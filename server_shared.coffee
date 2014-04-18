if Meteor.isServer

   share.bind_env = (func) ->
      if func?
         return Meteor.bindEnvironment func, (err) -> throw err
      else
         return func

   share.find_mime_boundary = (req) ->
      RE_BOUNDARY = /^multipart\/.+?(?:; boundary=(?:(?:"(.+)")|(?:([^\s]+))))$/i
      result = RE_BOUNDARY.exec req.headers['content-type']
      result?[1] or result?[2]