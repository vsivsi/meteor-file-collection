############################################################################
#     Copyright (C) 2014 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

bind_env = (func) ->
  if typeof func is 'function'
    return Meteor.bindEnvironment func, (err) -> throw err
  else
    return func

subWrapper = (sub, func) ->
  (test, onComplete) ->
    if Meteor.isClient
      Deps.autorun () ->
        if sub.ready()
          func test, onComplete
    else
      func test, onComplete

defaultColl = new FileCollection()

Tinytest.add 'FileCollection default constructor', (test) ->
  test.instanceOf defaultColl, FileCollection, "FileCollection constructor failed"
  test.equal defaultColl.root, 'fs', "default root isn't 'fs'"
  test.equal defaultColl.chunkSize, 2*1024*1024, "bad default chunksize"
  test.equal defaultColl.baseURL, "/gridfs/fs", "bad default base URL"

testColl = new FileCollection "test",
  baseURL: "/test"
  chunkSize: 1024*1024
  resumable: true
  http: [
     { method: 'get', path: ['/:_id', '/:_id/*:path?'], lookup: (params, query) -> { _id: params._id }}
     { method: 'post', path: '/:_id', lookup: (params, query) -> { _id: params._id }}
     { method: 'put', path: '/:_id', lookup: (params, query) -> { _id: params._id }}
     { method: 'delete', path: '/:_id', lookup: (params, query) -> { _id: params._id }}
  ]

noReadColl = new FileCollection "noReadColl",
  baseURL: "/noread"
  chunkSize: 1024*1024
  resumable: false
  http: [
     { method: 'get', path: '/:_id', lookup: (params, query) -> { _id: params._id }}
     { method: 'post', path: '/:_id', lookup: (params, query) -> { _id: params._id }}
     { method: 'put', path: '/:_id', lookup: (params, query) -> { _id: params._id }}
     { method: 'delete', path: '/:_id', lookup: (params, query) -> { _id: params._id }}
  ]

noAllowColl = new FileCollection "noAllowColl"
denyColl = new FileCollection "denyColl"

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
    write: () -> true
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
  Tinytest.add 'Client has Resumable', (test) ->
    test.instanceOf testColl.resumable, Resumable, "Resumable object not found"

Tinytest.add 'FileCollection constructor with options', (test) ->
  test.instanceOf testColl, FileCollection, "FileCollection constructor failed"
  test.equal testColl.root, 'test', "root collection not properly set"
  test.equal testColl.chunkSize, 1024*1024, "chunkSize not set properly"
  test.equal testColl.baseURL, "/test", "base URL not set properly"

Tinytest.add 'FileCollection insert and findOne', (test) ->
  _id = testColl.insert {}
  test.isNotNull _id, "No _id returned by insert"
  test.instanceOf _id, Meteor.Collection.ObjectID
  file = testColl.findOne {_id : _id}
  test.isNotNull file, "Invalid file returned by findOne"
  test.equal typeof file, "object"
  test.equal file.length, 0
  test.equal file.md5, 'd41d8cd98f00b204e9800998ecf8427e'
  test.instanceOf file.uploadDate, Date
  test.equal file.chunkSize, 1024*1024
  test.equal file.filename, ''
  test.equal typeof file.metadata, "object"
  test.instanceOf file.aliases, Array
  test.equal file.contentType, 'application/octet-stream'

Tinytest.addAsync 'FileCollection insert and findOne in callback', subWrapper(sub, (test, onComplete) ->
  _id = testColl.insert {}, (err, retid) ->
    test.fail(err) if err
    test.isNotNull _id, "No _id returned by insert"
    test.isNotNull retid, "No _id returned by insert callback"
    test.instanceOf _id, Meteor.Collection.ObjectID, "_id is wrong type"
    test.instanceOf retid, Meteor.Collection.ObjectID, "retid is wrong type"
    test.equal _id, retid, "different ids returned in return and callback"
    file = testColl.findOne {_id : retid}
    test.isNotNull file, "Invalid file returned by findOne"
    test.equal typeof file, "object"
    test.equal file.length, 0
    test.equal file.md5, 'd41d8cd98f00b204e9800998ecf8427e'
    test.instanceOf file.uploadDate, Date
    test.equal file.chunkSize, 1024*1024
    test.equal file.filename, ''
    test.equal typeof file.metadata, "object"
    test.instanceOf file.aliases, Array
    test.equal file.contentType, 'application/octet-stream'
    onComplete()
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
  test.equal file.chunkSize, 1024*1024
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
    test.instanceOf _id, Meteor.Collection.ObjectID, "_id is wrong type"
    test.instanceOf retid, Meteor.Collection.ObjectID, "retid is wrong type"
    test.equal _id, retid, "different ids returned in return and callback"
    file = testColl.findOne {_id : retid}
    test.isNotNull file, "Invalid file returned by findOne"
    test.equal typeof file, "object"
    test.equal file.length, 0
    test.equal file.md5, 'd41d8cd98f00b204e9800998ecf8427e'
    test.instanceOf file.uploadDate, Date
    test.equal file.chunkSize, 1024*1024
    test.equal file.filename, 'testfile'
    test.equal typeof file.metadata, "object"
    test.equal file.metadata.x, 1
    test.instanceOf file.aliases, Array
    test.equal file.aliases[0], 'foo'
    test.equal file.contentType, 'text/plain'
    onComplete()
)

if Meteor.isServer

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
          readstream = testColl.findOneStream {_id: file._id }
          readstream.on 'data', bind_env (chunk) ->
            test.equal chunk.toString(), '1234567890','Incorrect data read back from stream'
          readstream.on 'end', bind_env () ->
            testfile = "/tmp/FileCollection." + file._id + ".test"
            testColl.exportFile file, testfile, bind_env (err, doc) ->
              test.fail(err) if err
              testColl.importFile testfile, {}, bind_env (err, doc) ->
                test.fail(err) if err
                readstream = testColl.findOneStream {_id: doc._id }
                readstream.on 'data', bind_env (chunk) ->
                  test.equal chunk.toString(), '1234567890','Incorrect data read back from file stream'
                readstream.on 'end', bind_env () ->
                  onComplete()
        writestream.write '1234567890'
        writestream.end()

  Tinytest.addAsync 'Just Upsert stream to gridfs and read back, write to file system, and re-import',
    (test, onComplete) ->
      writestream = testColl.upsertStream { filename: 'writefile', contentType: 'text/plain' }
      writestream.on 'close', bind_env (file) ->
        test.equal typeof file, 'object', "Bad file object after upsert stream"
        test.equal file.length, 10, "Improper file length"
        test.equal file.md5, 'e46c309de99c3dfbd6acd9e77751ae98', "Improper file md5 hash"
        test.equal file.contentType, 'text/plain', "Improper contentType"
        readstream = testColl.findOneStream {_id: file._id }
        readstream.on 'data', bind_env (chunk) ->
          test.equal chunk.toString(), 'ZYXWVUTSRQ','Incorrect data read back from stream'
        readstream.on 'end', bind_env () ->
          testfile = "/tmp/FileCollection." + file._id + ".test"
          testColl.exportFile file, testfile, bind_env (err, doc) ->
            test.fail(err) if err
            testColl.importFile testfile, {}, bind_env (err, doc) ->
              test.fail(err) if err
              readstream = testColl.findOneStream {_id: doc._id }
              readstream.on 'data', bind_env (chunk) ->
                test.equal chunk.toString(), 'ZYXWVUTSRQ','Incorrect data read back from file stream'
              readstream.on 'end', bind_env () ->
                onComplete()
      writestream.write 'ZYXWVUTSRQ'
      writestream.end()

Tinytest.addAsync 'REST API PUT/GET', (test, onComplete) ->
  _id = testColl.insert { filename: 'writefile', contentType: 'text/plain' }, (err, _id) ->
    test.fail(err) if err
    url = Meteor.absoluteUrl 'test/' + _id
    HTTP.put url, { content: '0987654321'}, (err, res) ->
      test.fail(err) if err
      HTTP.get url + '/other/path/info', (err, res) ->
        test.fail(err) if err
        test.equal res.content, '0987654321'
        onComplete()

Tinytest.addAsync 'REST API POST/GET/DELETE', (test, onComplete) ->
  _id = testColl.insert { filename: 'writefile', contentType: 'text/plain' }, (err, _id) ->
    test.fail(err) if err
    url = Meteor.absoluteUrl 'test/' + _id
    HTTP.post url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: '--AaB03x\r\nContent-Disposition: form-data; name="file"; filename="foobar"\r\nContent-Type: text/plain\r\n\r\nABCDEFGHIJ\r\n--AaB03x--'},
      (err, res) ->
        test.fail(err) if err
        HTTP.get url, (err, res) ->
          test.fail(err) if err
          test.equal res.content,'ABCDEFGHIJ'
          HTTP.del url, (err, res) ->
            test.fail(err) if err
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
        req = $.get url
        req.done () ->
          test.fail new Error "Read without allow succeeded."
          onComplete()
        req.fail (jqXHR, status, err) ->
          test.equal err, 'Forbidden', 'Test was not forbidden'
          onComplete()
  )

