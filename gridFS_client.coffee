############################################################################
#     Copyright (C) 2014 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isClient

   class gridFSCollection extends Meteor.Collection

      constructor: (options) ->
         unless @ instanceof gridFSCollection
            return new gridFSCollection(options)

         @chunkSize = options.chunkSize ? share.defaultChunkSize
         @base = options.base ? 'fs'
         @baseURL = options.baseURL ? "/gridfs/#{@base}"
         super @base + '.files'

         # This call sets up the optional support for resumable.js
         # See the resumable.coffee file for more information
         if options.resumable
            share.setup_resumable.bind(@)()

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
