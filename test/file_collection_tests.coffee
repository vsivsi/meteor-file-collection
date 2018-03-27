############################################################################
#     Copyright (C) 2014-2017 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isServer
  os = Npm.require 'os'
  path = Npm.require 'path'

bind_env = (func) ->
  if typeof func is 'function'
    return Meteor.bindEnvironment func, (err) -> throw err
  else
    return func

subWrapper = (sub, func) ->
  (test, onComplete) ->
    if Meteor.isClient
      Tracker.autorun () ->
        if sub.ready()
          func test, onComplete
    else
      func test, onComplete

defaultColl = new FileCollection()

Tinytest.add 'FileCollection default constructor', (test) ->
  test.instanceOf defaultColl, FileCollection, "FileCollection constructor failed"
  test.equal defaultColl.root, 'fs', "default root isn't 'fs'"
  test.equal defaultColl.chunkSize, 2*1024*1024 - 1024, "bad default chunksize"
  test.equal defaultColl.baseURL, "/gridfs/fs", "bad default base URL"

idLookup = (params, query) ->
   return { _id: params._id }

longString = ''
while longString.length < 4096
   longString += '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'

testColl = new FileCollection "test",
  baseURL: "/test"
  chunkSize: 16
  resumable: true
  maxUploadSize: 2048
  http: [
     { method: 'get', path: '/:_id', lookup: idLookup}
     { method: 'post', path: '/:_id', lookup: idLookup}
     { method: 'put', path: '/:_id', lookup: idLookup}
     { method: 'delete', path: '/:_id', lookup: idLookup}
     { method: 'options', path: '/:_id', lookup: idLookup, handler: (req, res, next) ->
          res.writeHead(200, { 'Content-Type': 'text/plain', 'Access-Control-Allow-Origin': 'http://meteor.local' })
          res.end()
          return
     }
  ]

noReadColl = new FileCollection "noReadColl",
  baseURL: "/noread"
  chunkSize: 1024*1024
  resumable: false
  http: [
     { method: 'get', path: '/:_id', lookup: idLookup}
     { method: 'post', path: '/:_id', lookup: idLookup}
     { method: 'put', path: '/:_id', lookup: idLookup}
     { method: 'delete', path: '/:_id', lookup: idLookup}
  ]

noAllowColl = new FileCollection "noAllowColl"
denyColl = new FileCollection "denyColl"

Meteor.methods
  updateTest: (id, reject) ->
    check id, Mongo.ObjectID
    check reject, Boolean
    if this.isSimulation
      testColl.localUpdate { _id: id }, { $set: { 'metadata.test2': true } }
    else if reject
      throw new Meteor.Error "Rejected by server"
    else
      testColl.update { _id: id }, { $set: { 'metadata.test2': false } }

if Meteor.isServer

  Meteor.publish 'everything', () -> testColl.find {}
  Meteor.publish 'noAllowCollPub', () -> noAllowColl.find {}
  Meteor.publish 'noReadCollPub', () -> noReadColl.find {}
  Meteor.publish 'denyCollPub', () -> denyColl.find {}

  sub = null

  testColl.allow
    insert: () -> true
    write: () -> true
    remove: () -> true
    read: () -> true

  testColl.deny
    insert: () -> false
    write: () -> false
    remove: () -> false
    read: () -> false

  noAllowColl.allow
    read: () -> false
    insert: () -> false
    write: () -> false
    remove: () -> false

  noReadColl.allow
    read: () -> false
    insert: () -> true
    write: () -> { maxUploadSize: 15 }
    remove: () -> true

  noReadColl.deny
    read: () -> false
    insert: () -> false
    write: () -> false
    remove: () -> false

  denyColl.deny
    read: () -> true
    insert: () -> true
    write: () -> true
    remove: () -> true

  Tinytest.add 'set allow/deny on FileCollection', (test) ->
    test.equal testColl.allows.read[0](), true
    test.equal testColl.allows.insert[0](), true
    test.equal testColl.allows.remove[0](), true
    test.equal testColl.allows.write[0](), true
    test.equal testColl.denys.read[0](), false
    test.equal testColl.denys.write[0](), false
    test.equal testColl.denys.insert[0](), false
    test.equal testColl.denys.remove[0](), false

  Tinytest.add 'check server REST API', (test) ->
    test.equal typeof testColl.router, 'function'

if Meteor.isClient
  sub = Meteor.subscribe 'everything'

  Tinytest.add 'Server-only methods throw on client', (test) ->
    test.throws () -> testColl.allow({})
    test.throws () -> testColl.deny({})
    test.throws () -> testColl.upsert({})
    test.throws () -> testColl.update({})
    test.throws () -> testColl.findOneStream({})
    test.throws () -> testColl.upsertStream({})
    test.throws () -> testColl.importFile({})
    test.throws () -> testColl.exportFile({})

Tinytest.add 'FileCollection constructor with options', (test) ->
  test.instanceOf testColl, FileCollection, "FileCollection constructor failed"
  test.equal testColl.root, 'test', "root collection not properly set"
  test.equal testColl.chunkSize, 16, "chunkSize not set properly"
  test.equal testColl.baseURL, "/test", "base URL not set properly"

Tinytest.add 'FileCollection insert, findOne and remove', (test) ->
  _id = testColl.insert {}
  test.isNotNull _id, "No _id returned by insert"
  test.instanceOf _id, Mongo.ObjectID
  file = testColl.findOne {_id : _id}
  test.isNotNull file, "Invalid file returned by findOne"
  test.equal typeof file, "object"
  test.equal file.length, 0
  test.equal file.md5, 'd41d8cd98f00b204e9800998ecf8427e'
  test.instanceOf file.uploadDate, Date
  test.equal file.chunkSize, 16
  test.equal file.filename, ''
  test.equal typeof file.metadata, "object"
  test.instanceOf file.aliases, Array
  test.equal file.contentType, 'application/octet-stream'
  result = testColl.remove {_id : _id}
  test.equal result, 1, "Incorrect number of files removed"
  file = testColl.findOne {_id : _id}
  test.isUndefined file, "File was not removed"

Tinytest.addAsync 'FileCollection insert, findOne and remove with callback', subWrapper(sub, (test, onComplete) ->
  _id = testColl.insert {}, (err, retid) ->
    test.fail(err) if err
    test.isNotNull _id, "No _id returned by insert"
    test.isNotNull retid, "No _id returned by insert callback"
    test.instanceOf _id, Mongo.ObjectID, "_id is wrong type"
    test.instanceOf retid, Mongo.ObjectID, "retid is wrong type"
    test.equal _id, retid, "different ids returned in return and callback"
    file = testColl.findOne {_id : retid}
    test.isNotNull file, "Invalid file returned by findOne"
    test.equal typeof file, "object"
    test.equal file.length, 0
    test.equal file.md5, 'd41d8cd98f00b204e9800998ecf8427e'
    test.instanceOf file.uploadDate, Date
    test.equal file.chunkSize, 16
    test.equal file.filename, ''
    test.equal typeof file.metadata, "object"
    test.instanceOf file.aliases, Array
    test.equal file.contentType, 'application/octet-stream'
    finishCount = 0
    finish = () ->
      finishCount++
      if finishCount > 1
         onComplete()
    obs = testColl.find({_id : _id}).observeChanges
       removed: (id) ->
          obs.stop()
          test.ok EJSON.equals(id, _id), 'Incorrect file _id removed'
          finish()
    testColl.remove {_id : retid}, (err, result) ->
      test.fail(err) if err
      test.equal result, 1, "Incorrect number of files removed"
      finish()
)

Tinytest.add 'FileCollection insert and find with options', (test) ->
  _id = testColl.insert { filename: 'testfile', metadata: { x: 1 }, aliases: ["foo"], contentType: 'text/plain' }
  test.isNotNull _id, "No _id returned by insert"
  test.instanceOf _id, Meteor.Collection.ObjectID
  file = testColl.findOne {_id : _id}
  test.isNotNull file, "Invalid file returned by findOne"
  test.equal typeof file, "object"
  test.equal file.length, 0
  test.equal file.md5, 'd41d8cd98f00b204e9800998ecf8427e'
  test.instanceOf file.uploadDate, Date
  test.equal file.chunkSize, 16
  test.equal file.filename, 'testfile'
  test.equal typeof file.metadata, "object"
  test.equal file.metadata.x, 1
  test.instanceOf file.aliases, Array
  test.equal file.aliases[0], 'foo'
  test.equal file.contentType, 'text/plain'

Tinytest.addAsync 'FileCollection insert and find with options in callback', subWrapper(sub, (test, onComplete) ->
  _id = testColl.insert { filename: 'testfile', metadata: { x: 1 }, aliases: ["foo"], contentType: 'text/plain' }, (err, retid) ->
    test.fail(err) if err
    test.isNotNull _id, "No _id returned by insert"
    test.isNotNull retid, "No _id returned by insert callback"
    test.instanceOf _id, Mongo.ObjectID, "_id is wrong type"
    test.instanceOf retid, Mongo.ObjectID, "retid is wrong type"
    test.equal _id, retid, "different ids returned in return and callback"
    file = testColl.findOne {_id : retid}
    test.isNotNull file, "Invalid file returned by findOne"
    test.equal typeof file, "object"
    test.equal file.length, 0
    test.equal file.md5, 'd41d8cd98f00b204e9800998ecf8427e'
    test.instanceOf file.uploadDate, Date
    test.equal file.chunkSize, 16
    test.equal file.filename, 'testfile'
    test.equal typeof file.metadata, "object"
    test.equal file.metadata.x, 1
    test.instanceOf file.aliases, Array
    test.equal file.aliases[0], 'foo'
    test.equal file.contentType, 'text/plain'
    onComplete()
)

if Meteor.isServer

  Tinytest.addAsync 'Proper error handling for missing file on import',
    (test, onComplete) ->
      bogusfile = "/bogus/file.not"
      testColl.importFile bogusfile, {}, bind_env (err, doc) ->
         test.fail(err) unless err
         onComplete()

  Tinytest.addAsync 'Server accepts good and rejects bad updates', (test, onComplete) ->
    _id = testColl.insert()
    testColl.update _id, { $set: { "metadata.test": 1 } }, (err, res) ->
      test.fail(err) if err
      test.equal res, 1
      testColl.update _id, { $inc: { "metadata.test": 1 } }, (err, res) ->
        test.fail(err) if err
        test.equal res, 1
        doc = testColl.findOne _id
        test.equal doc.metadata.test, 2
        testColl.update _id, { $set: { md5: 1 } }, (err, res) ->
          test.isUndefined res
          test.instanceOf err, Meteor.Error
          testColl.update _id, { $unset: { filename: 1 } }, (err, res) ->
            test.isUndefined res
            test.instanceOf err, Meteor.Error
            testColl.update _id, { foo: "bar" }, (err, res) ->
              test.isUndefined res
              test.instanceOf err, Meteor.Error
              onComplete()

  Tinytest.addAsync 'Insert and then Upsert stream to gridfs and read back, write to file system, and re-import',
    (test, onComplete) ->
      _id = testColl.insert { filename: 'writefile', contentType: 'text/plain' }, (err, _id) ->
        test.fail(err) if err
        writestream = testColl.upsertStream { _id: _id }
        writestream.on 'close', bind_env (file) ->
          test.equal typeof file, 'object', "Bad file object after upsert stream"
          test.equal file.length, 10, "Improper file length"
          test.equal file.md5, 'e807f1fcf82d132f9bb018ca6738a19f', "Improper file md5 hash"
          test.equal file.contentType, 'text/plain', "Improper contentType"
          test.equal typeof file._id, 'object'
          test.equal _id, new Mongo.ObjectID file._id.toHexString()
          readstream = testColl.findOneStream {_id: file._id }
          readstream.on 'data', bind_env (chunk) ->
            test.equal chunk.toString(), '1234567890','Incorrect data read back from stream'
          readstream.on 'end', bind_env () ->
            testfile = path.join os.tmpdir(), "/FileCollection." + file._id + ".test"
            testColl.exportFile file, testfile, bind_env (err, doc) ->
              test.fail(err) if err
              testColl.importFile testfile, {}, bind_env (err, doc) ->
                test.fail(err) if err
                test.equal typeof doc, 'object', "No document imported"
                if typeof doc == 'object'
                  readstream = testColl.findOneStream {_id: doc._id }
                  readstream.on 'data', bind_env (chunk) ->
                    test.equal chunk.toString(), '1234567890','Incorrect data read back from file stream'
                  readstream.on 'end', bind_env () ->
                    onComplete()
                else
                  onComplete()
        writestream.write '1234567890'
        writestream.end()

  Tinytest.addAsync 'Just Upsert stream to gridfs and read back, write to file system, and re-import',
    (test, onComplete) ->
      writestream = testColl.upsertStream { filename: 'writefile', contentType: 'text/plain' }, bind_env (err, file) ->
        test.equal typeof file, 'object', "Bad file object after upsert stream"
        test.equal file.length, 10, "Improper file length"
        test.equal file.md5, 'e46c309de99c3dfbd6acd9e77751ae98', "Improper file md5 hash"
        test.equal file.contentType, 'text/plain', "Improper contentType"
        test.equal typeof file._id, 'object'
        test.instanceOf file._id, Mongo.ObjectID, "_id is wrong type"
        readstream = testColl.findOneStream {_id: file._id }
        readstream.on 'data', bind_env (chunk) ->
          test.equal chunk.toString(), 'ZYXWVUTSRQ','Incorrect data read back from stream'
        readstream.on 'end', bind_env () ->
          testfile = path.join os.tmpdir(), "/FileCollection." + file._id + ".test"
          testColl.exportFile file, testfile, bind_env (err, doc) ->
            test.fail(err) if err
            testColl.importFile testfile, {}, bind_env (err, doc) ->
              test.fail(err) if err
              test.equal typeof doc, 'object', "No document imported"
              if typeof doc == 'object'
                readstream = testColl.findOneStream {_id: doc._id }
                readstream.on 'data', bind_env (chunk) ->
                  test.equal chunk.toString(), 'ZYXWVUTSRQ','Incorrect data read back from file stream'
                readstream.on 'end', bind_env () ->
                  onComplete()
              else
                onComplete()
      writestream.write 'ZYXWVUTSRQ'
      writestream.end()

Tinytest.addAsync 'REST API PUT/GET', (test, onComplete) ->
  _id = testColl.insert { filename: 'writefile', contentType: 'text/plain' }, (err, _id) ->
    test.fail(err) if err
    url = Meteor.absoluteUrl 'test/' + _id
    HTTP.put url, { content: '0987654321'}, (err, res) ->
      test.fail(err) if err
      HTTP.call "OPTIONS", url, (err, res) ->
         test.fail(err) if err
         test.equal res.headers?['access-control-allow-origin'], 'http://meteor.local'
         HTTP.get url, (err, res) ->
           test.fail(err) if err
           test.equal res.content, '0987654321'
           onComplete()

Tinytest.addAsync 'REST API GET null id', (test, onComplete) ->
  _id = testColl.insert { filename: 'writefile', contentType: 'text/plain' }, (err, _id) ->
    test.fail(err) if err
    url = Meteor.absoluteUrl 'test/'
    HTTP.get url, (err, res) ->
      test.isNotNull err
      if err.response?  # Not sure why, but under phantomjs the error object is different
        test.equal err.response.statusCode, 404
      else
        console.warn "PhantomJS skipped statusCode check"
      onComplete()

Tinytest.addAsync 'maxUploadSize enforced by when HTTP PUT upload is too large', (test, onComplete) ->
   _id = testColl.insert { filename: 'writefile', contentType: 'text/plain' }, (err, _id) ->
      test.fail(err) if err
      url = Meteor.absoluteUrl 'test/' + _id
      HTTP.put url, { content: longString }, (err, res) ->
         test.isNotNull err
         if err.response?  # Not sure why, but under phantomjs the error object is different
            test.equal err.response.statusCode, 413
         else
            console.warn "PhantomJS skipped statusCode check"
         onComplete()

Tinytest.addAsync 'maxUploadSize enforced by when HTTP POST upload is too large', (test, onComplete) ->
   _id = testColl.insert { filename: 'writefile', contentType: 'text/plain' }, (err, _id) ->
      test.fail(err) if err
      url = Meteor.absoluteUrl 'test/' + _id
      content = """
         --AaB03x\r
         Content-Disposition: form-data; name="blahBlahBlah"\r
         Content-Type: text/plain\r
         \r
         BLAH\r
         --AaB03x\r
         Content-Disposition: form-data; name="file"; filename="foobar"\r
         Content-Type: text/plain\r
         \r
         #{longString}\r
         --AaB03x--\r
      """
      HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content }, (err, res) ->
         test.isNotNull err
         if err.response?  # Not sure why, but under phantomjs the error object is different
            test.equal err.response.statusCode, 413
         else
            console.warn "PhantomJS skipped statusCode check"
         onComplete()

Tinytest.addAsync 'If-Modified-Since header support', (test, onComplete) ->
  _id = testColl.insert { filename: 'writefile', contentType: 'text/plain' }, (err, _id) ->
    test.fail(err) if err
    url = Meteor.absoluteUrl 'test/' + _id
    HTTP.get url, (err, res) ->
      test.fail(err) if err
      test.equal res.statusCode, 200, 'Failed without If-Modified-Since header'
      modified = res.headers['last-modified']
      test.equal typeof modified, 'string', 'Invalid Last-Modified response'
      HTTP.get url, {headers: {'If-Modified-Since': modified}}, (err, res) ->
        test.fail(err) if err
        test.equal res.statusCode, 304, 'Returned file despite present If-Modified-Since'
        HTTP.get url, {headers: {'If-Modified-Since': 'hello'}}, (err, res) ->
          test.fail(err) if err
          test.equal res.statusCode, 200, 'Skipped file despite unparsable If-Modified-Since'
          modified = new Date(Date.parse(modified) - 2000).toUTCString()  ## past test
          HTTP.get url, {headers: {'If-Modified-Since': modified}}, (err, res) ->
            test.fail(err) if err
            test.equal res.statusCode, 200, 'Skipped file despite past If-Modified-Since'
            modified = new Date(Date.parse(modified) + 4000).toUTCString()  ## future test
            HTTP.get url, {headers: {'If-Modified-Since': modified}}, (err, res) ->
              test.fail(err) if err
              test.equal res.statusCode, 304, 'Returned file despite future If-Modified-Since'
              onComplete()

Tinytest.addAsync 'REST API POST/GET/DELETE', (test, onComplete) ->
  _id = testColl.insert { filename: 'writefile', contentType: 'text/plain' }, (err, _id) ->
    test.fail(err) if err
    url = Meteor.absoluteUrl 'test/' + _id
    content = """
      --AaB03x\r
      Content-Disposition: form-data; name="blahBlahBlah"\r
      Content-Type: text/plain\r
      \r
      BLAH\r
      --AaB03x\r
      Content-Disposition: form-data; name="file"; filename="foobar"\r
      Content-Type: text/plain\r
      \r
      ABCDEFGHIJ\r
      --AaB03x--\r
    """
    HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content},
      (err, res) ->
        test.fail(err) if err
        HTTP.get url, (err, res) ->
          test.fail(err) if err
          test.equal res.content,'ABCDEFGHIJ'
          HTTP.del url, (err, res) ->
            test.fail(err) if err
            onComplete()

createContent = (_id, data, name, chunkNum, chunkSize = 16) ->
  totalChunks = Math.floor(data.length / chunkSize)
  totalChunks += 1 unless totalChunks*chunkSize is data.length
  throw new Error "Bad chunkNum" if chunkNum > totalChunks
  begin = (chunkNum - 1) * chunkSize
  end = if chunkNum is totalChunks then data.length else chunkNum * chunkSize

  """
    --AaB03x\r
    Content-Disposition: form-data; name="resumableChunkNumber"\r
    Content-Type: text/plain\r
    \r
    #{chunkNum}\r
    --AaB03x\r
    Content-Disposition: form-data; name="resumableChunkSize"\r
    Content-Type: text/plain\r
    \r
    #{chunkSize}\r
    --AaB03x\r
    Content-Disposition: form-data; name="resumableCurrentChunkSize"\r
    Content-Type: text/plain\r
    \r
    #{end - begin}\r
    --AaB03x\r
    Content-Disposition: form-data; name="resumableTotalSize"\r
    Content-Type: text/plain\r
    \r
    #{data.length}\r
    --AaB03x\r
    Content-Disposition: form-data; name="resumableType"\r
    Content-Type: text/plain\r
    \r
    text/plain\r
    --AaB03x\r
    Content-Disposition: form-data; name="resumableIdentifier"\r
    Content-Type: text/plain\r
    \r
    #{_id._str}\r
    --AaB03x\r
    Content-Disposition: form-data; name="resumableFilename"\r
    Content-Type: text/plain\r
    \r
    #{name}\r
    --AaB03x\r
    Content-Disposition: form-data; name="resumableRelativePath"\r
    Content-Type: text/plain\r
    \r
    #{name}\r
    --AaB03x\r
    Content-Disposition: form-data; name="resumableTotalChunks"\r
    Content-Type: text/plain\r
    \r
    #{totalChunks}\r
    --AaB03x\r
    Content-Disposition: form-data; name="file"; filename="#{name}"\r
    Content-Type: text/plain\r
    \r
    #{data.substring(begin, end)}\r
    --AaB03x--\r
  """

createCheckQuery = (_id, data, name, chunkNum, chunkSize = 16) ->
  totalChunks = Math.floor(data.length / chunkSize)
  totalChunks += 1 unless totalChunks*chunkSize is data.length
  throw new Error "Bad chunkNum" if chunkNum > totalChunks
  begin = (chunkNum - 1) * chunkSize
  end = if chunkNum is totalChunks then data.length else chunkNum * chunkSize
  "?resumableChunkNumber=#{chunkNum}&resumableChunkSize=#{chunkSize}&resumableCurrentChunkSize=#{end-begin}&resumableTotalSize=#{data.length}&resumableType=text/plain&resumableIdentifier=#{_id._str}&resumableFilename=#{name}&resumableRelativePath=#{name}&resumableTotalChunks=#{totalChunks}"

Tinytest.addAsync 'Basic resumable.js REST interface POST/GET/DELETE', (test, onComplete) ->
  testColl.insert { filename: 'writeresumablefile', contentType: 'text/plain' }, (err, _id) ->
    test.fail(err) if err
    url = Meteor.absoluteUrl "test/_resumable"
    data = 'ABCDEFGHIJ'
    content = createContent _id, data, "writeresumablefile", 1
    HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content },
      (err, res) ->
        test.fail(err) if err
        url = Meteor.absoluteUrl 'test/' + _id
        HTTP.get url, (err, res) ->
          test.fail(err) if err
          test.equal res.content, data
          HTTP.del url, (err, res) ->
            test.fail(err) if err
            onComplete()

Tinytest.addAsync 'Basic resumable.js REST interface POST/GET/DELETE, multiple chunks', (test, onComplete) ->

  data = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'

  testColl.insert { filename: 'writeresumablefile', contentType: 'text/plain' }, (err, _id) ->
    test.fail(err) if err
    url = Meteor.absoluteUrl "test/_resumable"
    content = createContent _id, data, "writeresumablefile", 1
    content2 = createContent _id, data, "writeresumablefile", 2
    HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content },
      (err, res) ->
        test.fail(err) if err
        HTTP.get url + createCheckQuery(_id, data, "writeresumablefile", 2), (err, res) ->
          test.fail(err) if err
          test.equal res.statusCode, 204
          HTTP.call 'head', url + createCheckQuery(_id, data, "writeresumablefile", 1), (err, res) ->
            test.fail(err) if err
            test.equal res.statusCode, 200
            HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content2 },
              (err, res) ->
                test.fail(err) if err
                url = Meteor.absoluteUrl 'test/' + _id
                HTTP.get url, (err, res) ->
                  test.fail(err) if err
                  test.equal res.content, data
                  HTTP.del url, (err, res) ->
                    test.fail(err) if err
                    onComplete()

Tinytest.addAsync 'Basic resumable.js REST interface POST/GET/DELETE, duplicate chunks', (test, onComplete) ->

  data = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'

  testColl.insert { filename: 'writeresumablefile', contentType: 'text/plain' }, (err, _id) ->
    test.fail(err) if err
    url = Meteor.absoluteUrl "test/_resumable"
    content = createContent _id, data, "writeresumablefile", 1
    content2 = createContent _id, data, "writeresumablefile", 2
    HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content2 },
      (err, res) ->
        test.fail(err) if err
        HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content2 },
          (err, res) ->
            test.fail(err) if err
            HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content },
              (err, res) ->
                test.fail(err) if err
                url = Meteor.absoluteUrl 'test/' + _id
                HTTP.get url, (err, res) ->
                  test.fail(err) if err
                  test.equal res.content, data
                  HTTP.del url, (err, res) ->
                    test.fail(err) if err
                    onComplete()

Tinytest.addAsync 'Basic resumable.js REST interface POST/GET/DELETE, duplicate chunks 2', (test, onComplete) ->

  data = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'

  testColl.insert { filename: 'writeresumablefile', contentType: 'text/plain' }, (err, _id) ->
    test.fail(err) if err
    url = Meteor.absoluteUrl "test/_resumable"
    content = createContent _id, data, "writeresumablefile", 1
    content2 = createContent _id, data, "writeresumablefile", 2
    HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content },
      (err, res) ->
        test.fail(err) if err
        HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content2 },
          (err, res) ->
            test.fail(err) if err
            HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content },
              (err, res) ->
                test.fail(err) if err
                url = Meteor.absoluteUrl 'test/' + _id
                HTTP.get url, (err, res) ->
                  test.fail(err) if err
                  test.equal res.content, data
                  HTTP.del url, (err, res) ->
                    test.fail(err) if err
                    onComplete()

Tinytest.addAsync 'Basic resumable.js REST interface POST/GET/DELETE, duplicate chunks 3', (test, onComplete) ->

  data = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef'

  testColl.insert { filename: 'writeresumablefile', contentType: 'text/plain' }, (err, _id) ->
    test.fail(err) if err
    url = Meteor.absoluteUrl "test/_resumable"
    content = createContent _id, data, "writeresumablefile", 1
    content2 = createContent _id, data, "writeresumablefile", 2
    content3 = createContent _id, data, "writeresumablefile", 3
    HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content2 },
      (err, res) ->
        test.fail(err) if err
        HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content },
          (err, res) ->
            test.fail(err) if err
            HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content2 },
              (err, res) ->
                test.fail(err) if err
                HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content },
                  (err, res) ->
                    test.fail(err) if err
                    HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content3 },
                      (err, res) ->
                        test.fail(err) if err
                        url = Meteor.absoluteUrl 'test/' + _id
                        HTTP.get url, (err, res) ->
                          test.fail(err) if err
                          test.equal res.content, data
                          HTTP.del url, (err, res) ->
                            test.fail(err) if err
                            onComplete()

Tinytest.addAsync 'maxUploadSize enforced by when resumable.js upload is too large', (test, onComplete) ->
   testColl.insert { filename: 'writeresumablefile', contentType: 'text/plain' }, (err, _id) ->
      test.fail(err) if err
      url = Meteor.absoluteUrl "test/_resumable"
      content = createContent _id, longString, "writeresumablefile", 1
      HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content },
         (err, res) ->
            test.isNotNull err
            if err.response?  # Not sure why, but under phantomjs the error object is different
               test.equal err.response.statusCode, 413
            else
               console.warn "PhantomJS skipped statusCode check"
            onComplete()

Tinytest.addAsync 'REST API valid range requests', (test, onComplete) ->
  _id = testColl.insert { filename: 'writefile', contentType: 'text/plain' }, (err, _id) ->
    test.fail(err) if err
    url = Meteor.absoluteUrl 'test/' + _id
    HTTP.put url, { content: '0987654321'}, (err, res) ->
      test.fail(err) if err
      HTTP.get url, { headers: { 'Range': '0-'}},
        (err, res) ->
          test.fail(err) if err
          test.equal res.headers['content-range'], 'bytes 0-9/10'
          test.equal res.headers['accept-ranges'], 'bytes'
          test.equal res.statusCode, 206
          test.equal res.content, '0987654321'
          HTTP.get url, { headers: { 'Range': '0-9'}},
            (err, res) ->
              test.fail(err) if err
              test.equal res.headers['content-range'], 'bytes 0-9/10'
              test.equal res.headers['accept-ranges'], 'bytes'
              test.equal res.statusCode, 206
              test.equal res.content, '0987654321'
              HTTP.get url, { headers: { 'Range': '5-7'}},
                (err, res) ->
                  test.fail(err) if err
                  test.equal res.headers['content-range'], 'bytes 5-7/10'
                  test.equal res.headers['accept-ranges'], 'bytes'
                  test.equal res.statusCode, 206
                  test.equal res.content, '543'
                  onComplete()

Tinytest.addAsync 'REST API invalid range requests', (test, onComplete) ->
   _id = testColl.insert { filename: 'writefile', contentType: 'text/plain' }, (err, _id) ->
      test.fail(err) if err
      url = Meteor.absoluteUrl 'test/' + _id
      HTTP.put url, { content: '0987654321'}, (err, res) ->
         test.fail(err) if err
         HTTP.get url, { headers: { 'Range': '0-10'}}, (err, res) ->
            test.isNotNull err
            if err.response?  # Not sure why, but under phantomjs the error object is different
               test.equal err.response.statusCode, 416
            else
               console.warn "PhantomJS skipped statusCode check"
            HTTP.get url, { headers: { 'Range': '5-3'}}, (err, res) ->
               test.isNotNull err
               if err.response?  # Not sure why, but under phantomjs the error object is different
                  test.equal err.response.statusCode, 416
               else
                  console.warn "PhantomJS skipped statusCode check"
               HTTP.get url, { headers: { 'Range': '-1-5'}}, (err, res) ->
                  test.isNotNull err
                  if err.response?  # Not sure why, but under phantomjs the error object is different
                     test.equal err.response.statusCode, 416
                  else
                     console.warn "PhantomJS skipped statusCode check"
                  HTTP.get url, { headers: { 'Range': '1-abc'}}, (err, res) ->
                     test.isNotNull err
                     if err.response?  # Not sure why, but under phantomjs the error object is different
                        test.equal err.response.statusCode, 416
                     else
                        console.warn "PhantomJS skipped statusCode check"
                     onComplete()

Tinytest.addAsync 'REST API requests header manipilation', (test, onComplete) ->
  _id = testColl.insert { filename: 'writefile', contentType: 'text/plain' }, (err, _id) ->
    test.fail(err) if err
    url = Meteor.absoluteUrl 'test/' + _id
    HTTP.put url, { content: '0987654321'}, (err, res) ->
      test.fail(err) if err
      HTTP.get url+'?download=true', (err, res) ->
          test.equal res.headers['content-disposition'], "attachment; filename=\"writefile\"; filename*=UTF-8''writefile"
          test.equal res.statusCode, 200
          HTTP.get url+'?cache=123456', { headers: { 'Range': '1-5'}},
            (err, res) ->
              test.equal res.headers['cache-control'], 'max-age=123456, private'
              test.equal res.statusCode, 206
              HTTP.get url+'?cache=123', (err, res) ->
                test.equal res.headers['cache-control'], 'max-age=123, private'
                test.equal res.statusCode, 200
                onComplete()

Tinytest.addAsync 'REST API requests header manipilation, UTF-8', (test, onComplete) ->
  _id = testColl.insert { filename: '中文指南.txt', contentType: 'text/plain' }, (err, _id) ->
    test.fail(err) if err
    url = Meteor.absoluteUrl 'test/' + _id
    HTTP.put url, { content: '0987654321'}, (err, res) ->
      test.fail(err) if err
      HTTP.get url+'?download=true', (err, res) ->
          test.equal res.headers['content-disposition'], "attachment; filename=\"%E4%B8%AD%E6%96%87%E6%8C%87%E5%8D%97.txt\"; filename*=UTF-8''%E4%B8%AD%E6%96%87%E6%8C%87%E5%8D%97.txt"
          test.equal res.statusCode, 200
          HTTP.get url+'?cache=123456', { headers: { 'Range': '1-5'}},
            (err, res) ->
              test.equal res.headers['cache-control'], 'max-age=123456, private'
              test.equal res.statusCode, 206
              HTTP.get url+'?cache=123', (err, res) ->
                test.equal res.headers['cache-control'], 'max-age=123, private'
                test.equal res.statusCode, 200
                onComplete()

if Meteor.isClient

  noAllowSub = Meteor.subscribe 'noAllowCollPub'
  noReadSub = Meteor.subscribe 'noReadCollPub'
  denySub = Meteor.subscribe 'denyCollPub'

  Tinytest.addAsync 'Reject insert without true allow rule', subWrapper(noAllowSub, (test, onComplete) ->
    _id = noAllowColl.insert {}, (err, retid) ->
      if err
        test.equal err.error, 403
      else
        test.fail new Error "Insert without allow succeeded."
      onComplete()
  )

  Tinytest.addAsync 'Reject insert with true deny rule', subWrapper(denySub, (test, onComplete) ->
    _id = denyColl.insert {}, (err, retid) ->
      if err
        test.equal err.error, 403
      else
        test.fail new Error "Insert with deny succeeded."
      onComplete()
  )

  Tinytest.addAsync 'Reject HTTP GET without true allow rule', subWrapper(noReadSub, (test, onComplete) ->
    _id = noReadColl.insert { filename: 'writefile', contentType: 'text/plain' }, (err, _id) ->
      test.fail(err) if err
      url = Meteor.absoluteUrl 'noread/' + _id
      HTTP.put url, { content: '0987654321'}, (err, res) ->
        test.fail(err) if err
        HTTP.get url, (err, res) ->
           test.isNotNull err
           if err.response?  # Not sure why, but under phantomjs the error object is different
              test.equal err.response.statusCode, 403
           else
              console.warn "PhantomJS skipped statusCode check"
           onComplete()
  )

  Tinytest.addAsync 'Reject HTTP PUT larger than write allow rule allows', subWrapper(noReadSub, (test, onComplete) ->
      _id = noReadColl.insert { filename: 'writefile', contentType: 'text/plain' }, (err, _id) ->
         test.fail(err) if err
         url = Meteor.absoluteUrl 'noread/' + _id
         HTTP.put url, { content: '0123456789abcdef'}, (err, res) ->
            test.isNotNull err
            if err.response?  # Not sure why, but under phantomjs the error object is different
               test.equal err.response.statusCode, 413
            else
               console.warn "PhantomJS skipped statusCode check"
            onComplete()
  )

  Tinytest.addAsync 'Client basic localUpdate test', (test, onComplete) ->
    id = testColl.insert()
    test.equal (typeof testColl.localUpdate), 'function'
    testColl.localUpdate { _id: id }, { $set: { 'metadata.test': true } }
    doc = testColl.findOne { _id: id }
    test.equal doc.metadata.test, true
    onComplete()

  Tinytest.addAsync 'Client localUpdate server method rejection test', (test, onComplete) ->
    id = testColl.insert()
    Meteor.call 'updateTest', id, true, (err, res) ->
      test.instanceOf err, Meteor.Error
      doc = testColl.findOne { _id: id }
      test.isUndefined doc.metadata.test2
      test.isUndefined res
      Meteor.call 'updateTest', id, false, (err, res) ->
        test.fail(err) if err
        test.equal res, 1
        doc = testColl.findOne { _id: id }
        test.equal doc.metadata.test2, false
        onComplete()

  # Resumable.js tests

  Tinytest.add 'Client has Resumable', (test) ->
    test.instanceOf testColl.resumable, Resumable, "Resumable object not found"

  Tinytest.addAsync 'Client resumable.js Upload', (test, onComplete) ->
    thisId = null

    testColl.resumable.on 'fileAdded', (file) ->
      testColl.insert { _id: file.uniqueIdentifier, filename: file.fileName, contentType: file.file.type }, (err, _id) ->
        test.fail(err) if err
        thisId = "#{_id._str}"
        testColl.resumable.upload()

    testColl.resumable.on 'fileSuccess', (file) ->
      test.equal thisId, file.uniqueIdentifier
      url = Meteor.absoluteUrl 'test/' + file.uniqueIdentifier
      HTTP.get url, (err, res) ->
        test.fail(err) if err
        test.equal res.content,'ABCDEFGHIJ'
        HTTP.del url, (err, res) ->
          test.fail(err) if err
          testColl.resumable.events = []
          onComplete()

    testColl.resumable.on 'error', (msg, err) ->
      test.fail err

    myBlob = new Blob [ 'ABCDEFGHIJ' ], { type: 'text/plain' }
    myBlob.name = 'resumablefile'
    testColl.resumable.addFile myBlob

  Tinytest.addAsync 'Client resumable.js Upload, Multichunk', (test, onComplete) ->
    thisId = null

    testColl.resumable.on 'fileAdded', (file) ->
      testColl.insert { _id: file.uniqueIdentifier, filename: file.fileName, contentType: file.file.type }, (err, _id) ->
        test.fail(err) if err
        thisId = "#{_id._str}"
        testColl.resumable.upload()

    testColl.resumable.on 'fileSuccess', (file) ->
      test.equal thisId, file.uniqueIdentifier
      url = Meteor.absoluteUrl 'test/' + file.uniqueIdentifier
      HTTP.get url, (err, res) ->
        test.fail(err) if err
        test.equal res.content,'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
        HTTP.del url, (err, res) ->
          test.fail(err) if err
          testColl.resumable.events = []
          onComplete()

    testColl.resumable.on 'error', (msg, err) ->
      test.fail err

    myBlob = new Blob [ 'ABCDEFGHIJ', 'KLMNOPQRSTUVWXYZ', '0123456789' ], { type: 'text/plain' }
    myBlob.name = 'resumablefile'
    testColl.resumable.addFile myBlob
