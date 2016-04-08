############################################################################
#     Copyright (C) 2014-2016 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

share.defaultChunkSize = 2*1024*1024 - 1024
share.defaultRoot = 'fs'

share.resumableBase = '/_resumable'

share.insert_func = (file = {}, chunkSize) ->
   try
      id = new Mongo.ObjectID("#{file._id}")
   catch
      id = new Mongo.ObjectID()
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

share.reject_file_modifier = (modifier) ->

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
      Match.ObjectIncluding({ $unset: required })
      Match.ObjectIncluding({ $inc: forbidden })
      Match.ObjectIncluding({ $mul: forbidden })
      Match.ObjectIncluding({ $bit: forbidden })
      Match.ObjectIncluding({ $min: forbidden })
      Match.ObjectIncluding({ $max: forbidden })
      Match.ObjectIncluding({ $rename: required })
      Match.ObjectIncluding({ $currentDate: forbidden })
      Match.Where (pat) -> # This requires that the update isn't a replacement
        return not Match.test pat, Match.OneOf(
          Match.ObjectIncluding({ $inc: Match.Any })
          Match.ObjectIncluding({ $set: Match.Any })
          Match.ObjectIncluding({ $unset: Match.Any })
          Match.ObjectIncluding({ $addToSet: Match.Any })
          Match.ObjectIncluding({ $pop: Match.Any })
          Match.ObjectIncluding({ $pullAll: Match.Any })
          Match.ObjectIncluding({ $pull: Match.Any })
          Match.ObjectIncluding({ $pushAll: Match.Any })
          Match.ObjectIncluding({ $push: Match.Any })
          Match.ObjectIncluding({ $bit: Match.Any })
        )
   )
