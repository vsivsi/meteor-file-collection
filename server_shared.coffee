############################################################################
#     Copyright (C) 2014-2015 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isServer

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
