############################################################################
#     Copyright (C) 2014-2017 by Vaughn Iverson
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

   class FileCollection extends Mongo.Collection

      constructor: (@root = share.defaultRoot, options = {}) ->
         unless @ instanceof FileCollection
            return new FileCollection(@root, options)

         unless @ instanceof Mongo.Collection
            throw new Meteor.Error 'The global definition of Mongo.Collection has changed since the file-collection package was loaded. Please ensure that any packages that redefine Mongo.Collection are loaded before file-collection.'

         unless Mongo.Collection is Mongo.Collection.prototype.constructor
           throw new Meteor.Error 'The global definition of Mongo.Collection has been patched by another package, and the prototype constructor has been left in an inconsistent state. Please see this link for a workaround: https://github.com/vsivsi/meteor-file-sample-app/issues/2#issuecomment-120780592'

         if typeof @root is 'object'
            options = @root
            @root = share.defaultRoot

         @chunkSize = options.chunkSize ? share.defaultChunkSize

         @db = Meteor.wrapAsync(mongodb.MongoClient.connect)(process.env.MONGO_URL, options.mongoOptions ? {})

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

         @baseURL = options.baseURL ? "/gridfs/#{@root}"

         # if there are HTTP options, setup the express HTTP access point(s)
         if options.resumable or options.http
            share.setupHttpAccess.bind(@)(options)

         # Default client allow/deny permissions
         @allows = { read: [], insert: [], write: [], remove: [] }
         @denys = { read: [], insert: [], write: [], remove: [] }

         # Call super's constructor
         super @root + '.files', { idGeneration: 'MONGO' }

         # Default indexes
         if options.resumable
            indexOptions = {}
            if typeof options.resumableIndexName is 'string'
               indexOptions.name = options.resumableIndexName

            @db.collection("#{@root}.files").ensureIndex({
                  'metadata._Resumable.resumableIdentifier': 1
                  'metadata._Resumable.resumableChunkNumber': 1
                  length: 1
               }, indexOptions)

         @maxUploadSize = options.maxUploadSize ? -1  # Negative is no limit...

         ## Delay this feature until demand is clear. Unit tests / documentation needed.

         # unless options.additionalHTTPHeaders? and (typeof options.additionalHTTPHeaders is 'object')
         #    options.additionalHTTPHeaders = {}
         #
         # for h, v of options.additionalHTTPHeaders
         #    share.defaultResponseHeaders[h] = v

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
                  _id: Mongo.ObjectID
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
               ## Remove is now handled via the default method override below, so this should
               ## never be called.
               return true

         self = @ # Necessary in the method definition below

         ## Remove method override for this server-side collection
         Meteor.server.method_handlers["#{@_prefix}remove"] = (selector) ->

            check selector, Object

            unless LocalCollection._selectorIsIdPerhapsAsObject(selector)
               throw new Meteor.Error 403, "Not permitted. Untrusted code may only remove documents by ID."

            cursor = self.find selector

            if cursor.count() > 1
               throw new Meteor.Error 500, "Remote remove selector targets multiple files.\nSee https://github.com/vsivsi/meteor-file-collection/issues/152#issuecomment-278824127"

            [file] = cursor.fetch()

            if file
               if share.check_allow_deny.bind(self) 'remove', this.userId, file
                  return self.remove file
               else
                  throw new Meteor.Error 403, "Access denied"
            else
               return 0

      # Register application allow rules
      allow: (allowOptions) ->
         for type, func of allowOptions
            unless type of @allows
               throw new Meteor.Error "Unrecognized allow rule type '#{type}'."
            unless typeof func is 'function'
               throw new Meteor.Error "Allow rule #{type} must be a valid function."
            @allows[type].push(func)

      # Register application deny rules
      deny: (denyOptions) ->
         for type, func of denyOptions
            unless type of @denys
               throw new Meteor.Error "Unrecognized deny rule type '#{type}'."
            unless typeof func is 'function'
               throw new Meteor.Error "Deny rule #{type} must be a valid function."
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
            err = new Meteor.Error "Update does not support the upsert option"
            if callback?
               return callback err
            else
               throw err

         if share.reject_file_modifier(modifier) and not options.force
            err = new Meteor.Error "Modifying gridFS read-only document elements is a very bad idea!"
            if callback?
               return callback err
            else
               throw err
         else
            super selector, modifier, options, callback

      upsert: (selector, modifier, options = {}, callback = undefined) ->
         if not callback? and typeof options is 'function'
            callback = options
         err = new Meteor.Error "File Collections do not support 'upsert'"
         if callback?
            callback err
         else
            throw err

      upsertStream: (file, options = {}, callback = undefined) ->
         if not callback? and typeof options is 'function'
            callback = options
            options = {}
         callback = share.bind_env callback
         cbCalled = false
         mods = {}
         mods.filename = file.filename if file.filename?
         mods.aliases = file.aliases if file.aliases?
         mods.contentType = file.contentType if file.contentType?
         mods.metadata = file.metadata if file.metadata?

         options.autoRenewLock ?= true

         if options.mode is 'w+'
            throw new Meteor.Error "The ability to append file data in upsertStream() was removed in version 1.0.0"

         # Make sure that we have an ID and it's valid
         if file._id
            found = @findOne {_id: file._id}

         unless file._id and found
            file._id = @insert mods
         else if Object.keys(mods).length > 0
            @update { _id: file._id }, { $set: mods }

         writeStream = Meteor.wrapAsync(@gfs.createWriteStream.bind(@gfs))
            root: @root
            _id: mongodb.ObjectID("#{file._id}")
            mode: 'w'
            timeOut: @lockOptions.timeOut
            lockExpiration: @lockOptions.lockExpiration
            pollingInterval: @lockOptions.pollingInterval

         if writeStream

            if options.autoRenewLock
               writeStream.on 'expires-soon', () =>
                  writeStream.renewLock (e, d) ->
                     if e or not d
                        console.warn "Automatic Write Lock Renewal Failed: #{file._id}", e

            if callback?
               writeStream.on 'close', (retFile) ->
                  if retFile
                     retFile._id = new Mongo.ObjectID retFile._id.toHexString()
                     callback(null, retFile)
               writeStream.on 'error', (err) ->
                  callback(err)

            return writeStream

         return null

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
            options.autoRenewLock ?= true

            # Init the start and end range, default to full file or start/end as specified
            range =
               start: options.range?.start ? 0
               end: options.range?.end ? file.length - 1

            readStream = Meteor.wrapAsync(@gfs.createReadStream.bind(@gfs))
               root: @root
               _id: mongodb.ObjectID("#{file._id}")
               timeOut: @lockOptions.timeOut
               lockExpiration: @lockOptions.lockExpiration
               pollingInterval: @lockOptions.pollingInterval
               range:
                 startPos: range.start
                 endPos: range.end

            if readStream
               if options.autoRenewLock
                  readStream.on 'expires-soon', () =>
                     readStream.renewLock (e, d) ->
                        if e or not d
                           console.warn "Automatic Read Lock Renewal Failed: #{file._id}", e

               if callback?
                  readStream.on 'close', () ->
                     callback(null, file)
                  readStream.on 'error', (err) ->
                     callback(err)
               return readStream

         return null

      remove: (selector, callback = undefined) ->
         callback = share.bind_env callback
         if selector?
            ret = 0
            @find(selector).forEach (file) =>
               res = Meteor.wrapAsync(@gfs.remove.bind(@gfs))
                  _id: mongodb.ObjectID("#{file._id}")
                  root: @root
                  timeOut: @lockOptions.timeOut
                  lockExpiration: @lockOptions.lockExpiration
                  pollingInterval: @lockOptions.pollingInterval
               ret += if res then 1 else 0
            callback? and callback null, ret
            return ret
         else
            err = new Meteor.Error "Remove with an empty selector is not supported"
            if callback?
               callback err
               return
            else
               throw err

      importFile: (filePath, file, callback) ->
         callback = share.bind_env callback
         filePath = path.normalize filePath
         file ?= {}
         file.filename ?= path.basename filePath
         readStream = fs.createReadStream filePath
         readStream.on('error', share.bind_env(callback))
         writeStream = @upsertStream file
         readStream.pipe(share.streamChunker(@chunkSize)).pipe(writeStream)
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
