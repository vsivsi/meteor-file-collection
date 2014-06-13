############################################################################
#     Copyright (C) 2014 by Vaughn Iverson
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

   share.find_mime_boundary = (req) ->
      RE_BOUNDARY = /^multipart\/.+?(?:; boundary=(?:(?:"(.+)")|(?:([^\s]+))))$/i
      result = RE_BOUNDARY.exec req.headers['content-type']
      result?[1] or result?[2]