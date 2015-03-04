############################################################################
#     Copyright (C) 2014 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isServer

   express = Npm.require 'express'
   cookieParser = Npm.require 'cookie-parser'
   mongodb = Npm.require 'mongodb'
   grid = Npm.require 'gridfs-locking-stream'
   gridLocks = Npm.require 'gridfs-locks'
   dicer = Npm.require 'dicer'

   # Fast MIME Multipart parsing of generic HTTP POST request bodies

   dice_multipart = (req, callback) ->
      callback = share.bind_env callback
      boundary = share.find_mime_boundary req

      unless boundary
         err = new Error('No MIME multipart boundary found for dicer')
         return callback err

      params = {}
      param = ''
      count = 0
      fileStream = null
      fileType = 'text/plain'
      fileName = 'blob'
      data = ''

      d = new dicer { boundary: boundary }

      d.on 'part', (p) ->
         console.log "Part!"
         p.on 'header', (header) ->
            console.log "Header!"
            RE_FILE = /^form-data; name="file"; filename="([^"]+)"/
            RE_PARAM = /^form-data; name="([^"]+)"/
            for k, v of header
               console.log "K: #{k} V: #{v}"
               if k is 'content-type'
                  fileType = v
               if k is 'content-disposition'
                  if re = RE_FILE.exec(v)
                     fileStream = p
                     fileName = re[1]
                     console.log "File stream!"
                  else if param = RE_PARAM.exec(v)?[1]
                     console.log "Param!", param
                     data = ''
                     count++
                     p.on 'data', (d) ->
                        console.log "Got some part data! #{d}"
                        data += d.toString()
                     p.on 'end', () ->
                        count--
                        console.log "End of part!"
                        params[param] = data
                     p.on 'error', (err) ->
                        console.error('Error in Dicer while part streaming: \n', err)
                        callback err

            if count is 0 and fileStream
               params._fileType = fileType
               params._fileName = fileName
               params._fileStream = fileStream
               callback null, params

      d.on 'error', (err) ->
         callback err

      d.on 'finish', () ->
         console.log "Finishing!", params
         unless fileStream
            callback(new Error "No file in multipart POST")

      req.pipe(d)

   # Handle a generic HTTP POST file upload

   # This curl command should be properly handled by this code:
   # % curl -X POST 'http://127.0.0.1:3000/gridfs/fs/38a14c8fef2d6cef53c70792' \
   #        -F 'file=@"universe.png";type=image/png' -H 'X-Auth-Token: zrtrotHrDzwA4nC5'

   post = (req, res, next) ->

      # Parse MIME Multipart request body
      dice_multipart req, (err, params) =>
         if err
            console.warn('Error parsing POST body', err)
            res.writeHead(500)
            res.end()
            return

         # Handle filename or filetype data when included
         req.gridFS.contentType = params._fileType if params._fileType
         req.gridFS.filename = params._fileName if params._fileName

         # Write the file data.  No chunks here, this is the whole thing
         stream = @upsertStream req.gridFS
         if stream
            params._fileStream.pipe(stream)
               .on 'close', (retFile) ->
                  if retFile
                     res.writeHead(200)
                     res.end()
               .on 'error', (err) ->
                  res.writeHead(500)
                  res.end()
         else
            res.writeHead(410)
            res.end()

   # Handle a generic HTTP GET request
   # This also handles HEAD requests
   # If the request URL has a "?download=true" query, then a browser download response is triggered

   get = (req, res, next) ->

      # If range request in the header
      if req.headers['range']
        # Set status code to partial data
        statusCode = 206

        # Pick out the range required by the browser
        parts = req.headers["range"].replace(/bytes=/, "").split("-")
        start = parseInt(parts[0], 10)
        end = (if parts[1] then parseInt(parts[1], 10) else req.gridFS.length - 1)

        # Unable to handle range request - Send the valid range with status code 416
        if (start < 0) or (end >= req.gridFS.length) or (start > end) or isNaN(start) or isNaN(end)
          res.writeHead 416, 'Content-Range': 'bytes ' + '*/' + req.gridFS.length
          res.end()
          return

        # Determine the chunk size
        chunksize = (end - start) + 1

        # Construct the range request header
        headers =
            'Content-Range': 'bytes ' + start + '-' + end + '/' + req.gridFS.length
            'Accept-Ranges': 'bytes'
            'Content-type': req.gridFS.contentType
            'Content-Length': chunksize
            'Last-Modified': req.gridFS.uploadDate.toUTCString()

        # Read the partial request from gridfs stream
        stream = @findOneStream(
          _id: req.gridFS._id
        ,
          range:
            start: start
            end: end
        )

      # Otherwise prepare to stream the whole file
      else
        # Set default status code
        statusCode = 200

        # Set default headers
        headers =
            'Content-type': req.gridFS.contentType
            'Content-MD5': req.gridFS.md5
            'Content-Length': req.gridFS.length
            'Last-Modified': req.gridFS.uploadDate.toUTCString()

        # Open file to stream
        stream = @findOneStream { _id: req.gridFS._id }

      # Trigger download in browser, optionally specify filename.
      if (req.query.download and req.query.download.toLowerCase() == 'true') or req.query.filename
        filename = req.query.filename ? req.gridFS.filename
        headers['Content-Disposition'] = "attachment; filename=\"#{filename}\""

      # If specified in url query set cache to specified value, might want to add more options later.
      if req.query.cache and not isNaN(parseInt(req.query.cache))
        headers['Cache-Control'] = "max-age=" + parseInt(req.query.cache)+", private"

      # HEADs don't have a body
      if req.method is 'HEAD'
        res.writeHead 204, headers
        res.end()
        return

      # Stream file
      if stream
         res.writeHead statusCode, headers
         stream.pipe(res)
            .on 'close', () ->
               res.end()
            .on 'error', (err) ->
               res.writeHead(500)
               res.end(err)
      else
         res.writeHead(410)
         res.end()

   # Handle a generic HTTP PUT request

   # This curl command should be properly handled by this code:
   # % curl -X PUT 'http://127.0.0.1:3000/gridfs/fs/7868f3df8425ae68a572b334' \
   #        -T "universe.png" -H 'Content-Type: image/png' -H 'X-Auth-Token: tEPAwXbGwgfGiJL35'

   put = (req, res, next) ->

      # Handle content type if it's present
      if req.headers['content-type']
         req.gridFS.contentType = req.headers['content-type']

      # Write the file
      stream = @upsertStream req.gridFS
      if stream
         req.pipe(stream)
            .on 'close', (retFile) ->
               if retFile
                  res.writeHead(200)
                  res.end()
            .on 'error', (err) ->
               res.writeHead(500)
               res.end(err)
      else
         res.writeHead(404)
         res.end("#{req.url} Not found!")

   # Handle a generic HTTP DELETE request

   # This curl command should be properly handled by this code:
   # % curl -X DELETE 'http://127.0.0.1:3000/gridfs/fs/7868f3df8425ae68a572b334' \
   #        -H 'X-Auth-Token: tEPAwXbGwgfGiJL35'

   del = (req, res, next) ->

      @remove req.gridFS
      res.writeHead(204)
      res.end()

   # Setup all of the application specified paths and file lookups in express
   # Also performs allow/deny permission checks for POST/PUT/DELETE

   build_access_point = (http) ->

      # Loop over the app supplied http paths
      for r in http

         # Add an express middleware for each application REST path
         @router[r.method] r.path, (req, res, next) =>

           safeObjectID = (s) ->
              if s.match /^[0-9a-f]{24}$/i  # Validate that _id is a 12 byte hex string
                 new Meteor.Collection.ObjectID s
              else
                 null

           # params and queries literally named "_id" get converted to ObjectIDs automatically
           req.params._id = safeObjectID(req.params._id) if req.params?._id?
           req.query._id = safeObjectID(req.query._id) if req.query?._id?

           # Build the path lookup mongoDB query object for the gridFS files collection
           lookup = r.lookup? req.params or {}, req.query or {}
           unless lookup?
              # No lookup returned, so bailing
              res.writeHead(500)
              res.end()
              return
           else
              # Perform the collection query
              req.gridFS = @findOne lookup
              unless req.gridFS
                 res.writeHead(404)
                 res.end()
                 return

              # Make sure that the requested method is permitted for this file in the allow/deny rules
              switch req.method
                 when 'HEAD', 'GET'
                    unless share.check_allow_deny.bind(@) 'read', req.meteorUserId, req.gridFS
                       res.writeHead(403)
                       res.end()
                       return
                 when 'POST', 'PUT'
                    unless share.check_allow_deny.bind(@) 'write', req.meteorUserId, req.gridFS
                       res.writeHead(403)
                       res.end()
                       return
                 when 'DELETE'
                    unless share.check_allow_deny.bind(@) 'remove', req.meteorUserId, req.gridFS
                       res.writeHead(403)
                       res.end()
                       return
                 else
                    res.writeHead(500)
                    res.end()
                    return

              next()

      @router.route('/*')
         .all (req, res, next) ->  # Make sure a file has been selected by some rule
            unless req.gridFS
               res.writeHead(404)
               res.end()
               return
            next()

      # Loop over the app supplied http paths
      for r in http when typeof http.handler is 'function'
         # Add an express middleware for each custom request handler
         @router[r.method] r.path, http.handler.bind(@)

      # Add all of generic request handling methods to the express route
      @router.route('/*')
         .head(get.bind(@))   # Generic HTTP method handlers
         .get(get.bind(@))
         .put(put.bind(@))
         .post(post.bind(@))
         .delete(del.bind(@))
         .all (req, res, next) ->   # Unkown methods are denied
            res.writeHead(500)
            res.end()

   # Performs a meteor userId lookup by hased access token

   lookup_userId_by_token = (authToken) ->
      userDoc = Meteor.users?.findOne
         'services.resume.loginTokens':
            $elemMatch:
               hashedToken: Accounts?._hashLoginToken(authToken)
      return userDoc?._id or null

   # Express middleware to convert a Meteor access token provided in an HTTP request
   # to a Meteor userId attached to the request object as req.meteorUserId

   handle_auth = (req, res, next) ->
      unless req.meteorUserId?
         # Lookup userId if token is provided in HTTP heder
         if req.headers?['x-auth-token']?
            req.meteorUserId = lookup_userId_by_token req.headers['x-auth-token']
         # Or as a URL query of the same name
         else if req.cookies?['X-Auth-Token']?
            req.meteorUserId = lookup_userId_by_token req.cookies['X-Auth-Token']
         else
            req.meteorUserId = null
      next()

   # Set up all of the middleware, including optional support for Resumable.js chunked uploads
   share.setupHttpAccess = (options) ->
         r = express.Router()
         r.use express.query()   # Parse URL query strings
         r.use cookieParser()    # Parse cookies
         r.use handle_auth       # Turn x-auth-tokens into Meteor userIds
         WebApp.rawConnectHandlers.use(@baseURL, share.bind_env(r))

         # Set up support for resumable.js if requested
         if options.resumable
            options.http = share.resumable_paths.concat options.http

         # Setup application HTTP REST interface
         @router = express.Router()
         build_access_point.bind(@)(options.http, @router)
         WebApp.rawConnectHandlers.use(@baseURL, share.bind_env(@router))
