############################################################################
###     Copyright (C) 2014 by Vaughn Iverson
###     fileCollection is free software released under the MIT/X11 license.
###     See included LICENSE file for details.
############################################################################

if Meteor.isServer

   share.check_allow_deny = (type, userId, file, fields) ->
         console.log "In Client '#{type}' allow: #{file.filename}"
         allowResult = false
         allowResult = allowResult or allowFunc(userId, file, fields) for allowFunc in @allows[type]
         denyResult = true
         denyResult = denyResult and denyFunc(userId, file, fields) for denyFunc in @denys[type]
         result = allowResult and denyResult
         console.log "Permission: #{if result then "granted" else "denied"}"
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