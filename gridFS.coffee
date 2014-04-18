
defaultChunkSize = 2*1024*1024

_shared_insert_func = (file, chunkSize) ->
   try
      id = new Meteor.Collection.ObjectID("#{file._id}")
   catch
      id = new Meteor.Collection.ObjectID()
   subFile = {}
   subFile._id = id
   subFile.length = 0
   subFile.md5 = 'd41d8cd98f00b204e9800998ecf8427e'
   subFile.uploadDate = new Date()
   subFile.chunkSize = chunkSize
   subFile.filename = file.filename ? ''
   subFile.metadata = file.metadata ? {}
   subFile.aliases = file.aliases ? []
   subFile.contentType = file.contentType ? 'application/octet-stream'
   return subFile

if Meteor.isServer

   mongodb = Npm.require 'mongodb'
   grid = Npm.require 'gridfs-locking-stream'
   gridLocks = Npm.require 'gridfs-locks'
   fs = Npm.require 'fs'
   path = Npm.require 'path'
   dicer = Npm.require 'dicer'
   async = Npm.require 'async'
   express = Npm.require 'express'

   class gridFSCollection extends Meteor.Collection

      _check_allow_deny: (type, userId, file, fields) ->
         console.log "In Client '#{type}' allow: #{file.filename}"
         allowResult = false
         allowResult = allowResult or allowFunc(userId, file, fields) for allowFunc in @allows[type]
         denyResult = true
         denyResult = denyResult and denyFunc(userId, file, fields) for denyFunc in @denys[type]
         result = allowResult and denyResult
         console.log "Permission: #{if result then "granted" else "denied"}"
         return result

      _lookup_userId_by_token: (authToken) ->
         console.log "Looking up user by token #{authToken} which hashes to #{Accounts._hashLoginToken(authToken)}"
         userDoc = Meteor.users.findOne { 'services.resume.loginTokens': { $elemMatch: { hashedToken: Accounts._hashLoginToken(authToken) } } }
         return userDoc?._id or null

      _bind_env: (func) ->
         if func?
            return Meteor.bindEnvironment func, (err) -> throw err
         else
            return func

      _find_mime_boundary: (req) ->
         RE_BOUNDARY = /^multipart\/.+?(?:; boundary=(?:(?:"(.+)")|(?:([^\s]+))))$/i
         result = RE_BOUNDARY.exec req.headers['content-type']
         result?[1] or result?[2]

      _dice_resumable_multipart: (req, callback) ->
         callback = @_bind_env callback
         boundary = @_find_mime_boundary req

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

      _dice_multipart: (req, callback) ->
         callback = @_bind_env callback
         boundary = @_find_mime_boundary req

         unless boundary
           err = new Error('No MIME multipart boundary found for dicer')
           return callback err

         fileStream = null

         d = new dicer { boundary: boundary }

         d.on 'part', (p) ->
            p.on 'header', (header) ->
               RE_FILE = /^form-data; name="file"; filename="[^"]*"/
               RE_NUMBER = /Size|Chunk/
               for k, v of header
                  if k is 'content-disposition'
                     if RE_FILE.exec(v)
                        fileStream = p
                        callback(null, fileStream)

         d.on 'error', (err) ->
           console.log('Error in Dicer: \n', err)
           callback err

         d.on 'finish', () ->
            unless fileStream
               callback(new Error "No file blob in multipart POST")

         req.pipe(d)

      _post: (req, res, next) ->
         console.log "Cowboy!", req.method, req.gridFS, req.headers

         unless @_check_allow_deny 'update', req.meteorUserId, req.gridFS, ['length', 'md5']
            res.writeHead(404)
            res.end("#{req.url} Not found!")
            return

         @_dice_multipart req, (err, fileStream) =>
            if err
               res.writeHead(500)
               res.end()
               return
            else
               console.log "Got fileStream callback"
               stream = @upsert req.gridFS
               if stream
                  fileStream.pipe(stream)
                     .on 'close', () ->
                        console.log "Closing the stream..."
                        res.writeHead(200)
                        res.end()
                     .on 'error', (err) ->
                        res.writeHead(500)
                        res.end(err)
               else
                  res.writeHead(410)
                  res.end("Gone!")

      _resumable_post: (req, res, next) ->

         @_dice_resumable_multipart req, (err, resumable, fileStream) =>
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

               file = gridFSCollection.__super__.findOne.bind(@)({ _id: ID })

               unless file
                  res.writeHead(404)
                  res.end('Upload document not found!')
                  return

               unless @_check_allow_deny 'update', req.meteorUserId, file, ['length', 'md5']
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
               writeStream = @upsert
                  filename: "_Resumable_#{resumable.resumableIdentifier}_#{resumable.resumableChunkNumber}_#{resumable.resumableTotalChunks}"
                  metadata: file.metadata

               unless writeStream
                  res.writeHead(404)
                  res.end('Gone!')
                  return

               try
                  fileStream.pipe(writeStream)
                     .on 'close', @_bind_env((file) =>
                        console.log "Piping Close!"
                        res.writeHead(200)
                        res.end()
                        @_check_order(file))
                     .on 'error', @_bind_env((err) =>
                        console.log "Piping Error!", err
                        res.writeHead(500)
                        res.end(err))
               catch err
                  res.writeHead(500)
                  res.end(err)
                  console.error "Caught during pipe", err
                  console.trace()

      _check_order: (file) ->
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

      _resumable_get: (req, res, next) ->

         console.log "Query: ", req.query

         file = gridFSCollection.__super__.findOne.bind(@)(
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

         if @_check_allow_deny 'update', req.meteorUserId, file, ['length', 'md5']
            res.writeHead(200)
            res.end()
            return

         res.writeHead(404)
         res.end()

      _get: (req, res, next) ->
         console.log "Cowboy!", req.method, req.gridFS

         headers =
            'Content-type': req.gridFS.contentType
            'Content-MD5': req.gridFS.md5
            'Content-Length': req.gridFS.length
            'Last-Modified': req.gridFS.uploadDate.toUTCString()

         if req.query.download
            headers['Content-Disposition'] = "attachment; filename=\"#{req.gridFS.filename}\""

         if req.method is 'HEAD'
            res.writeHead 204, headers
            res.end()
            return

         stream = @findOne { _id: req.gridFS._id }
         if stream
            res.writeHead 200, headers
            stream.pipe(res)
                  .on 'close', () ->
                     res.end()
                  .on 'error', (err) ->
                     res.writeHead(500)
                     res.end(err)
         else
            res.writeHead(410)
            res.end("#{req.url} Gone!")

      _put: (req, res, next) ->

         console.log "Cowboy!", req.method, req.gridFS

         unless @_check_allow_deny 'update', req.meteorUserId, req.gridFS, ['length', 'md5']
            res.writeHead(404)
            res.end("#{req.url} Not found!")
            return

         stream = @upsert req.gridFS
         if stream
            req.pipe(stream)
               .on 'close', () ->
                  res.writeHead(200)
                  res.end()
               .on 'error', (err) ->
                  res.writeHead(500)
                  res.end(err)
         else
            res.writeHead(404)
            res.end("#{req.url} Not found!")

      _delete: (req, res, next) ->
         console.log "Cowboy!", req.method, req.gridFS

         unless @_check_allow_deny 'remove', req.meteorUserId, req.gridFS
            res.writeHead(404)
            res.end("#{req.url} Not found!")
            return

         @remove req.gridFS
         res.writeHead(204)
         res.end()

      _build_access_point: (http, route) ->

         for r in http
            route[r.method] r.path, do (r) =>
               (req, res, next) =>
                  console.log "Params", req.params
                  console.log "Queries: ", req.query
                  console.log "Method: ", req.method

                  req.params._id = new Meteor.Collection.ObjectID("#{req.params._id}") if req.params?._id?
                  req.query._id = new Meteor.Collection.ObjectID("#{req.query._id}") if req.query?._id?

                  q = r.query req.meteorUserId, req.params or {}, req.query or {}
                  console.log "finding One, query:", JSON.stringify(q,false,1)
                  unless q?
                     console.log "No query returned, so passing"
                     next()
                  else
                     try
                        req.gridFS = gridFSCollection.__super__.findOne.bind(@)(q)
                        if req.gridFS
                           console.log "Found file #{req.gridFS._id}"
                           next()
                        else
                           res.writeHead(404)
                           res.end()
                     catch
                        res.writeHead(404)
                        res.end()

         route.route('/*')
            .head(@_get.bind(@))
            .get(@_get.bind(@))
            .put(@_put.bind(@))
            .post(@_post.bind(@))
            .delete(@_delete.bind(@))
            .all (req, res, next) ->
               res.writeHead(404)
               res.end()

      _handle_auth: (req, res, next) =>
         unless req.meteorUserId?
            console.log "Headers: ", req.headers
            # Lookup userId if token is provided
            if req.headers?['x-auth-token']?
               req.meteorUserId = @_lookup_userId_by_token req.headers['x-auth-token']
            else if req.query?['x-auth-token']?
               console.log "Has query x-auth-token: #{req.query['x-auth-token']}"
               req.meteorUserId = @_lookup_userId_by_token req.query['x-auth-token']
            console.log "Request:", req.method, req.url, req.headers?['x-auth-token'] or req.query?['x-auth-token'], req.meteorUserId
         next()

      constructor: (options = {}) ->
         unless @ instanceof gridFSCollection
            return new gridFSCollection(options)

         @chunkSize = options.chunkSize ? defaultChunkSize
         @base = options.base ? 'fs'

         @db = Meteor._wrapAsync(mongodb.MongoClient.connect)(process.env.MONGO_URL,{})
         @locks = gridLocks.LockCollection @db, { root: @base, timeOut: 360, lockExpiration: 90 }
         @gfs = new grid(@db, mongodb, @base)

         # Make an index on md5, to support GET requests
         @gfs.files.ensureIndex [['md5', 1]], (err, ret) ->
            throw err if err
         # Make an index on aliases, to support alternative GET requests
         @gfs.files.ensureIndex [['aliases', 1]], (err, ret) ->
            throw err if err

         @baseURL = options.baseURL ? "/gridfs/#{@base}"

         if options.resumable or options.http
            r = express.Router()
            r.use express.query()
            r.use @_handle_auth.bind(@)
            WebApp.rawConnectHandlers.use(@baseURL, @_bind_env(r))

         if options.resumable
            r = express.Router()
            r.route('/_resumable')
               .get(@_resumable_get.bind(@))
               .post(@_resumable_post.bind(@))
               .all((req, res, next) ->
                  res.writeHead(404)
                  res.end())
            WebApp.rawConnectHandlers.use(@baseURL, @_bind_env(r))

         if options.http
            @router = express.Router()
            @_build_access_point(options.http ? [], @router)
            WebApp.rawConnectHandlers.use(@baseURL, @_bind_env(@router))

         @allows = { insert: [], update: [], remove: [] }
         @denys = { insert: [], update: [], remove: [] }

         super @base + '.files'

         gridFSCollection.__super__.allow.bind(@)

            remove: (userId, file) =>
               if @_check_allow_deny 'remove', userId, file

                  # This causes the file data itself to be removed from gridFS
                  @remove file
                  return true

               return false

            update: (userId, file, fields) =>

               # Only metedata, filename, aliases and contentType may be changed by the client
               unless fields.every((x) -> ['metadata', 'aliases', 'filename', 'contentType'].indexOf(x) isnt -1)
                  console.log "Update failed"
                  return false

               if @_check_allow_deny 'update', userId, file, fields
                  console.log "Update approved"
                  return true

               console.log "Update failed"
               return false

            insert: (userId, file) =>

               check file,
                  _id: Meteor.Collection.ObjectID
                  length: Match.Where (x) ->
                     check x, Match.Integer
                     x >= 0
                  md5: Match.Where (x) ->
                     check x, String
                     x.length is 32
                  uploadDate: Date
                  chunkSize: Match.Where (x) ->
                     check x, Match.Integer
                     x > 0
                  filename: String
                  contentType: String
                  aliases: [ String ]
                  metadata: Object

               unless file.chunkSize is @chunkSize
                  console.error "Invalid chunksize"
                  return false

               if @_check_allow_deny 'insert', userId, file
                  return true

               return false

      remove: (selector, callback = undefined) ->
         callback = @_bind_env callback
         if selector?
            @find(selector).forEach (file) =>
               Meteor._wrapAsync(@gfs.remove.bind(@gfs))({ _id: mongodb.ObjectID("#{file._id}"), root: @base })
            callback and callback null
         else
            console.warn "GridFS Collection does not 'remove' with an empty selector"
            callback null

      allow: (allowOptions) ->
         @allows[type].push(func) for type, func of allowOptions when type of @allows

      deny: (denyOptions) ->
         @denys[type].push(func) for type, func of denyOptions when type of @denys

      insert: (file, callback = undefined) ->
         file = _shared_insert_func file, @chunkSize
         super file, callback

      upsert: (file, options = {}, callback = undefined) ->

         callback = @_bind_env callback

         unless file._id
            id = @insert file
            file = gridFSCollection.__super__.findOne.bind(@)({ _id: id })

         subFile =
            _id: mongodb.ObjectID("#{file._id}")
            mode: 'w+'
            root: @base
            metadata: file.metadata ? {}
            timeOut: 30

         writeStream = Meteor._wrapAsync(@gfs.createWriteStream.bind(@gfs)) subFile

         writeStream.on 'close', (retFile) ->
            console.log "Done writing"

         if callback?
            writeStream.on 'close', (retFile) ->
               callback(null, retFile._id)

         console.log "Returning writeStream"
         return writeStream

      findOne: (selector, options = {}) ->
         file = super selector, { sort: options.sort, skip: options.skip }
         if file
            readStream = Meteor._wrapAsync(@gfs.createReadStream.bind(@gfs))
               root: @base
               _id: mongodb.ObjectID("#{file._id}")
            return readStream
         else
            return null

      importFile: (filePath, options, callback) ->
         callback = @_bind_env callback
         filePath = path.normalize filePath
         options = options || {}
         options.filename = path.basename filePath
         readStream = fs.createReadStream filePath
         writeStream = @upsert options, {}, callback
         readStream.pipe(writeStream)
            .on('error', callback)

      exportFile: (id, filePath, callback) ->
         callback = @_bind_env callback
         filePath = path.normalize filePath
         readStream = @findOne { _id: id }
         writeStream = fs.createWriteStream filePath
         readStream.pipe(writeStream)
            .on('finish', callback)
            .on('error', callback)

##################################################################################################

if Meteor.isClient

   class gridFSCollection extends Meteor.Collection

      constructor: (options) ->
         unless @ instanceof gridFSCollection
            return new gridFSCollection(options)

         @chunkSize = options.chunkSize ? defaultChunkSize
         @base = options.base ? 'fs'
         @baseURL = options.baseURL ? "/gridfs/#{@base}"
         super @base + '.files'

         if options.resumable
            r = new Resumable
               target: "#{@baseURL}/_resumable"
               generateUniqueIdentifier: (file) -> "#{new Meteor.Collection.ObjectID()}"
               chunkSize: @chunkSize
               testChunks: true
               simultaneousUploads: 3
               prioritizeFirstAndLastChunk: false
               headers: { 'X-Auth-Token': Accounts._storedLoginToken() ? '' }

            unless r.support
               console.error "resumable.js not supported by this Browser, uploads will be disabled"
               @resumable = null
            else
               @resumable = r
               r.on('fileAdded', (file) =>
                  console.log "fileAdded", file
                  @insert({
                     _id: file.uniqueIdentifier
                     filename: file.fileName
                     contentType: file.file.type
                  }, () -> r.upload())
               )
               r.on('fileSuccess', (file, message) =>
                  console.log "fileSuccess", file, message
               )
               r.on('fileError', (file, message) =>
                  console.log "fileError", file, message
               )

      upsert: () ->
         throw new Error "GridFS Collections do not support 'upsert' on client"

      insert: (file, callback = undefined) ->
         file = _shared_insert_func file, @chunkSize
         super file, callback

