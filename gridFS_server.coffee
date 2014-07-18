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

   class FileCollection extends Meteor.Collection

      constructor: (@root = share.defaultRoot, options = {}) ->
         unless @ instanceof FileCollection
            return new FileCollection(@root, options)

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
         @allows = { read: [], insert: [], write: [], remove: [] }
         @denys = { read: [], insert: [], write: [], remove: [] }

         # Call super's constructor
         super @root + '.files', { idGeneration: 'MONGO' }

         # Setup specific allow/deny rules for gridFS, and tie-in the application settings

         FileCollection.__super__.allow.bind(@)
            # Because allow rules are not guaranteed to run,
            # all checking is done in the deny rules below
            insert: (userId, file) => true
            remove: (userId, file) => true

         FileCollection.__super__.deny.bind(@)

            insert: (userId, file) =>

               # Make darn sure we're creating a valid gridFS .files document
               check file,
                  _id: Meteor.Collection.ObjectID
                  length: Match.Where (x) =>
                     check x, Match.Integer
                     x is 0
                  md5: Match.Where (x) =>
                     check x, String
                     x is 'd41d8cd98f00b204e9800998ecf8427e' # The md5 of an empty file
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
                  return true

               # call application rules
               if share.check_allow_deny.bind(@) 'insert', userId, file
                  return false

               return true

            update: (userId, file, fields) =>
               ## Cowboy updates are not currently allowed from the client. Too much to screw up.
               ## For example, if you store file ownership info in a sub document under 'metadata'
               ## it will be complicated to guard against that being changed if you allow other parts
               ## of the metadata sub doc to be updated. Write specific Meteor methods instead to
               ## allow reasonable changes to the "metadata" parts of the gridFS file record.
               return true

            remove: (userId, file) =>
               # call application rules
               if share.check_allow_deny.bind(@) 'remove', userId, file
                  # This causes the file data itself to be removed from gridFS
                  @remove file
                  return false

               return true

      # Register application allow rules
      allow: (allowOptions) ->
         if 'update' of allowOptions
            if allowOptions.write?
               throw new Error 'Specifying both "update" and "write" allow rules is not permitted. Use "write" rules only.'
            allowOptions.write = allowOptions.update
            delete allowOptions.update
            console.warn '***********************************************************************'
            console.warn '** "update" allow/deny rules on fileCollections are now deprecated for'
            console.warn '** use in securing HTTP POST/PUT requests. "write" allow/deny rules'
            console.warn '** should be used instead.'
            console.warn '**'
            console.warn '** As of v0.3.0 all fileCollections implementing "update" allow/deny'
            console.warn '** rules will begin returning 403 errors for POST/PUT requests.'
            console.warn '**'
            console.warn '** See:'
            console.warn '** https://github.com/vsivsi/meteor-file-collection/#fcallowoptions'
            console.warn '***********************************************************************'
         for type, func of allowOptions
            unless type of @allows
               throw new Error "Unrecognized allow rule type '#{type}'."
            unless typeof func is 'function'
               throw new Error "Allow rule #{type} must be a valid function."
            @allows[type].push(func)

      # Register application deny rules
      deny: (denyOptions) ->
         if 'update' of denyOptions
            if denyOptions.write?
               throw new Error 'Specifying both "update" and "write" deny rules is not permitted. Use "write" rules only.'
            denyOptions.write = denyOptions.update
            delete denyOptions.update
            console.warn '***********************************************************************'
            console.warn '** "update" allow/deny rules on fileCollections are now deprecated for'
            console.warn '** use in securing HTTP POST/PUT requests. "write" allow/deny rules'
            console.warn '** should be used instead.'
            console.warn '**'
            console.warn '** As of v0.3.0 all fileCollections implementing "update" allow/deny'
            console.warn '** rules will begin returning 403 errors for POST/PUT requests.'
            console.warn '**'
            console.warn '** See:'
            console.warn '** https://github.com/vsivsi/meteor-file-collection/#fcallowoptions'
            console.warn '***********************************************************************'
         for type, func of denyOptions
            unless type of @denys
               throw new Error "Unrecognized deny rule type '#{type}'."
            unless typeof func is 'function'
               throw new Error "Deny rule #{type} must be a valid function."
            @denys[type].push(func)

      insert: (file = {}, callback = undefined) ->
         file = share.insert_func file, @chunkSize
         super file, callback

      # Update is dangerous! The checks inside attempt to keep you out of
      # trouble with gridFS. Clients can't update at all. Be careful!
      # Only metadata, filename, aliases and contentType should ever be changed
      # directly by a server.

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
         if not callback? and typeof options is 'function'
            callback = options
            options = {}
         unless options.mode is 'w' or options.mode is 'w+'
            options.mode = 'w'
         callback = share.bind_env callback

         mods = {}
         mods.filename = file.filename if file.filename?
         mods.aliases = file.aliases if file.aliases?
         mods.contentType = file.contentType if file.contentType?
         mods.metadata = file.metadata if file.metadata?

         # Make sure that we have an ID and it's valid
         if file._id
            found = @findOne {_id: file._id}

         unless file._id and found
            file._id = @insert mods
         else
            @update { _id: file._id }, { $set: mods }

         writeStream = Meteor._wrapAsync(@gfs.createWriteStream.bind(@gfs))
            root: @root
            _id: mongodb.ObjectID("#{file._id}")
            mode: options.mode ? 'w'
            timeOut: @lockOptions.timeOut
            lockExpiration: @lockOptions.lockExpiration
            pollingInterval: @lockOptions.pollingInterval

         if callback?
            writeStream.on 'close', (retFile) ->
               callback(null, retFile)
         return writeStream

      findOneStream: (selector, options = {}, callback = undefined) ->
         if not callback? and typeof options is 'function'
            callback = options
            options = {}

         callback = share.bind_env callback
         opts = {}
         opts.sort = options.sort if options.sort?
         opts.skip = options.skip if options.skip?
         file = @findOne selector, opts
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

   # Encapsulating class for deprecation warning
   class fileCollection extends FileCollection
      constructor: (r = share.defaultRoot, o = {}) ->
         unless @ instanceof fileCollection
            return new fileCollection(r, o)
         console.warn '******************************************************'
         console.warn '** The "fileCollection" global object is deprecated'
         console.warn '** It will be removed in v0.3.0'
         console.warn '**'
         console.warn '** Use "FileCollection" instead (with capital "F")'
         console.warn '******************************************************'
         super r, o