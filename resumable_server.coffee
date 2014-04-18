if Meteor.isServer

   express = Npm.require 'express'
   mongodb = Npm.require 'mongodb'
   grid = Npm.require 'gridfs-locking-stream'
   gridLocks = Npm.require 'gridfs-locks'
   dicer = Npm.require 'dicer'
   async = Npm.require 'async'

   check_order = (file) ->
      fileId = mongodb.ObjectID("#{file.metadata._Resumable.resumableIdentifier}")
      console.log "fileId: #{fileId}"
      lock = gridLocks.Lock(fileId, @locks, {}).obtainWriteLock()
      lock.on 'locked', () =>
         files = @db.collection "#{@base}.files"

         files.find({'metadata._Resumable.resumableIdentifier': file.metadata._Resumable.resumableIdentifier},
                    { sort: { 'metadata._Resumable.resumableChunkNumber': 1 }}).toArray (err, parts) =>
            throw err if err
            console.log "Found #{parts.length} OOO parts"

            unless parts.length >= 1
               return lock.releaseLock()

            lastPart = 0
            goodParts = parts.filter (el) ->
               l = lastPart
               lastPart = el.metadata?._Resumable.resumableChunkNumber
               return el.length is el.metadata?._Resumable.resumableCurrentChunkSize and lastPart is l + 1

            unless goodParts.length is goodParts[0].metadata._Resumable.resumableTotalChunks
               console.log "Found #{goodParts.length} of #{goodParts[0].metadata._Resumable.resumableTotalChunks}, so bailing for now."
               return lock.releaseLock()

            # Manipulate the chunks and files collections directly under write lock
            console.log "Start reassembling the file!!!!"
            chunks = @db.collection "#{@base}.chunks"
            totalSize = goodParts[0].metadata._Resumable.resumableTotalSize
            async.eachLimit goodParts, 3,
               (part, cb) =>
                  partId = mongodb.ObjectID("#{part._id}")
                  partlock = gridLocks.Lock(partId, @locks, {}).obtainWriteLock()
                  partlock.on 'locked', () ->
                     async.series [
                           (cb) -> chunks.update { files_id: partId, n: 0 },
                              { $set: { files_id: fileId, n: part.metadata._Resumable.resumableChunkNumber - 1 }}
                              cb
                           (cb) -> files.remove { _id: partId }, cb
                        ],
                        (err, res) =>
                           throw err if err
                           unless part.metadata._Resumable.resumableChunkNumber is part.metadata._Resumable.resumableTotalChunks
                              partlock.removeLock()
                              cb()
                           else
                              # check for a hanging chunk
                              chunks.update { files_id: partId, n: 1 },
                                 { $set: { files_id: fileId, n: part.metadata._Resumable.resumableChunkNumber }}
                                 (err, res) ->
                                    throw err if err
                                    console.log "Last bit updated", res
                                    partlock.removeLock()
                                    cb()

                  partlock.on 'timed-out', () ->  throw "Part Lock timed out"
               (err) =>
                  throw err if err

                  files.update { _id: fileId }, { $set: { length: totalSize }},
                     (err, res) =>
                        console.log "file updated", err, res
                        lock.releaseLock()
                        # Now open the file to update the md5 hash...
                        @gfs.createWriteStream { _id: fileId }, (err, stream) ->
                           throw err if err
                           console.log "Writing to stream to change md5 sum"
                           stream.write('')
                           stream.end()

      lock.on 'timed-out', () -> throw "File Lock timed out"

   dice_resumable_multipart = (req, callback) ->
      callback = share.bind_env callback
      boundary = share.find_mime_boundary req

      unless boundary
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
                        console.log('Error in Dicer while streaming: \n', err)
                        callback err

                  else if RE_FILE.exec(v)
                     fileStream = p
                     if resCount is 0
                        callback(null, resumable, fileStream)

      d.on 'error', (err) ->
        console.log('Error in Dicer: \n', err)
        callback err

      d.on 'finish', () ->
         unless fileStream
            callback(new Error "No file blob in multipart POST")

      req.pipe(d)

   resumable_post = (req, res, next) ->

      dice_resumable_multipart.bind(@) req, (err, resumable, fileStream) =>
         if err
            res.writeHead(500)
            res.end(err)
            return
         else
            unless resumable
               res.writeHead(501)
               res.end('Not a resumable.js POST!')
               return

            # See if this file already exists in some form
            try
               ID = new Meteor.Collection.ObjectID(resumable.resumableIdentifier)
            catch
               res.writeHead(501)
               res.end('Bad ID!')
               return

            file = @findOne { _id: ID }

            unless file
               res.writeHead(404)
               res.end('Upload document not found!')
               return

            unless share.check_allow_deny.bind(@) 'update', req.meteorUserId, file, ['length', 'md5']
               res.writeHead(404)
               res.end("#{req.url} Not found!")
               return

            unless ((file.chunkSize is resumable.resumableChunkSize) and
                    (resumable.resumableCurrentChunkSize is resumable.resumableChunkSize) or
                    ((resumable.resumableChunkNumber is resumable.resumableTotalChunks) and
                     (resumable.resumableCurrentChunkSize < 2*resumable.resumableChunkSize)))

               res.writeHead(501)
               res.end('Invalid chunkSize')
               return

            file.metadata._Resumable = resumable
            writeStream = @upsertStream
               filename: "_Resumable_#{resumable.resumableIdentifier}_#{resumable.resumableChunkNumber}_#{resumable.resumableTotalChunks}"
               metadata: file.metadata

            unless writeStream
               res.writeHead(404)
               res.end('Gone!')
               return

            try
               fileStream.pipe(writeStream)
                  .on 'close', share.bind_env((file) =>
                     console.log "Piping Close!"
                     res.writeHead(200)
                     res.end()
                     check_order.bind(@)(file))
                  .on 'error', share.bind_env((err) =>
                     console.log "Piping Error!", err
                     res.writeHead(500)
                     res.end(err))
            catch err
               res.writeHead(500)
               res.end(err)
               console.error "Caught during pipe", err
               console.trace()

   resumable_get = (req, res, next) ->

      console.log "Query: ", req.query

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

      unless file
         res.writeHead(404)
         res.end()
         return

      console.log "Show me the file!", file

      if share.check_allow_deny.bind(@) 'update', req.meteorUserId, file, ['length', 'md5']
         res.writeHead(200)
         res.end()
         return

      res.writeHead(404)
      res.end()

   share.setup_resumable = () ->
	    r = express.Router()
	    r.route('/_resumable')
	       .get(resumable_get.bind(@))
	       .post(resumable_post.bind(@))
	       .all((req, res, next) ->
	          res.writeHead(500)
	          res.end())
	    WebApp.rawConnectHandlers.use(@baseURL, share.bind_env(r))
