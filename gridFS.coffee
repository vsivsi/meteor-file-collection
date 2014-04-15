if Meteor.isServer

   mongodb = Npm.require 'mongodb'
   grid = Npm.require 'gridfs-locking-stream'
   gridLocks = Npm.require 'gridfs-locks'
   fs = Npm.require 'fs'
   path = Npm.require 'path'
   dicer = Npm.require 'dicer'

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

      _find_mime_boundary: (req) ->
         RE_BOUNDARY = /^multipart\/.+?(?:; boundary=(?:(?:"(.+)")|(?:([^\s]+))))$/i
         result = RE_BOUNDARY.exec req.headers['content-type']
         result[1] or result[2]

      _dice_multipart: (req, callback) ->
         callback = @_bind_env callback
         boundary = @_find_mime_boundary req

         resumable = {}
         resCount = 0
         fileStream = null

         d = new dicer { boundary: boundary }

         d.on 'part', (p) ->

            console.log('New part!')

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
                           console.log('Resumable Part #{resVar} data: ' + resData)
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
                        console.log "Filestream!"
                        fileStream = p
                        if resCount is 0
                           callback(null, resumable, fileStream)

         d.on 'error', (err) ->
           console.log('Error in Dicer: \n', err)
           callback err

         d.on 'finish', () ->
            console.log('End of parts')
            unless fileStream
               callback(new Error "No file blob in multipart POST")

         req.pipe(d)

      _get: (req, res, next) ->
         console.log "Cowboy!", req.method
         next()

      _post: (req, res, next) ->
         console.log "Cowboy!", req.method

         @_dice_multipart req, (err, resumable, fileStream) =>
            if err
               res.writeHead(500)
               res.end('Form submission unsuccessful!')
               return
            else
               console.log "From Resumable:" + JSON.stringify (resumable)
               unless resumable
                  res.writeHead(500)
                  res.end('Form submission unsuccessful!')
                  return

               # See if this file already exists in some form
               file = gridFS.__super__.findOne.bind(@)({ _id: new Meteor.Collection.ObjectID("#{resumable.resumableIdentifier}") })
               lastChunk = false

               unless file
                  res.writeHead(404)
                  res.end('Upload document not found!')
                  return

               # Shortcut for last chunk of a contiguous file, just write it!
               if ((resumable.resumableChunkNumber is resumable.resumableTotalChunks is 1) or
                   (file.metadata?._Resumable?.resumableChunkNumber + 1 is resumable.resumableChunkNumber is resumable.resumableTotalChunks))
                  delete file.metadata._Resumable
                  console.log "Upserting last chunk", file
                  lastChunk = true
                  writeStream = @upsert { _id: new mongodb.ObjectID(resumable.resumableIdentifier), metadata : file.metadata }

               # Next chunk of a contiguous file
               else if ((resumable.resumableChunkNumber is 1) or
                        (file.metadata?._Resumable?.resumableChunkNumber + 1 is resumable.resumableChunkNumber))
                  file.metadata._Resumable = resumable
                  console.log "Upserting next chunk", file
                  writeStream = @upsert { _id: new mongodb.ObjectID(resumable.resumableIdentifier), metadata : file.metadata }

               # Out of order chunk of a file, stash it...
               else
                  console.log "Upserting OOO chunk", file
                  writeStream = @upsert
                     filename: "_Resumable_#{resumable.resumableIdentifier}_#{resumable.resumableChunkNumber}_#{resumable.resumableTotalChunks}"
                     metadata:
                        _Resumable: resumable

               unless writeStream
                  res.writeHead(500)
                  res.end('Form submission unsuccessful!')
                  return

               console.log "Piping!"
               try
                  fileStream.pipe(writeStream)
                     .on 'close', @_bind_env((file) =>
                        console.log "Piping Close!"
                        res.writeHead(200)
                        res.end('Form submission successful!')
                        unless lastChunk
                          @_check_order(file)
                        )
                     .on 'error', @_bind_env((err) =>
                        console.log "Piping Error!", err
                        res.writeHead(500)
                        res.end('Form submission unsuccessful!'))
               catch err
                  console.error "Caught during pipe", err
                  console.trace()

      _check_order: (file) ->
         console.log "Checking the order of chunks for processing...", file
         fileId = new mongodb.ObjectID file.metadata._Resumable.resumableIdentifier
         console.log "fileId: #{fileId}"
         lock = gridLocks.Lock fileId, @locks, {}
         lock.obtainWriteLock()
         lock.on 'locked', @_bind_env(() =>
            OOO_arr = @find({_id: {$ne: fileId}, 'metadata._Resumable.resumableIdentifier': file.metadata._Resumable.resumableIdentifier},
                            { sort: { 'metadata._Resumable.resumableChunkNumber': 1 }}).fetch()
            console.log "Found #{OOO_arr.length} OOO parts"
            if OOO_arr.length > 0
               mainfile = gridFS.__super__.findOne.bind(@)({ _id: fileId })
               if mainfile
                  console.log "Found mainfile, which has #{mainfile.metadata._Resumable.resumableChunkNumber} parts"
                  if mainfile.metadata._Resumable.resumableChunkNumber + OOO_arr.length is mainfile.metadata._Resumable.resumableTotalChunks
                     # Manipulate the chunks and files collections directly under write lock
                     console.log "Start reassembling the file!!!!"

                     chunks = @db.collection "#{@base}.chunks"
                     files = @db.collection "#{@base}.files"

                     # go through all of the OOO uploaded parts and reassign them
                     for part, i in OOO_arr
                        # console.log part._id
                        partId = new mongodb.ObjectID part._id._str
                        if i isnt part.metadata._Resumable.resumableChunkNumber - mainfile.metadata._Resumable.resumableChunkNumber - 1
                           throw "WTF Chunk numbers!"
                        chunks.update { files_id: partId, n: 0 }, { $set: { files_id: fileId, n: part.metadata._Resumable.resumableChunkNumber - 1 }}, (err, res) => console.log "Updated", err, res
                        files.remove { _id: partId }, (err, res) => console.log "removed", err, res

                     # check for a hanging chunk
                     chunks.update { files_id: partId, n: 1 }, { $set: { files_id: fileId, n: part.metadata._Resumable.resumableChunkNumber }}, (err, res) => console.log "Last bit updated", err, res

                     totalSize = mainfile.metadata._Resumable.resumableTotalSize
                     delete mainfile.metadata._Resumable
                     files.update { _id: fileId }, { $set: { length: totalSize, metadata: mainfile.metadata }}, (err, res) => console.log "file updated", err, res

            lock.releaseLock()
         )
         lock.on 'timed-out', @_bind_env(() => console.error "Lock timed out")

      _put: (req, res, next) ->
         console.log "Cowboy!", req.method

         writeStream = fs.createWriteStream '/Users/vsi/uploads/put.txt'
         req.pipe(writeStream)
            .on 'finish', () ->
               res.writeHead(200)
               res.end("'k thx bye!")

      _delete: (req, res, next) ->
         console.log "Cowboy!", req.method
         next()

      _connect_gridfs: (req, res, next) ->
         switch req.method
            when 'GET' then @_get(req, res, next)
            when 'HEAD' then @_get(req, res, next)
            when 'POST' then @_post(req, res, next)
            when 'PUT' then @_put(req, res, next)
            when 'DELETE' then @_delete(req, res, next)
            else
               console.log "Bad method ", req.method
               next()

      _access_point: (url) ->
         app = WebApp.rawConnectHandlers
         app.use(url, @_bind_env(@_connect_gridfs.bind(@)))

      constructor: (@base, @baseURL) ->
         console.log "Making a gridFS collection!"

         @base ?= 'fs'
         @baseURL ?= "/gridfs/#{@base}"

         @_access_point(@baseURL)

         @db = Meteor._wrapAsync(mongodb.MongoClient.connect)(process.env.MONGO_URL,{})
         @locks = gridLocks.LockCollection @db, { root: @base, timeOut: 180, lockExpiration: 90 }
         @gfs = new grid(@db, mongodb, @base)
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

      insert: (file, callback = undefined) ->
         # if file._id
         #    id = new Meteor.Collection.ObjectID("#{file._id}")
         # else
         #    id = new Meteor.Collection.ObjectID()
         if file._id
            id = new mongodb.ObjectID("#{file._id}")
         else
            id = new mongodb.ObjectID()
         subFile = {}
         subFile._id = id
         subFile.length = 0
         subFile.md5 = 'd41d8cd98f00b204e9800998ecf8427e'
         subFile.uploadDate = new Date()
         subFile.chunkSize = file.chunkSize or @chunkSize
         subFile.filename = file.filename if file.filename?
         subFile.metadata = file.metadata or {}
         subfile.aliases = file.aliases if file.aliases?
         subFile.contentType = file.contentType if file.contentType?
         console.log "About to insert"
         super subFile, callback

      upsert: (file, options = {}, callback = undefined) ->

         callback = @_bind_env callback

         unless file._id
            console.log "@@@ Fresh insert for ", file
            id = @insert file
            file = gridFS.__super__.findOne.bind(@)({ _id: id })
            # file._id = new Meteor.Collection.ObjectID("#{file._id}")
            # file._id = id
            # file = gridFS.__super__.findOne.bind(@)({ _id: new Meteor.Collection.ObjectID("#{file._id}") })

         console.log "File: ", file

         subFile =
            # _id: "#{file._id}"
            _id: file._id
            mode: 'w+'
            root: @base
            metadata: file.metadata ? {}
            timeOut: 30

         console.log "upsert: ", subFile

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
               _id: "#{file._id}"
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
            simultaneousUploads: 3
            prioritizeFirstAndLastChunk: true
            headers:
               'X-Auth-Token': Accounts._storedLoginToken() or ''

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
                  chunkSize: @chunkSize
                  metadata:
                     owner: Meteor.userId() ? null
                     _Resumable: { }
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
         subFile.metadata = file.metadata or {}
         subFile.contentType = file.contentType if file.contentType?
         super subFile, callback

