############################################################################
#     Copyright (C) 2014-2015 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isServer

   express = Npm.require 'express'
   mongodb = Npm.require 'mongodb'
   grid = Npm.require 'gridfs-locking-stream'
   gridLocks = Npm.require 'gridfs-locks'
   dicer = Npm.require 'dicer'
   async = Npm.require 'async'

   # This function checks to see if all of the parts of a Resumable.js uploaded file are now in the gridFS
   # Collection. If so, it completes the file by moving all of the chunks to the correct file and cleans up

   check_order = (file, callback) ->
      fileId = mongodb.ObjectID("#{file.metadata._Resumable.resumableIdentifier}")
      lock = gridLocks.Lock(fileId, @locks, {}).obtainWriteLock()
      lock.on 'locked', () =>

         files = @db.collection "#{@root}.files"

         cursor = files.find(
            {
               'metadata._Resumable.resumableIdentifier': file.metadata._Resumable.resumableIdentifier
               length:
                  $ne: 0
            },
            {
               fields:
                  length: 1
                  metadata: 1
               sort:
                  'metadata._Resumable.resumableChunkNumber': 1
            }
         )
         
         cursor.count (err, count) =>
            if err
               lock.releaseLock()
               return callback err

            unless count >= 1
               cursor.close()
               return lock.releaseLock()

            unless count is file.metadata._Resumable.resumableTotalChunks
               cursor.close()
               return lock.releaseLock()

            # Manipulate the chunks and files collections directly under write lock
            chunks = @db.collection "#{@root}.chunks"

            cursor.batchSize file.metadata._Resumable.resumableTotalChunks + 1

            cursor.toArray (err, parts) =>

               if err
                  lock.releaseLock()
                  return callback err

               async.eachLimit parts, 5,
                  (part, cb) =>
                     if err
                        console.error "Error from cursor.next()", err
                        cb err
                     return cb new Error "Received null part" unless part
                     partId = mongodb.ObjectID("#{part._id}")
                     partlock = gridLocks.Lock(partId, @locks, {}).obtainWriteLock()
                     partlock.on 'locked', () =>
                        async.series [
                              # Move the chunks to the correct file
                              (cb) -> chunks.update { files_id: partId, n: 0 },
                                 { $set: { files_id: fileId, n: part.metadata._Resumable.resumableChunkNumber - 1 }}
                                 cb
                              # Delete the temporary chunk file documents
                              (cb) -> files.remove { _id: partId }, cb
                           ],
                           (err, res) =>
                              return cb err if err
                              unless part.metadata._Resumable.resumableChunkNumber is part.metadata._Resumable.resumableTotalChunks
                                 partlock.removeLock()
                                 cb()
                              else
                                 # check for a final hanging gridfs chunk
                                 chunks.update { files_id: partId, n: 1 },
                                    { $set: { files_id: fileId, n: part.metadata._Resumable.resumableChunkNumber }}
                                    (err, res) ->
                                       partlock.removeLock()
                                       return cb err if err
                                       cb()
                     partlock.on 'timed-out', () -> cb new Error 'Partlock timed out!'
                     partlock.on 'expired', () -> cb new Error 'Partlock expired!'
                     partlock.on 'error', (err) ->
                        console.error "Error obtaining partlock #{part._id}", err 
                        cb err
                  (err) =>
                     if err
                        lock.releaseLock()
                        return callback err
                     # Build up the command for the md5 hash calculation
                     md5Command =
                       filemd5: fileId
                       root: "#{@root}"
                     # Send the command to calculate the md5 hash of the file
                     @db.command md5Command, (err, results) ->
                       if err
                          lock.releaseLock()
                          return callback err
                       # Update the size and md5 to the file data
                       files.update { _id: fileId }, { $set: { length: file.metadata._Resumable.resumableTotalSize, md5: results.md5 }},
                          (err, res) =>
                             lock.releaseLock()
                             return callback err if err
      
      lock.on 'timed-out', () -> callback new Error "File Lock timed out"
      lock.on 'expired', () -> callback new Error "File Lock expired"
      lock.on 'error', (err) -> callback err

   # Fast MIME Multipart parsing of the Resumable.js HTTP POST request bodies

   dice_resumable_multipart = (req, callback) ->
      callback = share.bind_env callback
      boundary = share.find_mime_boundary req

      unless boundary
         console.error 'No MIME multipart boundary found for dicer'
         err = new Error('No MIME multipart boundary found for dicer')
         return callback err

      resumable = {}
      resCount = 0
      fileStream = null

      d = new dicer { boundary: boundary }

      d.on 'part', (p) ->
         p.on 'header', (header) ->
            RE_RESUMABLE = /^form-data; name="(resumable[^"]+)"/
            RE_FILE = /^form-data; name="file"; filename="blob"/
            RE_NUMBER = /Size|Chunk/
            for k, v of header
               if k is 'content-disposition'
                  if resVar = RE_RESUMABLE.exec(v)?[1]
                     resData = ''
                     resCount++

                     p.on 'data', (data) -> resData += data.toString()

                     p.on 'end', () ->
                        resCount--
                        unless RE_NUMBER.test(resVar)
                           resumable[resVar] = resData
                        else
                           resumable[resVar] = parseInt(resData)
                        if resCount is 0 and fileStream
                           callback(null, resumable, fileStream)

                     p.on 'error', (err) ->
                        console.error('Error in Dicer while streaming: \n', err)
                        callback err

                  else if RE_FILE.exec(v)
                     fileStream = p
                     if resCount is 0
                        callback(null, resumable, fileStream)

      d.on 'error', (err) ->
        console.error('Error in Dicer: \n', err)
        callback err

      d.on 'finish', () ->
         unless fileStream
            callback(new Error "No file blob in multipart POST")

      req.pipe(d)

   # Handle HTTP POST requests from Resumable.js

   resumable_post = (req, res, next) ->

      # Parse the multipart body
      dice_resumable_multipart.bind(@) req, (err, resumable, fileStream) =>
         # Error parsing
         if err
            res.writeHead(500)
            res.end()
            return
         else
            # This khas to be a resumable POST
            unless resumable
               res.writeHead(501)
               res.end()
               return

            # See if this file already exists in some form
            try
               ID = new Meteor.Collection.ObjectID(resumable.resumableIdentifier)
            catch
               res.writeHead(501)
               res.end()
               return

            file = @findOne { _id: ID }

            # File must exist to write to it
            unless file
               res.writeHead(404)
               res.end()
               return

            # Make sure we have permission
            unless share.check_allow_deny.bind(@) 'write', req.meteorUserId, file, ['length', 'md5']
               res.writeHead(404)
               res.end()
               return

            # Sanity check the chunk sizes that are critical to reassembling the file from parts
            unless ((file.chunkSize is resumable.resumableChunkSize) and
                    (resumable.resumableCurrentChunkSize is resumable.resumableChunkSize) or
                    ((resumable.resumableChunkNumber is resumable.resumableTotalChunks) and
                     (resumable.resumableCurrentChunkSize < 2*resumable.resumableChunkSize)))

               res.writeHead(501)
               res.end()
               return

            # Everything looks good, so write this part
            file.metadata._Resumable = resumable
            writeStream = @upsertStream
               filename: "_Resumable_#{resumable.resumableIdentifier}_#{resumable.resumableChunkNumber}_#{resumable.resumableTotalChunks}"
               metadata: file.metadata

            unless writeStream
               res.writeHead(404)
               res.end()
               return

            fileStream.pipe(writeStream)
               .on 'close', share.bind_env((retFile) =>
                  if retFile
                     res.writeHead(200)
                     res.end()
                     # Check to see if all of the parts are now available and can be reassembled
                     check_order.bind(@)(file, (err) ->
                        console.error "Error reassembling chunks of resumable.js upload", err
                     )
                  )
               .on 'error', share.bind_env((err) =>
                  console.error "Piping Error!", err
                  res.writeHead(500)
                  res.end())

   # This handles Resumable.js "test GET" requests, that exist to determine if a part is already uploaded

   resumable_get = (req, res, next) ->

      # Query to see if this entire file is already complete, or if this part is complete in the GridFS collection
      file = @findOne(
         $or: [
            {
               _id: req.query.resumableIdentifier
               length: req.query.resumableTotalSize
            }
            {
               length: req.query.resumableCurrentChunkSize
               'metadata._Resumable.resumableIdentifier': req.query.resumableIdentifier
               'metadata._Resumable.resumableChunkNumber': req.query.resumableChunkNumber
            }
         ]
      )

      # If not, tell Resumable.js we don't have it yet
      unless file
         res.writeHead(404)
         res.end()
         return

      # Make sure we'll allow the POST that will come subsequently come from this...
      unless share.check_allow_deny.bind(@) 'write', req.meteorUserId, file, ['length', 'md5']
         res.writeHead(404)
         res.end()
         return

      # All is good
      res.writeHead(200)
      res.end()


   # Setup the GET and POST HTTP REST paths for Resumable.js in express
   share.setup_resumable = () ->
	    r = express.Router()
	    r.route('/_resumable')
	       .get(resumable_get.bind(@))
	       .post(resumable_post.bind(@))
	       .all((req, res, next) ->
	          res.writeHead(500)
	          res.end())
	    WebApp.rawConnectHandlers.use(@baseURL, share.bind_env(r))
