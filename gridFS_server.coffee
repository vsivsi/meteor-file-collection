
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

         # if there are HTTP options, setup the express HTTP access point(s)
         if options.resumable or options.http
            share.setupHttpAccess.bind(@)(options)

         # Default client allow/deny permissions
         @allows = { insert: [], update: [], remove: [] }
         @denys = { insert: [], update: [], remove: [] }

         # Call super's constructor
         super @base + '.files'

         # Setup specific allow/deny rules for gridFS, and tie-in the application settings
         gridFSCollection.__super__.allow.bind(@)

            remove: (userId, file) =>

               # call application rules
               if @_check_allow_deny 'remove', userId, file

                  # This causes the file data itself to be removed from gridFS
                  @remove file
                  return true

               return false

            update: (userId, file, fields) =>

               ## Cowboy updates are not currently allowed from the client. Too much to screw up.
               ## For example, if you store file ownership info in a sub document under 'metadata'
               ## it will be complicated to guard against that being changed if you allow other parts
               ## of the metadata sub doc to be updated. Write specific Meteor methods instead to
               ## allow reasonable changes to the "metadata" parts of the gridFS file record.

               ## WARNING! Only metadata, filename, aliases and contentType should ever be changed
               ## directly by a client, e.g. :

               # unless fields.every((x) -> ['metadata', 'aliases', 'filename', 'contentType'].indexOf(x) isnt -1)
               #    console.log "Update failed"
               #    return false

               ## call application rules
               # if @_check_allow_deny 'update', userId, file, fields
               #    console.log "Update approved"
               #    return true

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

               # Enforce a uniform chunkSize
               unless file.chunkSize is @chunkSize
                  console.error "Invalid chunksize"
                  return false

               # call application rules
               if @_check_allow_deny 'insert', userId, file
                  return true

               return false

      # Register application allow rules
      allow: (allowOptions) ->
         @allows[type].push(func) for type, func of allowOptions when type of @allows

      # Register application deny rules
      deny: (denyOptions) ->
         @denys[type].push(func) for type, func of denyOptions when type of @denys

      insert: (file, callback = undefined) ->
         file = share.insert_func file, @chunkSize
         super file, callback

      upsert: (file, options = {}, callback = undefined) ->
         callback = share.bind_env callback

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

      remove: (selector, callback = undefined) ->
         callback = share.bind_env callback
         if selector?
            @find(selector).forEach (file) =>
               Meteor._wrapAsync(@gfs.remove.bind(@gfs))({ _id: mongodb.ObjectID("#{file._id}"), root: @base })
            callback and callback null
         else
            console.warn "GridFS Collection does not 'remove' with an empty selector"
            callback null

      importFile: (filePath, options, callback) ->
         callback = share.bind_env callback
         filePath = path.normalize filePath
         options = options || {}
         options.filename = path.basename filePath
         readStream = fs.createReadStream filePath
         writeStream = @upsert options, {}, callback
         readStream.pipe(writeStream)
            .on('error', callback)

      exportFile: (id, filePath, callback) ->
         callback = share.bind_env callback
         filePath = path.normalize filePath
         readStream = @findOne { _id: id }
         writeStream = fs.createWriteStream filePath
         readStream.pipe(writeStream)
            .on('finish', callback)
            .on('error', callback)

