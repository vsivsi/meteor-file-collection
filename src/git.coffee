############################################################################
#     Copyright (C) 2015 by Vaughn Iverson
#     file-collection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isServer

   gbs = Npm.require 'git-blob-stream'

   through2 = Npm.require 'through2'

   strStream = (data) ->
      s = through2()
      s.write data
      s.end()
      return s

   share.Git = class Git

      constructor: (@fC, @repo = '') ->
         unless @ instanceof Git
            return new Git(@fC, @repo)

         unless @fC instanceof FileCollection
            throw new Error "Git error: Invalid fileCollection provided"

         unless typeof @repo is 'string'
            throw new Error "Git error: Invalid repository name provided"

         @gbs = gbs

         @prefix = "#{@repo}.git"

         # Initialize the repo if necessary
         @_updateServerInfo()

      _objPath: (hash) ->
         return "objects/#{hash.slice(0,2)}/#{hash.slice(2)}"

      _updateServerInfo: () ->
         Async.runSync (done) =>
            unless @_readHead()
               @_writeHead 'ref: refs/heads/master'
            query =
               filename:
                  $regex: new RegExp "^#{@prefix}/refs/"
            refs = ""
            @fC.find(query).forEach (d) ->
               refs += "#{d.metadata._Git.ref}\t#{d.filename.slice(d.filename.indexOf('/')+1)}\n"
            name = "#{@prefix}/info/refs"
            query =
               _id: name
               filename: name
               metadata:
                  _Git:
                     repo: @repo
                     type: 'refs'
            outStream = @fC.upsertStream query, (err, f) =>
               console.dir f
               done err, f
            console.log "Here are the refs!", refs
            outStream.end refs

      _readFile: (query) ->
         Async.runSync (done) =>
            buffers = []
            bufferLen = 0
            rs = @fC.findOneStream query
            rs.on 'data', (buffer) =>
               bufferLen += buffer.length
               buffers.push buffer
            rs.on 'end', () =>
               done null, Buffer.concat(buffers, bufferLen)
            rs.on 'error', (err) =>
               done err

      _readHead: () ->
         headRef = @_readRef 'HEAD'
         unless headRef?
            return null
         unless headRef[..4] is 'ref: '
            console.warn 'HEAD is detached'
            return headRef
         else
            return @_readRef headRef[5..]

      _writeHead: (ref) ->
         Async.runSync (done) =>
            unless ref and typeof ref is 'string'
               done new Error "_writeHead must have a valid reference"
            query =
               _id: "#{@prefix}/HEAD"
               filename: "#{@prefix}/HEAD"
               metadata:
                  _Git:
                     repo: @repo
                     type: 'HEAD'
                     ref: "#{ref}"
            outStream = @fC.upsertStream query, (err, f) =>
               console.dir f
               done err, f
            outStream.end "#{ref}\n"

      _readRef: (ref) ->
         query =
            _id: "#{@prefix}/#{ref}"
         ref = @fC.findOne query
         unless ref?
            console.warn "Missing ref: #{ref}"
            return null
         if ref.metadata?._Git?.ref?
            return ref.metadata._Git.ref
         else
            # Read the file...
            return _readFile(query).result

      _writeRef: (ref, commit) ->
         Async.runSync (done) =>
            unless ref and typeof ref is 'string'
               done new Error "_writeRef must have a valid reference"
            unless commit and typeof commit is 'string' and commit.length is 40
               done new Error "_writeRef must have a valid commit"
            name = "#{@prefix}/#{ref}"
            query =
               _id: name
               filename: name
               metadata:
                  _Git:
                     repo: @repo
                     type: 'ref'
                     ref: commit
            outStream = @fC.upsertStream query, (err, f) =>
               done err if err
               console.dir f
               @_updateServerInfo()
               done null, f
            outStream.end "#{commit}\n"

      _writeTree: (tree) ->
         Async.runSync (done) =>
            console.log "Making a tree!"
            data = Async.wrap(gbs.treeWriter) tree, { arrayTree: true, noOutput: true }
            console.log "tree should be: #{data.hash}, #{data.size}"
            name = "#{@prefix}/#{@_objPath data.hash}"
            if @fC.findOne { _id: name }
               done null, data
            else
               outStream = @fC.upsertStream
                     _id: name
                     filename: name
                     metadata:
                        _Git:
                           repo: @repo
                           sha1: data.hash
                           type: 'tree'
                           size: data.size
                           tree: data.tree
                  , (err, f) =>
                     console.dir f, { depth: null }
                     console.log "#{data.hash} written! as #{f._id}", err
                     done err, data
               gbs.treeWriter(tree).pipe(outStream)

      _writeCommit: (commit) ->
         Async.runSync (done) =>
            console.log "Making a commit!", commit
            data = Async.wrap(gbs.commitWriter) commit, { noOutput: true }
            console.log "commit should be: #{data.hash}, #{data.size}"
            name = "#{@prefix}/#{@_objPath data.hash}"
            if @fC.findOne { _id: name }
               done null, data
            else
               outStream = @fC.upsertStream
                     _id: name
                     filename: name
                     metadata:
                        _Git:
                           repo: @repo
                           sha1: data.hash
                           type: 'commit'
                           size: data.size
                           commit: data.commit
                  , (err, f) =>
                     console.dir f.metadata._Git.commit, { depth: null }
                     console.log "#{data.hash} written! as #{f._id}", err
                     done null, data
               gbs.commitWriter(commit).pipe(outStream)

      _writeTag: (tag) ->
         Async.runSync (done) =>
            console.log "Making a tag!"
            data = Async.wrap(gbs.tagWriter) tag, { noOutput: true }
            console.log "tag should be: #{data.hash}, #{data.size}"
            name = "#{@prefix}/#{@_objPath data.hash}"
            if @fC.findOne { _id: name }
               done null, data
            else
               outStream = @fC.upsertStream
                     _id: name
                     filename: name
                     metadata:
                        _Git:
                           repo: @repo
                           sha1: data.hash
                           type: 'tag'
                           size: data.size
                           tag: data.tag
                  , (err, f) =>
                     console.dir f.metadata._Git.tag, { depth: null }
                     console.log "#{data.hash} written! as #{f._id}", err
                     @_writeRef "refs/tags/#{tag.tag}", tag.object
                     done null, data
               gbs.tagWriter(tag).pipe(outStream)

      _checkFile: (inputStream) ->
         res = Async.runSync (done) =>
            inputStream.pipe gbs.blobWriter { type: 'blob', noOutput: true }, Meteor.bindEnvironment (err, data) =>
               if err
                  return done err
               name = "#{@prefix}/#{@_objPath data.hash}"
               if @fC.findOne { _id: name }
                  done null, { blob: data, newBlob: false }
               else
                  done null, { blob: data, newBlob: true }

      _writeFile: (data, stream) ->
         res = Async.runSync (done) =>
            name = "#{@prefix}/#{@_objPath data.hash}"
            bw = gbs.blobWriter
                  type: 'blob'
                  size: data.length
               ,  (err, obj) =>
                  console.dir obj
                  done err, obj
            outStream = @fC.upsertStream
                  _id: name
                  filename: name
                  metadata:
                     _Git:
                        repo: @repo
                        sha1: data.hash
                        type: 'blob'
                        size: data.size
               , (err, f) =>
                  console.dir f, { depth: null }
                  console.log "#{data.hash} written! as #{f._id}", err
            stream.pipe(bw).pipe(outStream)
         return res

      _makeDbTree: (collection, query) ->
         @_writeTree collection.find(query).map (d) =>
            res = Async.runSync (done) =>
               canon = EJSON.stringify d, { canonical: true, indent: true }
               r = @_checkFile strStream(canon)
               if r.error
                  return done r.error
               record =
                  name: "#{d._id}"
                  mode: gbs.gitModes.file
                  hash: r.result.blob.hash
               if r.result.newBlob
                  rr = @_writeFile r.result.blob, strStream(canon)
                  if rr.error
                     return done rr.error
                  console.log "Record written", canon, rr.result
                  done null, record
               else
                  console.log "Record present", canon, r.result.blob
                  done null, record
            throw res.error if res.error
            return res.result

      _makeFcTree: (collection, query) ->
         @_writeTree collection.find(query).map (d) =>
            if d.metadata?._blobCache?.md5 is d.md5
               name = "#{@prefix}/#{@_objPath d.metadata._blobCache.sha1}"
               doc = @fC.findOne name
               if doc
                  console.log "Hit blob cache!"
                  record =
                     name: d.filename
                     mode: gbs.gitModes.file
                     hash: d.metadata._blobCache.sha1
                  return record
            res = Async.runSync (done) =>
               # Check if this blob exists
               r = @_checkFile collection.findOneStream({ _id: d._id })
               if r.error
                  return done r.error
               record =
                 name: d.filename
                 mode: gbs.gitModes.file
                 hash: r.result.blob.hash
               if r.result.newBlob
                  rr = @_writeFile r.result.blob, collection.findOneStream({ _id: d._id })
                  console.log "FileStream written", rr.result
               else
                  console.log "File present", r.result.blob
               collection.update { _id: d._id }, { $set: { 'metadata._blobCache': { md5: d.md5, sha1: r.result.blob.hash } } }
               done null, record
            throw res.error if res.error
            return res.result
