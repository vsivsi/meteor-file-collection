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

Tinytest.add('fileCollection default constructor', function(test) {
  var defaultColl = new fileCollection();
  test.instanceOf(defaultColl, fileCollection, "fileCollection constructor failed");
  test.equal(defaultColl.root, 'fs', "default root isn't 'fs'");
  test.equal(defaultColl.chunkSize, 2*1024*1024, "bad default chunksize");
  test.equal(defaultColl.baseURL, "/gridfs/fs", "bad default base URL");
});

var testColl = new fileCollection("test", {
  baseURL: "/something/else",
  chunkSize: 1024*1024
});

if (Meteor.isServer) {
  testColl.allow({
    insert: function () { return true; },
    update: function () { return false; },
    remove: function () { return true; }
  });
  testColl.deny({
    insert: function () { return false; },
    update: function () { return true; },
    remove: function () { return false; }
  });
  Tinytest.add('set allow/deny on fileCollection', function(test) {
    test.equal(testColl.allows.insert[0](), true);
    test.equal(testColl.allows.remove[0](), true);
    test.equal(testColl.denys.update[0](), true);
    test.equal(testColl.allows.update[0](), false);
    test.equal(testColl.denys.insert[0](), false);
    test.equal(testColl.denys.remove[0](), false);
  });
}

Tinytest.add('fileCollection constructor with options', function(test) {
  test.instanceOf(testColl, fileCollection, "fileCollection constructor failed");
  test.equal(testColl.root, 'test', "root collection not properly set");
  test.equal(testColl.chunkSize, 1024*1024, "chunkSize not set properly");
  test.equal(testColl.baseURL, "/something/else", "base URL not set properly");
});

Tinytest.add('fileCollection insert and findOne', function(test) {
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

Tinytest.add('fileCollection insert and find with options', function(test) {
  var _id = testColl.insert({ filename: 'testfile', metadata: { x: 1 }, aliases: ["foo"], contentType: 'text/plain' });
  test.isNotNull(_id, "No _id returned by insert");
  test.instanceOf(_id, Meteor.Collection.ObjectID);
  var file = testColl.findOne({_id : _id});
  test.isNotNull(file, "Invalid file returned by findOne");
  test.equal(typeof file, "object");
  test.equal(file.length, 0);
  test.equal(file.md5, 'd41d8cd98f00b204e9800998ecf8427e')
  test.instanceOf(file.uploadDate, Date);
  test.equal(file.chunkSize, 1024*1024);
  test.equal(file.filename, 'testfile');
  test.equal(typeof file.metadata, "object");
  test.equal(file.metadata.x, 1);
  test.instanceOf(file.aliases, Array);
  test.equal(file.aliases[0], 'foo');
  test.equal(file.contentType, 'text/plain')
});

if (Meteor.isServer) {

  Tinytest.addAsync('Upsert stream to gridfs and read back, write to file system, and re-import', function(test, onComplete) {
    var _id = testColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function (err, _id) {
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
            var testfile = "/tmp/fileCollection." + file._id + ".test"
            testColl.exportFile(file, testfile, bind_env(function (err, doc) {
              testColl.importFile(testfile, {}, bind_env(function (err, doc) {
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

// Tinytest.addAsync('fileCollection insert empty file', function(test, expect) {
//   testColl.insert({}, expect(function (err, doc) {
//     if (err) { return test.fail(err) }
//     console.log("Return from insert", doc);
//     return test.instanceOf(doc, Object);
//   }));
// });

if (Meteor.isClient) {
  var R = new Resumable();
  Tinytest.add('client has Resumable', function(test) {
    console.log("In client");
    return test.instanceOf(R, Resumable, "Failure");
  });
}

if (Meteor.isServer) {
  Tinytest.add('', function(test) {
    console.log("In server");
    return test.equal(true, true, "Failure");
  });
}


