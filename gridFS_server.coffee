
if Meteor.isServer

   mongodb = Npm.require 'mongodb'
   grid = Npm.require 'gridfs-locking-stream'
   gridLocks = Npm.require 'gridfs-locks'
   fs = Npm.require 'fs'
   path = Npm.require 'path'
   dicer = Npm.require 'dicer'
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
               RE_FILE = /^form-data; name="file"; filename="([^"]+)"/
               for k, v of header
                  console.log "Part header: k: #{k}, v: #{v}"
                  if k is 'content-type'
                     ft = v
                  if k is 'content-disposition'
                     if re = RE_FILE.exec(v)
                        fileStream = p
                        console.log "Parsing this shit!", v
                        fn = re[1]
               callback(null, fileStream, fn, ft)

         d.on 'error', (err) ->
           console.log('Error in Dicer: \n', err)
           callback err

         d.on 'finish', () ->
            unless fileStream
               callback(new Error "No file in multipart POST")

         req.pipe(d)

      _post: (req, res, next) ->
         console.log "Cowboy!", req.method, req.gridFS, req.headers

         unless @_check_allow_deny 'update', req.meteorUserId, req.gridFS, ['length', 'md5']
            res.writeHead(404)
            res.end("#{req.url} Not found!")
            return

         @_dice_multipart req, (err, fileStream, filename, filetype) =>
            if err
               res.writeHead(500)
               res.end()
               return
            console.log "filename: #{filename} filetype: #{filetype}"

            if filename or filetype
               set = {}
               set.contentType = filetype if filetype
               set.filename = filename if filename
               @update { _id: req.gridFS._id }, { $set: set }

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

         if req.headers['content-type']
            @update { _id: req.gridFS._id }, { $set: { contentType: req.headers['content-type'] }}

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

         @chunkSize = options.chunkSize ? share.defaultChunkSize
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
            share.setup_resumable.bind(@)()

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
               # Only metedata, filename, aliases and contentType should ever be changed by the client

               # unless fields.every((x) -> ['metadata', 'aliases', 'filename', 'contentType'].indexOf(x) isnt -1)
               #    console.log "Update failed"
               #    return false

               # if @_check_allow_deny 'update', userId, file, fields
               #    console.log "Update approved"
               #    return true

               # Cowboy updates are not allowed from the client. There's too much to screw up.
               # For example, if you store file ownership info in a sub document under 'metadata'
               # it will be complicate to guard against that being changed if you allow other parts
               # of the metadata sub doc to be updated. Write specific Meteor methods instead to allow
               # reasonable changes to the "metadata" parts of the gridFS file record.
               # i.e. ['metadata', 'aliases', 'filename', 'contentType']
               return false

            insert: (userId, file) =>

               # Make darn sure we're creating a valid gridFS .files document
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
         file = share.insert_func file, @chunkSize
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


