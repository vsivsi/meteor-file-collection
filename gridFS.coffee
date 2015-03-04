############################################################################
#     Copyright (C) 2014-2015 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

share.defaultChunkSize = 2*1024*1024 - 1
share.defaultRoot = 'fs'

share.insert_func = (file = {}, chunkSize) ->
   try
      id = new Meteor.Collection.ObjectID("#{file._id}")
   catch
      id = new Meteor.Collection.ObjectID()
   subFile = {}
   subFile._id = id
   subFile.length = 0
   subFile.md5 = 'd41d8cd98f00b204e9800998ecf8427e'
   subFile.uploadDate = new Date()
   subFile.chunkSize = chunkSize
   subFile.filename = file.filename ? ''
   subFile.metadata = file.metadata ? {}
   subFile.aliases = file.aliases ? []
   subFile.contentType = file.contentType ? 'application/octet-stream'
   return subFile
