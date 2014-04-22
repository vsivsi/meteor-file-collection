############################################################################
#     Copyright (C) 2014 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isServer

   share.check_allow_deny = (type, userId, file, fields) ->
      console.log "In Client '#{type}' allow: #{file.filename}"
      allowResult = false
      for allowFunc in @allows[type]
         allowResult = allowResult or allowFunc(userId, file, fields)
      denyResult = false
      for denyFunc in @denys[type]
         denyResult = denyResult or denyFunc(userId, file, fields)
      result = allowResult and not denyResult
      console.log "Permission: #{if result then "granted" else "denied"} Allow: #{allowResult} Deny: #{denyResult}"
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