############################################################################
#     Copyright (C) 2014-2015 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isClient

   class FileCollection extends Mongo.Collection

      constructor: (@root = share.defaultRoot, options = {}) ->
         unless @ instanceof FileCollection
            return new FileCollection(root, options)

         unless @ instanceof Mongo.Collection
            throw new Error 'The global definition of Mongo.Collection has changed since the file-collection package was loaded. Please ensure that any packages that redefine Mongo.Collection are loaded before file-collection.'

         unless Mongo.Collection is Mongo.Collection.prototype.constructor
           throw new Error 'The global definition of Mongo.Collection has been patched by another package, and the prototype constructor has been left in an inconsistent state. Please see this link for a workaround: https://github.com/vsivsi/meteor-file-sample-app/issues/2#issuecomment-120780592'

         if typeof @root is 'object'
            options = @root
            @root = share.defaultRoot

         @base = @root
         @baseURL = options.baseURL ? "/gridfs/#{@root}"
         @chunkSize = options.chunkSize ? share.defaultChunkSize
         super @root + '.files', { idGeneration: 'MONGO' }

         # This call sets up the optional support for resumable.js
         # See the resumable.coffee file for more information
         if options.resumable
            share.setup_resumable.bind(@)()

      # remove works as-is. No modifications necessary so it currently goes straight to super

      # Insert only creates an empty (but valid) gridFS file. To put data into it from a client,
      # you need to use an HTTP POST or PUT after the record is inserted. For security reasons,
      # you shouldn't be able to POST or PUT to a file that hasn't been inserted.

      insert: (file, callback = undefined) ->
         # This call ensures that a full gridFS file document
         # gets built from whatever is provided
         file = share.insert_func file, @chunkSize
         super file, callback

      # This will only update the local client-side minimongo collection
      # You can shadow update with this to enable latency compensation when
      # updating the server-side collection using a Meteor method call
      localUpdate: (selector, modifier, options = {}, callback = undefined) ->
         if not callback? and typeof options is 'function'
            callback = options
            options = {}

         if options.upsert?
            err = new Error "Update does not support the upsert option"
            if callback?
               return callback err
            else
               throw err

         if share.reject_file_modifier(modifier)
            err = new Error "Modifying gridFS read-only document elements is a very bad idea!"
            if callback?
               return callback err
            else
               throw err
         else
            @find().collection.update selector, modifier, options, callback

      allow: () ->
        throw new Error "File Collection Allow rules may not be set in client code."

      deny: () ->
        throw new Error "File Collection Deny rules may not be set in client code."

      upsert: () ->
         throw new Error "File Collections do not support 'upsert'"

      update: () ->
         throw new Error "File Collections do not support 'update' on client, use method calls instead"

      findOneStream: () ->
         throw new Error "File Collections do not support 'findOneStream' in client code."

      upsertStream: () ->
         throw new Error "File Collections do not support 'upsertStream' in client code."

      importFile: () ->
         throw new Error "File Collections do not support 'importFile' in client code."

      exportFile: () ->
         throw new Error "File Collections do not support 'exportFile' in client code."
