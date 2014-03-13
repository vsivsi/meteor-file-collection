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

      constructor: (@base) ->
         console.log "Making a gridFS collection!"

         @base ?= 'fs'

         @db = Meteor._wrapAsync(mongodb.MongoClient.connect)(process.env.MONGO_URL,{})
         @gfs = new grid(@db, mongodb)
         @chunkSize = 2*1024*1024

         @allows = { insert: [], update: [], remove: [] }
         @denys = { insert: [], update: [], remove: [] }

         super @base + '.files'

         gridFS.__super__.allow.bind(@)

            remove: (userId, file) =>
               if @_check_allow_deny 'remove', userId, file
                  Meteor._wrapAsync(@gfs.remove.bind(@gfs))({ _id: "#{file._id}", root: @base })
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
                  return true

               return true

      remove: (selector, callback = undefined) ->
         callback = @_bind_env callback
         console.log "In Server REMOVE"
         if selector?
            @find(selector).forEach (file) ->
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
         file = super selector, { sort: options.sort, skip: options.skip}
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

      constructor: (@base) ->
         console.log "Making a gridFS collection!"
         @base ?= 'fs'
         super @base + '.files'

      upsert: () ->
         throw new Error "GridFS Collections do not support 'upsert'"

