############################################################################
#     Copyright (C) 2014-2016 by Vaughn Iverson
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
               lock.releaseLock()
               return callback()

            unless count is file.metadata._Resumable.resumableTotalChunks
               cursor.close()
               lock.releaseLock()
               return callback()

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
                     return cb new Meteor.Error "Received null part" unless part
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
                     partlock.on 'timed-out', () -> cb new Meteor.Error 'Partlock timed out!'
                     partlock.on 'expired', () -> cb new Meteor.Error 'Partlock expired!'
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
                             callback err

      lock.on 'expires-soon', () ->
         lock.renewLock().once 'renewed', (ld) ->
            unless ld
               console.warn "Resumable upload lock renewal failed!"
      lock.on 'expired', () -> callback new Meteor.Error "File Lock expired"
      lock.on 'timed-out', () -> callback new Meteor.Error "File Lock timed out"
      lock.on 'error', (err) -> callback err

   # Handle HTTP POST requests from Resumable.js

   resumable_post_lookup = (params, query, multipart) ->
      return { _id: share.safeObjectID(multipart?.params?.resumableIdentifier) }

   resumable_post_handler = (req, res, next) ->

      # This has to be a resumable POST
      unless req.multipart?.params?.resumableIdentifier
         console.error "Missing resumable.js multipart information"
         res.writeHead(501, share.defaultResponseHeaders)
         res.end()
         return

      resumable = req.multipart.params
      resumable.resumableTotalSize = parseInt resumable.resumableTotalSize
      resumable.resumableTotalChunks = parseInt resumable.resumableTotalChunks
      resumable.resumableChunkNumber = parseInt resumable.resumableChunkNumber
      resumable.resumableChunkSize = parseInt resumable.resumableChunkSize
      resumable.resumableCurrentChunkSize = parseInt resumable.resumableCurrentChunkSize

      if req.maxUploadSize > 0
         unless resumable.resumableTotalSize <= req.maxUploadSize
            res.writeHead(413, share.defaultResponseHeaders)
            res.end()
            return

      # Sanity check the chunk sizes that are critical to reassembling the file from parts
      unless ((req.gridFS.chunkSize is resumable.resumableChunkSize) and
              (resumable.resumableChunkNumber <= resumable.resumableTotalChunks) and
              (resumable.resumableTotalSize/resumable.resumableChunkSize <= resumable.resumableTotalChunks+1) and
              (resumable.resumableCurrentChunkSize is resumable.resumableChunkSize) or
              ((resumable.resumableChunkNumber is resumable.resumableTotalChunks) and
               (resumable.resumableCurrentChunkSize < 2*resumable.resumableChunkSize)))

         res.writeHead(501, share.defaultResponseHeaders)
         res.end()
         return

      chunkQuery =
         length: resumable.resumableCurrentChunkSize
         'metadata._Resumable.resumableIdentifier': resumable.resumableIdentifier
         'metadata._Resumable.resumableChunkNumber': resumable.resumableChunkNumber

      # This is to handle duplicate chunk uploads in case of network weirdness
      findResult = @findOne chunkQuery, { fields: { _id: 1 }}

      if findResult
         # Duplicate chunk... Don't rewrite it.
         # console.warn "Duplicate chunk detected: #{resumable.resumableChunkNumber}, #{resumable.resumableIdentifier}"
         res.writeHead(200, share.defaultResponseHeaders)
         res.end()
      else
         # Everything looks good, so write this part
         req.gridFS.metadata._Resumable = resumable
         writeStream = @upsertStream
            filename: "_Resumable_#{resumable.resumableIdentifier}_#{resumable.resumableChunkNumber}_#{resumable.resumableTotalChunks}"
            metadata: req.gridFS.metadata

         unless writeStream
            res.writeHead(404, share.defaultResponseHeaders)
            res.end()
            return

         req.multipart.fileStream.pipe(share.streamChunker(@chunkSize)).pipe(writeStream)
            .on 'close', share.bind_env((retFile) =>
               if retFile
                  # Check to see if all of the parts are now available and can be reassembled
                  check_order.bind(@)(req.gridFS, (err) ->
                     if err
                        console.error "Error reassembling chunks of resumable.js upload", err
                        res.writeHead(500, share.defaultResponseHeaders)
                     else
                        res.writeHead(200, share.defaultResponseHeaders)
                     res.end()
                  )
               else
                  console.error "Missing retFile on pipe close"
                  res.writeHead(500, share.defaultResponseHeaders)
                  res.end()
               )

            .on 'error', share.bind_env((err) =>
               console.error "Piping Error!", err
               res.writeHead(500, share.defaultResponseHeaders)
               res.end())

   resumable_get_lookup = (params, query) ->
      q = { _id: share.safeObjectID(query.resumableIdentifier) }
      return q

   # This handles Resumable.js "test GET" requests, that exist to determine
   # if a part is already uploaded. It also handles HEAD requests, which
   # should be a bit more efficient and resumable.js now supports
   resumable_get_handler = (req, res, next) ->
      query = req.query
      chunkQuery =
         $or: [
            {
               _id: share.safeObjectID(query.resumableIdentifier)
               length: parseInt query.resumableTotalSize
            }
            {
               length: parseInt query.resumableCurrentChunkSize
               'metadata._Resumable.resumableIdentifier': query.resumableIdentifier
               'metadata._Resumable.resumableChunkNumber': parseInt query.resumableChunkNumber
            }
         ]

      result = @findOne chunkQuery, { fields: { _id: 1 }}
      if result
         # Chunk is present
         res.writeHead(200, share.defaultResponseHeaders)
      else
         # Chunk is missing
         res.writeHead(204, share.defaultResponseHeaders)

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
      {
         method: 'head'
         path: '/_resumable'
         lookup: resumable_get_lookup
         handler: resumable_get_handler
      }
   ]
