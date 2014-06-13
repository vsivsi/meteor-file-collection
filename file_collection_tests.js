/***************************************************************************
###     Copyright (C) 2014 by Vaughn Iverson
###     fileCollection is free software released under the MIT/X11 license.
###     See included LICENSE file for details.
***************************************************************************/

function bind_env(func) {
  if (typeof func == 'function') {
    return Meteor.bindEnvironment(func, function (err) { throw err });
  }
  else {
    return func;
  }
}

var subWrapper = function (sub, func) {
  return function(test, onComplete) {
    if (Meteor.isClient) {
      Deps.autorun(function () {
        if (sub.ready()) {
          func(test, onComplete);
        }
      });
    } else {
      func(test, onComplete);
    }
  };
};

var defaultColl = new FileCollection();

Tinytest.add('FileCollection default constructor', function(test) {
  test.instanceOf(defaultColl, FileCollection, "FileCollection constructor failed");
  test.equal(defaultColl.root, 'fs', "default root isn't 'fs'");
  test.equal(defaultColl.chunkSize, 2*1024*1024, "bad default chunksize");
  test.equal(defaultColl.baseURL, "/gridfs/fs", "bad default base URL");
});

var testColl = new FileCollection("test", {
  baseURL: "/test",
  chunkSize: 1024*1024,
  resumable: true,
  http: [
     { method: 'get', path: '/:_id', lookup: function (params, query) { return { _id: params._id }}},
     { method: 'post', path: '/:_id', lookup: function (params, query) { return { _id: params._id }}},
     { method: 'put', path: '/:_id', lookup: function (params, query) { return { _id: params._id }}},
     { method: 'delete', path: '/:_id', lookup: function (params, query) { return { _id: params._id }}}
  ]
});

var noAllowColl = new FileCollection("noAllowColl");
var denyColl = new FileCollection("denyColl");

if (Meteor.isServer) {

  Meteor.publish('everything', function () { return testColl.find({}); });
  Meteor.publish('noAllowCollPub', function () { return noAllowColl.find({}); });
  Meteor.publish('denyCollPub', function () { return denyColl.find({}); });

  var sub = null

  testColl.allow({
    insert: function () { return true; },
    update: function () { return true; },
    remove: function () { return true; }
  });
  testColl.deny({
    insert: function () { return false; },
    update: function () { return false; },
    remove: function () { return false; }
  });
  noAllowColl.allow({
    insert: function () { return false; },
    update: function () { return false; },
    remove: function () { return false; }
  });
  denyColl.deny({
    insert: function () { return true; },
    update: function () { return true; },
    remove: function () { return true; }
  });

  Tinytest.add('set allow/deny on FileCollection', function(test) {
    test.equal(testColl.allows.insert[0](), true);
    test.equal(testColl.allows.remove[0](), true);
    test.equal(testColl.allows.update[0](), true);
    test.equal(testColl.denys.update[0](), false);
    test.equal(testColl.denys.insert[0](), false);
    test.equal(testColl.denys.remove[0](), false);
  });

  Tinytest.add('check server REST API', function (test) {
    test.equal(typeof testColl.router, 'function');
  });
}

if (Meteor.isClient) {

  var sub = Meteor.subscribe('everything');

  Tinytest.add('Client has Resumable', function(test) {
    test.instanceOf(testColl.resumable, Resumable, "Resumable object not found");
  });
}

Tinytest.add('FileCollection constructor with options', function(test) {
  test.instanceOf(testColl, FileCollection, "FileCollection constructor failed");
  test.equal(testColl.root, 'test', "root collection not properly set");
  test.equal(testColl.chunkSize, 1024*1024, "chunkSize not set properly");
  test.equal(testColl.baseURL, "/test", "base URL not set properly");
});

Tinytest.add('FileCollection insert and findOne', function(test) {
  var _id = testColl.insert({});
  test.isNotNull(_id, "No _id returned by insert");
  test.instanceOf(_id, Meteor.Collection.ObjectID);
  var file = testColl.findOne({_id : _id});
  test.isNotNull(file, "Invalid file returned by findOne");
  test.equal(typeof file, "object");
  test.equal(file.length, 0);
  test.equal(file.md5, 'd41d8cd98f00b204e9800998ecf8427e')
  test.instanceOf(file.uploadDate, Date);
  test.equal(file.chunkSize, 1024*1024);
  test.equal(file.filename, '');
  test.equal(typeof file.metadata, "object");
  test.instanceOf(file.aliases, Array);
  test.equal(file.contentType, 'application/octet-stream')
});

Tinytest.addAsync('FileCollection insert and findOne in callback', subWrapper(sub, function(test, onComplete) {
  var _id = testColl.insert({}, function (err, retid) {
    if (err) { test.fail(err); }
    test.isNotNull(_id, "No _id returned by insert");
    test.isNotNull(retid, "No _id returned by insert callback");
    test.instanceOf(_id, Meteor.Collection.ObjectID, "_id is wrong type");
    test.instanceOf(retid, Meteor.Collection.ObjectID, "retid is wrong type");
    test.equal(_id, retid, "different ids returned in return and callback");
    var file = testColl.findOne({_id : retid});
    test.isNotNull(file, "Invalid file returned by findOne");
    test.equal(typeof file, "object");
    test.equal(file.length, 0);
    test.equal(file.md5, 'd41d8cd98f00b204e9800998ecf8427e');
    test.instanceOf(file.uploadDate, Date);
    test.equal(file.chunkSize, 1024*1024);
    test.equal(file.filename, '');
    test.equal(typeof file.metadata, "object");
    test.instanceOf(file.aliases, Array);
    test.equal(file.contentType, 'application/octet-stream');
    onComplete();
  });
}));

Tinytest.add('FileCollection insert and find with options', function(test) {
  var _id = testColl.insert({ filename: 'testfile', metadata: { x: 1 }, aliases: ["foo"], contentType: 'text/plain' });
  test.isNotNull(_id, "No _id returned by insert");
  test.instanceOf(_id, Meteor.Collection.ObjectID);
  var file = testColl.findOne({_id : _id});
  test.isNotNull(file, "Invalid file returned by findOne");
  test.equal(typeof file, "object");
  test.equal(file.length, 0);
  test.equal(file.md5, 'd41d8cd98f00b204e9800998ecf8427e');
  test.instanceOf(file.uploadDate, Date);
  test.equal(file.chunkSize, 1024*1024);
  test.equal(file.filename, 'testfile');
  test.equal(typeof file.metadata, "object");
  test.equal(file.metadata.x, 1);
  test.instanceOf(file.aliases, Array);
  test.equal(file.aliases[0], 'foo');
  test.equal(file.contentType, 'text/plain');
});

Tinytest.addAsync('FileCollection insert and find with options in callback', subWrapper(sub, function(test, onComplete) {
  var _id = testColl.insert({ filename: 'testfile', metadata: { x: 1 }, aliases: ["foo"], contentType: 'text/plain' }, function(err, retid) {
    if (err) { test.fail(err); }
    test.isNotNull(_id, "No _id returned by insert");
    test.isNotNull(retid, "No _id returned by insert callback");
    test.instanceOf(_id, Meteor.Collection.ObjectID, "_id is wrong type");
    test.instanceOf(retid, Meteor.Collection.ObjectID, "retid is wrong type");
    test.equal(_id, retid, "different ids returned in return and callback");
    var file = testColl.findOne({_id : retid});
    test.isNotNull(file, "Invalid file returned by findOne");
    test.equal(typeof file, "object");
    test.equal(file.length, 0);
    test.equal(file.md5, 'd41d8cd98f00b204e9800998ecf8427e');
    test.instanceOf(file.uploadDate, Date);
    test.equal(file.chunkSize, 1024*1024);
    test.equal(file.filename, 'testfile');
    test.equal(typeof file.metadata, "object");
    test.equal(file.metadata.x, 1);
    test.instanceOf(file.aliases, Array);
    test.equal(file.aliases[0], 'foo');
    test.equal(file.contentType, 'text/plain');
    onComplete();
  });
}));

if (Meteor.isServer) {

  Tinytest.addAsync('Upsert stream to gridfs and read back, write to file system, and re-import', function(test, onComplete) {
    var _id = testColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function (err, _id) {
      if (err) { test.fail(err); }
      var writestream = testColl.upsertStream({ _id: _id });
      writestream.on('close', bind_env(function (file) {
        test.equal(typeof file, 'object', "Bad file object after upsert stream");
        test.equal(file.length, 10, "Improper file length");
        test.equal(file.md5, 'e807f1fcf82d132f9bb018ca6738a19f', "Improper file md5 hash");
        var readstream = testColl.findOneStream({_id: file._id });
        readstream.on('data', bind_env(function (chunk) {
          test.equal(chunk.toString(), '1234567890','Incorrect data read back from stream');
        }));
        readstream.on('end', bind_env(function () {
          var testfile = "/tmp/FileCollection." + file._id + ".test"
          testColl.exportFile(file, testfile, bind_env(function (err, doc) {
            if (err) { test.fail(err); }
            testColl.importFile(testfile, {}, bind_env(function (err, doc) {
              if (err) { test.fail(err); }
              var readstream = testColl.findOneStream({_id: doc._id });
              readstream.on('data', bind_env(function (chunk) {
                test.equal(chunk.toString(), '1234567890','Incorrect data read back from file stream');
              }));
              readstream.on('end', bind_env(function () {
                onComplete();
              }));
            }));
          }));
        }));
      }));
      writestream.write('1234567890');
      writestream.end();
    });
  });
}

Tinytest.addAsync('REST API PUT/GET', function(test, onComplete) {
  var _id = testColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function (err, _id) {
    if (err) { test.fail(err); }
    var url = Meteor.absoluteUrl('test/'+_id);
    HTTP.put(url, { content: '0987654321'}, function (err, res) {
      if (err) { test.fail(err); }
      HTTP.get(url, function (err, res) {
        if (err) { test.fail(err); }
        test.equal(res.content,'0987654321');
        onComplete();
      });
    });
  });
});

Tinytest.addAsync('REST API POST/GET/DELETE', function(test, onComplete) {
  var _id = testColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function (err, _id) {
    if (err) { test.fail(err); }
    var url = Meteor.absoluteUrl('test/'+_id);
    HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: '--AaB03x\r\nContent-Disposition: form-data; name="file"; filename="foobar"\r\nContent-Type: text/plain\r\n\r\nABCDEFGHIJ\r\n--AaB03x--'},
      function (err, res) {
        if (err) { test.fail(err); }
        HTTP.get(url, function (err, res) {
          if (err) { test.fail(err); }
          test.equal(res.content,'ABCDEFGHIJ');
          HTTP.del(url, function (err, res) {
            if (err) { test.fail(err); }
            onComplete();
          });
        });
      });
  });
});


if (Meteor.isClient) {
  var noAllowSub = Meteor.subscribe('noAllowCollPub');
  var denySub = Meteor.subscribe('denyCollPub');

  Tinytest.add('Reject insert without true allow rule', subWrapper(noAllowSub, function(test, onComplete) {
    var _id = noAllowColl.insert({}, function (err, retid) {
      if (err) {
        test.equal(err.error, 403);
        onComplete();
      } else {
        test.fail(new Error("Insert without allow succeeded."));
      }
    });
  }));

  Tinytest.add('Reject insert with true deny rule', subWrapper(denySub, function(test, onComplete) {
    var _id = denyColl.insert({}, function (err, retid) {
      if (err) {
        test.equal(err.error, 403);
        onComplete();
      } else {
        test.fail(new Error("Insert with deny succeeded."));
      }
    });
  }));
}


