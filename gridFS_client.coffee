
if Meteor.isClient

   class gridFSCollection extends Meteor.Collection

      constructor: (options) ->
         unless @ instanceof gridFSCollection
            return new gridFSCollection(options)

         @chunkSize = options.chunkSize ? share.defaultChunkSize
         @base = options.base ? 'fs'
         @baseURL = options.baseURL ? "/gridfs/#{@base}"
         super @base + '.files'

         if options.resumable
            _setup_resumable.bind(@)()

      # remove works as-is. No modifications necessary so it currently goes straight to super

      upsert: () ->
         throw new Error "GridFS Collections do not support 'upsert' on client"

      update: () ->
         throw new Error "GridFS Collections do not support 'update' on client"

      # Insert only creates an empty (but valid) gridFS file. To put data into it from a client,
      # you need to use an HTTP POST or PUT after the record is inserted. For security reasons,
      # you shouldn't be able to POST or PUT to a file that hasn't been inserted.

      insert: (file, callback = undefined) ->
         # This call ensures that a full gridFS file document
         # gets built from whatever is provided
         file = share.insert_func file, @chunkSize
         super file, callback

   _setup_resumable = () ->
      r = new Resumable
         target: "#{@baseURL}/_resumable"
         generateUniqueIdentifier: (file) -> "#{new Meteor.Collection.ObjectID()}"
         fileParameterName: 'file'
         chunkSize: @chunkSize
         testChunks: true
         simultaneousUploads: 3
         maxFiles: undefined
         maxFilesErrorCallback: undefined
         prioritizeFirstAndLastChunk: false
         query: undefined
         headers: {}

      unless r.support
         console.error "resumable.js not supported by this Browser, uploads will be disabled"
         @resumable = null
      else
         # Autoupdate the token depending on who is logged in
         Deps.autorun () =>
            Meteor.userId()
            r.opts.headers['X-Auth-Token'] = Accounts._storedLoginToken() ? ''
         @resumable = r


