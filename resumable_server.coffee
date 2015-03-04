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

   # Handle HTTP POST requests from Resumable.js

   resumable_post_lookup = (params, query, multipart) ->
      return { _id: share.safeObjectID(multipart?.params?.resumableIdentifier) }

   resumable_post_handler = (req, res, next) ->
      # This has to be a resumable POST
      unless req.multipart?.params?.resumableIdentifier
         console.error "Missing resumable.js multipart information"
         res.writeHead(501)
         res.end()
         return

      resumable = req.multipart.params
      resumable.resumableTotalSize = parseInt resumable.resumableTotalSize
      resumable.resumableTotalChunks = parseInt resumable.resumableTotalChunks
      resumable.resumableChunkNumber = parseInt resumable.resumableChunkNumber
      resumable.resumableChunkSize = parseInt resumable.resumableChunkSize
      resumable.resumableCurrentChunkSize = parseInt resumable.resumableCurrentChunkSize

      # Sanity check the chunk sizes that are critical to reassembling the file from parts
      unless ((req.gridFS.chunkSize is resumable.resumableChunkSize) and
              (resumable.resumableCurrentChunkSize is resumable.resumableChunkSize) or
              ((resumable.resumableChunkNumber is resumable.resumableTotalChunks) and
               (resumable.resumableCurrentChunkSize < 2*resumable.resumableChunkSize)))

         res.writeHead(501)
         res.end()
         return

      # Everything looks good, so write this part
      req.gridFS.metadata._Resumable = resumable
      writeStream = @upsertStream
         filename: "_Resumable_#{resumable.resumableIdentifier}_#{resumable.resumableChunkNumber}_#{resumable.resumableTotalChunks}"
         metadata: req.gridFS.metadata

      unless writeStream
         res.writeHead(404)
         res.end()
         return

      req.multipart.fileStream.pipe(writeStream)
         .on 'close', share.bind_env((retFile) =>
            if retFile
               res.writeHead(200)
               res.end()
               # Check to see if all of the parts are now available and can be reassembled
               check_order.bind(@)(req.gridFS, (err) ->
                  console.error "Error reassembling chunks of resumable.js upload", err
               )
            )
         .on 'error', share.bind_env((err) =>
            console.error "Piping Error!", err
            res.writeHead(500)
            res.end())

   resumable_get_lookup = (params, query) ->
      return $or: [
            {
               _id: query.resumableIdentifier
               length: query.resumableTotalSize
            }
            {
               length: query.resumableCurrentChunkSize
               'metadata._Resumable.resumableIdentifier': query.resumableIdentifier
               'metadata._Resumable.resumableChunkNumber': query.resumableChunkNumber
            }
         ]

   # This handles Resumable.js "test GET" requests, that exist to determine if a part is already uploaded
   resumable_get_handler = (req, res, next) ->
      # All is good
      res.writeHead(200)
      res.end()

   # Setup the GET and POST HTTP REST paths for Resumable.js in express
   share.resumable_paths = [
      {
         method: 'post'
         path: '/_resumable'
         lookup: resumable_post_lookup
         handler: resumable_post_handler
      }
      {
         method: 'get'
         path: '/_resumable'
         lookup: resumable_get_lookup
         handler: resumable_get_handler
      }
   ]
