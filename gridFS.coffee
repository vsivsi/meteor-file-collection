if Meteor.isServer

   mongodb = Npm.require 'mongodb'
   grid = Npm.require 'gridfs-stream'
   fs = Npm.require 'fs'
   path = Npm.require 'path'

   class gridFS extends Meteor.Collection

      _check_allow_deny: (type, userId, file) ->
         console.log "In Client '#{type}' allow: #{file.filename} {@db}"
         allowResult = false
         allowResult = allowResult or allowFunc(userId, file) for allowFunc in @allows[type]
         denyResult = true
         denyResult = denyResult and denyFunc(userId, file) for denyFunc in @denys[type]
         return allowResult and denyResult

      _bind_env: (func) ->
         if func?
            return Meteor.bindEnvironment func, (err) -> throw err
         else
            return func

      _get: (req, res, next) ->
         console.log "Cowboy!", req.method
         next()

      _post: (req, res, next) ->
         console.log "Cowboy!", req
         res.writeHead(200)
         res.end("'k thx bye!")

      _put: (req, res, next) ->
         console.log "Cowboy!", req.method
         next()

      _delete: (req, res, next) ->
         console.log "Cowboy!", req.method
         next()

      _connect_gridfs: (req, res, next) ->
         switch req.method
            when 'GET' then @_get(req, res, next)
            when 'POST' then @_post(req, res, next)
            when 'PUT' then @_put(req, res, next)
            when 'DELETE' then @_delete(req, res, next)
            else
               console.log "Bad method ", req.method
               next()

      _access_point: (url) ->
         app = WebApp.rawConnectHandlers
         app.use url, @_connect_gridfs.bind(@)

      constructor: (@base, @baseURL) ->
         console.log "Making a gridFS collection!"

         @base ?= 'fs'
         @baseURL ?= "/gridfs/#{@base}"

         @_access_point(@baseURL)

         @db = Meteor._wrapAsync(mongodb.MongoClient.connect)(process.env.MONGO_URL,{})
         @gfs = new grid(@db, mongodb)
         @chunkSize = 2*1024*1024

         @allows = { insert: [], update: [], remove: [] }
         @denys = { insert: [], update: [], remove: [] }

         super @base + '.files'

         gridFS.__super__.allow.bind(@)

            remove: (userId, file) =>
               if @_check_allow_deny 'remove', userId, file
                  @remove file
                  # Meteor._wrapAsync(@gfs.remove.bind(@gfs))({ _id: "#{file._id}", root: @base })
                  return true

               return false

            update: (userId, file, fields) =>
               if @_check_allow_deny 'update', userId, file
                  if fields.length is 1 and fields[0] is 'metadata'
                     # Only metadata may be updated
                     return true

               return false

            insert: (userId, file) =>
               if @_check_allow_deny 'insert', userId, file
                  file.client = true
                  return true

               return false

      remove: (selector, callback = undefined) ->
         callback = @_bind_env callback
         console.log "In Server REMOVE"
         if selector?
            @find(selector).forEach (file) =>
               Meteor._wrapAsync(@gfs.remove.bind(@gfs))({ _id: "#{file._id}", root: @base })
            callback and callback null
         else
            console.warn "GridFS Collection does not 'remove' with an empty selector"
            callback null

      allow: (allowOptions) ->
         @allows[type].push(func) for type, func of allowOptions when type of @allows

      deny: (denyOptions) ->
         @denys[type].push(func) for type, func of denyOptions when type of @denys

      insert: (options, callback = undefined) ->
         callback = @_bind_env callback
         writeStream = @gfs.createWriteStream
            filename: options.filename || ''
            mode: 'w'
            root: @base
            chunk_size: options.chunk_size || @chunkSize
            aliases: options.aliases || null
            metadata: options.metadata || null
            content_type: options.content_type || 'application/octet-stream'

         if callback?
            writeStream.on('close', (file) ->
               callback(null, file._id))

         return writeStream

      findOne: (selector, options = {}) ->
         file = super selector, { sort: options.sort, skip: options.skip }
         if file
            readStream = @gfs.createReadStream
               root: @base
               _id: "#{file._id}"
            return readStream
         else
            return null

      upsert: () ->
         throw new Error "GridFS Collections do not support 'upsert'"

      importFile: (filePath, options, callback) ->
         callback = @_bind_env callback
         filePath = path.normalize filePath
         options = options || {}
         options.filename = path.basename filePath
         readStream = fs.createReadStream filePath
         writeStream = @insert options, callback
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

   class gridFS extends Meteor.Collection

      constructor: (@base, @baseURL) ->
         console.log "Making a gridFS collection!"
         @base ?= 'fs'
         @baseURL ?= "/gridfs/#{@base}"
         @chunkSize = 2*1024*1024
         super @base + '.files'

         r = new Resumable
            target: @baseURL
            generateUniqueIdentifier: (file) -> "#{new Meteor.Collection.ObjectID()}"
            chunkSize: @chunkSize
            testChunks: false

         unless r.support
            console.error "resumable.js not supported by this Browser, uploads will be disabled"
         else
            @resumable = r
            r.on('fileAdded', (file) =>
               console.log "fileAdded", file
               @insert({
                  _id: file.uniqueIdentifier
                  filename: file.fileName
                  contentType: file.file.type
                  metadata:
                     uploaded: false
                     owner: Meteor.userId() ? null
                     resumable: {}
               }, () -> r.upload())
            )
            r.on('fileSuccess', (file, message) =>
               console.log "fileSuccess", file, message
            )
            r.on('fileError', (file, message) =>
               console.log "fileError", file, message
            )

      upsert: () ->
         throw new Error "GridFS Collections do not support 'upsert'"

      insert: (file, callback = undefined) ->
         if file._id
            id = new Meteor.Collection.ObjectID("#{file._id}")
         else
            id = new Meteor.Collection.ObjectID()
         subFile = {}
         subFile._id = id
         subFile.length = 0
         subFile.md5 = 'd41d8cd98f00b204e9800998ecf8427e'
         subFile.uploadDate = new Date()
         subFile.chunkSize = file.chunkSize or @chunkSize
         subFile.filename = file.filename if file.filename?
         subFile.metadata = file.metadata if file.metadata?
         subFile.contentType = file.contentType if file.contentType?
         super subFile, callback

