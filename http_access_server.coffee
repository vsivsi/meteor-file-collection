
if Meteor.isServer

   express = Npm.require 'express'
   mongodb = Npm.require 'mongodb'
   grid = Npm.require 'gridfs-locking-stream'
   gridLocks = Npm.require 'gridfs-locks'
   dicer = Npm.require 'dicer'

   dice_multipart = (req, callback) ->
      callback = share.bind_env callback
      boundary = share.find_mime_boundary req

      unless boundary
        err = new Error('No MIME multipart boundary found for dicer')
        return callback err

      fileStream = null

      d = new dicer { boundary: boundary }

      d.on 'part', (p) ->
         p.on 'header', (header) ->
            RE_FILE = /^form-data; name="file"; filename="([^"]+)"/
            for k, v of header
               console.log "Part header: k: #{k}, v: #{v}"
               if k is 'content-type'
                  ft = v
               if k is 'content-disposition'
                  if re = RE_FILE.exec(v)
                     fileStream = p
                     console.log "Parsing this shit!", v
                     fn = re[1]
            callback(null, fileStream, fn, ft)

      d.on 'error', (err) ->
        console.log('Error in Dicer: \n', err)
        callback err

      d.on 'finish', () ->
         unless fileStream
            callback(new Error "No file in multipart POST")

      req.pipe(d)

   post = (req, res, next) ->
      console.log "Cowboy!", req.method, req.gridFS, req.headers

      unless @_check_allow_deny 'update', req.meteorUserId, req.gridFS, ['length', 'md5']
         res.writeHead(404)
         res.end("#{req.url} Not found!")
         return

      dice_multipart req, (err, fileStream, filename, filetype) =>
         if err
            res.writeHead(500)
            res.end()
            return
         console.log "filename: #{filename} filetype: #{filetype}"

         if filename or filetype
            set = {}
            set.contentType = filetype if filetype
            set.filename = filename if filename
            @update { _id: req.gridFS._id }, { $set: set }

         stream = @upsert req.gridFS
         if stream
            fileStream.pipe(stream)
               .on 'close', () ->
                  console.log "Closing the stream..."
                  res.writeHead(200)
                  res.end()
               .on 'error', (err) ->
                  res.writeHead(500)
                  res.end(err)
         else
            res.writeHead(410)
            res.end("Gone!")

   get = (req, res, next) ->
      console.log "Cowboy!", req.method, req.gridFS

      headers =
         'Content-type': req.gridFS.contentType
         'Content-MD5': req.gridFS.md5
         'Content-Length': req.gridFS.length
         'Last-Modified': req.gridFS.uploadDate.toUTCString()

      if req.query.download
         headers['Content-Disposition'] = "attachment; filename=\"#{req.gridFS.filename}\""

      if req.method is 'HEAD'
         res.writeHead 204, headers
         res.end()
         return

      stream = @findOne { _id: req.gridFS._id }
      if stream
         res.writeHead 200, headers
         stream.pipe(res)
               .on 'close', () ->
                  res.end()
               .on 'error', (err) ->
                  res.writeHead(500)
                  res.end(err)
      else
         res.writeHead(410)
         res.end("#{req.url} Gone!")

   put = (req, res, next) ->

      console.log "Cowboy!", req.method, req.gridFS

      unless @_check_allow_deny 'update', req.meteorUserId, req.gridFS, ['length', 'md5']
         res.writeHead(404)
         res.end("#{req.url} Not found!")
         return

      if req.headers['content-type']
         @update { _id: req.gridFS._id }, { $set: { contentType: req.headers['content-type'] }}

      stream = @upsert req.gridFS
      if stream
         req.pipe(stream)
            .on 'close', () ->
               res.writeHead(200)
               res.end()
            .on 'error', (err) ->
               res.writeHead(500)
               res.end(err)
      else
         res.writeHead(404)
         res.end("#{req.url} Not found!")

   del = (req, res, next) ->
      console.log "Cowboy!", req.method, req.gridFS

      unless @_check_allow_deny 'remove', req.meteorUserId, req.gridFS
         res.writeHead(404)
         res.end("#{req.url} Not found!")
         return

      @remove req.gridFS
      res.writeHead(204)
      res.end()

   build_access_point = (http, route) ->

      for r in http
         route[r.method] r.path, do (r) =>
            (req, res, next) =>
               console.log "Params", req.params
               console.log "Queries: ", req.query
               console.log "Method: ", req.method

               req.params._id = new Meteor.Collection.ObjectID("#{req.params._id}") if req.params?._id?
               req.query._id = new Meteor.Collection.ObjectID("#{req.query._id}") if req.query?._id?

               q = r.query req.meteorUserId, req.params or {}, req.query or {}
               console.log "finding One, query:", JSON.stringify(q,false,1)
               unless q?
                  console.log "No query returned, so passing"
                  next()
               else
                  try
                     req.gridFS = gridFSCollection.__super__.findOne.bind(@)(q)
                     if req.gridFS
                        console.log "Found file #{req.gridFS._id}"
                        next()
                     else
                        res.writeHead(404)
                        res.end()
                  catch
                     res.writeHead(404)
                     res.end()

      route.route('/*')
         .head(get.bind(@))
         .get(get.bind(@))
         .put(put.bind(@))
         .post(post.bind(@))
         .delete(del.bind(@))
         .all (req, res, next) ->
            res.writeHead(404)
            res.end()

   # Performs a meteor userId lookup by hased access token

   lookup_userId_by_token = (authToken) ->
      userDoc = Meteor.users.findOne
         'services.resume.loginTokens':
            $elemMatch:
               hashedToken: Accounts._hashLoginToken(authToken)
      return userDoc?._id or null

   # Express middleware to convert a Meteor access token provided in an HTTP request
   # to a Meteor userId attached to the request object as req.meteorUserId

   handle_auth = (req, res, next) ->
      unless req.meteorUserId?
         # Lookup userId if token is provided in HTTP heder
         if req.headers?['x-auth-token']?
            req.meteorUserId = lookup_userId_by_token req.headers['x-auth-token']
         # Or as a URL query of the same name
         else if req.query?['x-auth-token']?
            console.log "Has query x-auth-token: #{req.query['x-auth-token']}"
            req.meteorUserId = lookup_userId_by_token req.query['x-auth-token']
         console.log "Request:", req.method, req.url, req.headers?['x-auth-token'] or req.query?['x-auth-token'], req.meteorUserId
      next()

   share.setupHttpAccess = (options) ->
         r = express.Router()
         r.use express.query()
         r.use handle_auth
         WebApp.rawConnectHandlers.use(@baseURL, share.bind_env(r))

         if options.resumable
            share.setup_resumable.bind(@)()

         if options.http
            @router = express.Router()
            build_access_point.bind(@)(options.http ? [], @router)
            WebApp.rawConnectHandlers.use(@baseURL, share.bind_env(@router))
