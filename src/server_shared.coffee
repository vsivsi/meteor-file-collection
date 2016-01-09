############################################################################
#     Copyright (C) 2014-2016 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isServer

   through2 = Npm.require 'through2'

   share.defaultResponseHeaders =
      'Content-Type': 'text/plain'

   share.check_allow_deny = (type, userId, file, fields) ->

      checkRules = (rules) ->
         res = false
         for func in rules[type] when not res
            res = func(userId, file, fields)
         return res

      result = not checkRules(@denys) and checkRules(@allows)
      return result

   share.bind_env = (func) ->
      if func?
         return Meteor.bindEnvironment func, (err) -> throw err
      else
         return func

   share.safeObjectID = (s) ->
      if s?.match /^[0-9a-f]{24}$/i  # Validate that _id is a 12 byte hex string
         new Mongo.ObjectID s
      else
         null

   share.streamChunker = (size = share.defaultChunkSize) ->
      makeFuncs = (size) ->
         bufferList = [ new Buffer(0) ]
         total = 0
         flush = (cb) ->
            outSize = if total > size then size else total
            if outSize > 0
               outputBuffer = Buffer.concat bufferList, outSize
               this.push outputBuffer
               total -= outSize
            lastBuffer = bufferList.pop()
            newBuffer = lastBuffer.slice(lastBuffer.length - total)
            bufferList = [ newBuffer ]
            if total < size
               cb()
            else
               flush.bind(this) cb
         transform = (chunk, enc, cb) ->
            bufferList.push chunk
            total += chunk.length
            if total < size
               cb()
            else
               flush.bind(this) cb
         return [transform, flush]
      return through2.apply this, makeFuncs(size)
