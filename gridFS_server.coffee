############################################################################
#     Copyright (C) 2014 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isServer

   mongodb = Npm.require 'mongodb'
   grid = Npm.require 'gridfs-locking-stream'
   gridLocks = Npm.require 'gridfs-locks'
   fs = Npm.require 'fs'
   path = Npm.require 'path'
   dicer = Npm.require 'dicer'
   express = Npm.require 'express'

   class fileCollection extends Meteor.Collection

      constructor: (@root = share.defaultRoot, options = {}) ->
         unless @ instanceof fileCollection
            return new fileCollection(@root, options)

         if typeof @root is 'object'
            options = @root
            @root = share.defaultRoot

         @chunkSize = options.chunkSize ? share.defaultChunkSize

         @db = Meteor._wrapAsync(mongodb.MongoClient.connect)(process.env.MONGO_URL,{})

         @lockOptions =
            timeOut: options.locks?.timeOut ? 360
            lockExpiration: options.locks?.lockExpiration ? 90
            pollingInterval: options.locks?.pollingInterval ? 5

         @locks = gridLocks.LockCollection @db,
            root: @root
            timeOut: @lockOptions.timeOut
            lockExpiration: @lockOptions.lockExpiration
            pollingInterval: @lockOptions.pollingInterval

         @gfs = new grid(@db, mongodb, @root)

         # Make an index on md5, to support GET requests
         @gfs.files.ensureIndex [['md5', 1]], (err, ret) ->
            throw err if err
         # Make an index on aliases, to support alternative GET requests
         @gfs.files.ensureIndex [['aliases', 1]], (err, ret) ->
            throw err if err

         @baseURL = options.baseURL ? "/gridfs/#{@root}"

         # if there are HTTP options, setup the express HTTP access point(s)
         if options.resumable or options.http
            share.setupHttpAccess.bind(@)(options)

         # Default client allow/deny permissions
         @allows = { insert: [], update: [], remove: [] }
         @denys = { insert: [], update: [], remove: [] }

         # Call super's constructor
         super @root + '.files'

         # Setup specific allow/deny rules for gridFS, and tie-in the application settings

         fileCollection.__super__.allow.bind(@)

            remove: (userId, file) =>

               # call application rules
               if share.check_allow_deny.bind(@) 'remove', userId, file

                  # This causes the file data itself to be removed from gridFS
                  @remove file
                  return true

               return false

            insert: (userId, file) =>

               # Make darn sure we're creating a valid gridFS .files document
               check file,
                  _id: Meteor.Collection.ObjectID
                  length: Match.Where (x) =>
                     check x, Match.Integer
                     x is 0
                  md5: Match.Where (x) =>
                     check x, String
                     x is 'd41d8cd98f00b204e9800998ecf8427e'
                  uploadDate: Date
                  chunkSize: Match.Where (x) =>
                     check x, Match.Integer
                     x is @chunkSize
                  filename: String
                  contentType: String
                  aliases: [ String ]
                  metadata: Object

               # Enforce a uniform chunkSize
               unless file.chunkSize is @chunkSize
                  console.warn "Invalid chunksize"
                  return false

               # call application rules
               if share.check_allow_deny.bind(@) 'insert', userId, file
                  return true

               return false

         fileCollection.__super__.deny.bind(@)

            update: (userId, file, fields) =>

               ## Cowboy updates are not currently allowed from the client. Too much to screw up.
               ## For example, if you store file ownership info in a sub document under 'metadata'
               ## it will be complicated to guard against that being changed if you allow other parts
               ## of the metadata sub doc to be updated. Write specific Meteor methods instead to
               ## allow reasonable changes to the "metadata" parts of the gridFS file record.

               ## WARNING! Only metadata, filename, aliases and contentType should ever be changed
               ## directly by a server or client, e.g. :

               # unless fields.every((x) -> ['metadata', 'aliases', 'filename', 'contentType'].indexOf(x) isnt -1)
               #    return false

               ## call application rules
               # if share.check_allow_deny.bind(@) 'update', userId, file, fields
               #    return true

               return true

      # Register application allow rules
      allow: (allowOptions) ->
         @allows[type].push(func) for type, func of allowOptions when type of @allows

      # Register application deny rules
      deny: (denyOptions) ->
         @denys[type].push(func) for type, func of denyOptions when type of @denys

      insert: (file = {}, callback = undefined) ->
         file = share.insert_func file, @chunkSize
         super file, callback

      # Update is dangerous! The checks inside attempt to keep you out of
      # trouble with gridFS. Clients can't update at all. Be careful!
      update: (selector, modifier, options = {}, callback = undefined) ->
         if not callback? and typeof options is 'function'
            callback = options
            options = {}

         if options.upsert?
            err = new Error("Update does not support the upsert option")
            if callback?
               return callback err
            else
               throw err

         if reject_file_modifier(modifier) and not options.force
            err = new Error("Modifying gridFS read-only document elements is a very bad idea!")
            if callback?
               return callback err
            else
               throw err
         else
            super selector, modifier, options, callback

      upsert: (selector, modifier, options = {}, callback = undefined) ->
         if not callback? and typeof options is 'function'
            callback = options
         err = new Error "File Collections do not support 'upsert'"
         if callback?
            callback err
         else
            throw new Error "File Collections do not support 'upsert'"

      upsertStream: (file, options = {}, callback = undefined) ->
         unless options.mode is 'w' or options.mode is 'w+'
            options.mode = 'w'
         callback = share.bind_env callback
         unless file._id
            id = @insert file
            file = @findOne { _id: id }
         subFile =
            _id: mongodb.ObjectID("#{file._id}")
            filename: file.filename ? ''
            mode: options.mode ? 'w'
            root: @root
            metadata: file.metadata ? {}
            aliases: file.aliases ? []
            content_type: file.contentType ? 'application/octet-stream'
            timeOut: @lockOptions.timeOut
            lockExpiration: @lockOptions.lockExpiration
            pollingInterval: @lockOptions.pollingInterval
         writeStream = Meteor._wrapAsync(@gfs.createWriteStream.bind(@gfs)) subFile
         if callback?
            writeStream.on 'close', (retFile) ->
               callback(null, retFile)
         return writeStream

      findOneStream: (selector, options = {}, callback = undefined) ->
         callback = share.bind_env callback
         file = @findOne selector, { sort: options.sort, skip: options.skip }
         if file
            readStream = Meteor._wrapAsync(@gfs.createReadStream.bind(@gfs))
               root: @root
               _id: mongodb.ObjectID("#{file._id}")
               timeOut: @lockOptions.timeOut
               lockExpiration: @lockOptions.lockExpiration
               pollingInterval: @lockOptions.pollingInterval
            if callback?
               readStream.on 'end', (retFile) ->
                  callback(null, file)
            return readStream
         else
            return null

      remove: (selector, callback = undefined) ->
         callback = share.bind_env callback
         if selector?
            @find(selector).forEach (file) =>
               ret = Meteor._wrapAsync(@gfs.remove.bind(@gfs))({ _id: mongodb.ObjectID("#{file._id}"), root: @root })
            callback? and callback null, ret
         else
            callback? and callback new Error "Remove with an empty selector is not supported"

      importFile: (filePath, file, callback) ->
         callback = share.bind_env callback
         filePath = path.normalize filePath
         file ?= {}
         file.filename ?= path.basename filePath
         readStream = fs.createReadStream filePath
         writeStream = @upsertStream file
         readStream.pipe(writeStream)
            .on('close', share.bind_env((d) -> callback(null, d)))
            .on('error', share.bind_env(callback))

      exportFile: (selector, filePath, callback) ->
         callback = share.bind_env callback
         filePath = path.normalize filePath
         readStream = @findOneStream selector
         writeStream = fs.createWriteStream filePath
         readStream.pipe(writeStream)
            .on('finish', share.bind_env(callback))
            .on('error', share.bind_env(callback))

reject_file_modifier = (modifier) ->

   forbidden = Match.OneOf(
      Match.ObjectIncluding({ _id:        Match.Any })
      Match.ObjectIncluding({ length:     Match.Any })
      Match.ObjectIncluding({ chunkSize:  Match.Any })
      Match.ObjectIncluding({ md5:        Match.Any })
      Match.ObjectIncluding({ uploadDate: Match.Any })
   )

   required = Match.OneOf(
      Match.ObjectIncluding({ _id:         Match.Any })
      Match.ObjectIncluding({ length:      Match.Any })
      Match.ObjectIncluding({ chunkSize:   Match.Any })
      Match.ObjectIncluding({ md5:         Match.Any })
      Match.ObjectIncluding({ uploadDate:  Match.Any })
      Match.ObjectIncluding({ metadata:    Match.Any })
      Match.ObjectIncluding({ aliases:     Match.Any })
      Match.ObjectIncluding({ filename:    Match.Any })
      Match.ObjectIncluding({ contentType: Match.Any })
   )

   console.log "In modifier check", modifier

   return Match.test modifier, Match.OneOf(
      Match.ObjectIncluding({ $set: forbidden })
      Match.ObjectIncluding({ $unset: required})
      Match.ObjectIncluding({ $inc: forbidden})
      Match.ObjectIncluding({ $mul: forbidden})
      Match.ObjectIncluding({ $bit: forbidden})
      Match.ObjectIncluding({ $min: forbidden})
      Match.ObjectIncluding({ $max: forbidden})
      Match.ObjectIncluding({ $rename: required})
      Match.ObjectIncluding({ $currentDate: forbidden})
   )
