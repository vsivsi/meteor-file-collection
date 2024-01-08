/*
 * decaffeinate suggestions:
 * DS102: Remove unnecessary code created because of implicit returns
 * DS207: Consider shorter variations of null checks
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/main/docs/suggestions.md
 */
//###########################################################################
//     Copyright (C) 2014-2017 by Vaughn Iverson
//     fileCollection is free software released under the MIT/X11 license.
//     See included LICENSE file for details.
//###########################################################################

let os, path, sub;
if (Meteor.isServer) {
    os = Npm.require('os');
    path = Npm.require('path');
}

const bind_env = function(func) {
    if (typeof func === 'function') {
        return Meteor.bindEnvironment(func, function(err) { throw err; });
    } else {
        return func;
    }
};

const subWrapper = (sub, func) => (function(test, onComplete) {
    if (Meteor.isClient) {
        return Tracker.autorun(function() {
            if (sub.ready()) {
                return func(test, onComplete);
            }
        });
    } else {
        return func(test, onComplete);
    }
});

const defaultColl = new FileCollection();

Tinytest.add('FileCollection default constructor', function(test) {
    test.instanceOf(defaultColl, FileCollection, "FileCollection constructor failed");
    test.equal(defaultColl.root, 'fs', "default root isn't 'fs'");
    test.equal(defaultColl.chunkSize, (2*1024*1024) - 1024, "bad default chunksize");
    return test.equal(defaultColl.baseURL, "/gridfs/fs", "bad default base URL");
});

const idLookup = (params, query) => ({
    _id: params._id
});

let longString = '';
while (longString.length < 4096) {
    longString += '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
}

const testColl = new FileCollection("test", {
    baseURL: "/test",
    chunkSize: 16,
    resumable: true,
    maxUploadSize: 2048,
    http: [
        { method: 'get', path: '/:_id', lookup: idLookup},
        { method: 'post', path: '/:_id', lookup: idLookup},
        { method: 'put', path: '/:_id', lookup: idLookup},
        { method: 'delete', path: '/:_id', lookup: idLookup},
        { method: 'options', path: '/:_id', lookup: idLookup, handler(req, res, next) {
                res.writeHead(200, { 'Content-Type': 'text/plain', 'Access-Control-Allow-Origin': 'http://meteor.local' });
                res.end();
            }
        }
    ]
});

const noReadColl = new FileCollection("noReadColl", {
    baseURL: "/noread",
    chunkSize: 1024*1024,
    resumable: false,
    http: [
        { method: 'get', path: '/:_id', lookup: idLookup},
        { method: 'post', path: '/:_id', lookup: idLookup},
        { method: 'put', path: '/:_id', lookup: idLookup},
        { method: 'delete', path: '/:_id', lookup: idLookup}
    ]
});

const noAllowColl = new FileCollection("noAllowColl");
const denyColl = new FileCollection("denyColl");

Meteor.methods({
    updateTest(id, reject) {
        check(id, Mongo.ObjectID);
        check(reject, Boolean);
        if (this.isSimulation) {
            return testColl.localUpdate({ _id: id }, { $set: { 'metadata.test2': true } });
        } else if (reject) {
            throw new Meteor.Error("Rejected by server");
        } else {
            return testColl.update({ _id: id }, { $set: { 'metadata.test2': false } });
        }
    }});

if (Meteor.isServer) {

    Meteor.publish('everything', () => testColl.find({}));
    Meteor.publish('noAllowCollPub', () => noAllowColl.find({}));
    Meteor.publish('noReadCollPub', () => noReadColl.find({}));
    Meteor.publish('denyCollPub', () => denyColl.find({}));

    sub = null;

    testColl.allow({
        insert() { return true; },
        write() { return true; },
        remove() { return true; },
        read() { return true; }
    });

    testColl.deny({
        insert() { return false; },
        write() { return false; },
        remove() { return false; },
        read() { return false; }
    });

    noAllowColl.allow({
        read() { return false; },
        insert() { return false; },
        write() { return false; },
        remove() { return false; }
    });

    noReadColl.allow({
        read() { return false; },
        insert() { return true; },
        write() { return { maxUploadSize: 15 }; },
        remove() { return true; }
    });

    noReadColl.deny({
        read() { return false; },
        insert() { return false; },
        write() { return false; },
        remove() { return false; }
    });

    denyColl.deny({
        read() { return true; },
        insert() { return true; },
        write() { return true; },
        remove() { return true; }
    });

    Tinytest.add('set allow/deny on FileCollection', function(test) {
        test.equal(testColl.allows.read[0](), true);
        test.equal(testColl.allows.insert[0](), true);
        test.equal(testColl.allows.remove[0](), true);
        test.equal(testColl.allows.write[0](), true);
        test.equal(testColl.denys.read[0](), false);
        test.equal(testColl.denys.write[0](), false);
        test.equal(testColl.denys.insert[0](), false);
        return test.equal(testColl.denys.remove[0](), false);
    });

    Tinytest.add('check server REST API', test => test.equal(typeof testColl.router, 'function'));
}

if (Meteor.isClient) {
    sub = Meteor.subscribe('everything');

    Tinytest.add('Server-only methods throw on client', function(test) {
        test.throws(() => testColl.allow({}));
        test.throws(() => testColl.deny({}));
        test.throws(() => testColl.upsert({}));
        test.throws(() => testColl.update({}));
        test.throws(() => testColl.findOneStream({}));
        test.throws(() => testColl.upsertStream({}));
        test.throws(() => testColl.importFile({}));
        return test.throws(() => testColl.exportFile({}));
    });
}

Tinytest.add('FileCollection constructor with options', function(test) {
    test.instanceOf(testColl, FileCollection, "FileCollection constructor failed");
    test.equal(testColl.root, 'test', "root collection not properly set");
    test.equal(testColl.chunkSize, 16, "chunkSize not set properly");
    return test.equal(testColl.baseURL, "/test", "base URL not set properly");
});

Tinytest.add('FileCollection insert, findOne and remove', function(test) {
    const _id = testColl.insert({});
    test.isNotNull(_id, "No _id returned by insert");
    test.instanceOf(_id, Mongo.ObjectID);
    let file = testColl.findOne({_id});
    test.isNotNull(file, "Invalid file returned by findOne");
    test.equal(typeof file, "object");
    test.equal(file.length, 0);
    test.equal(file.md5, 'd41d8cd98f00b204e9800998ecf8427e');
    test.instanceOf(file.uploadDate, Date);
    test.equal(file.chunkSize, 16);
    test.equal(file.filename, '');
    test.equal(typeof file.metadata, "object");
    test.instanceOf(file.aliases, Array);
    test.equal(file.contentType, 'application/octet-stream');
    const result = testColl.remove({_id});
    test.equal(result, 1, "Incorrect number of files removed");
    file = testColl.findOne({_id});
    return test.isUndefined(file, "File was not removed");
});

Tinytest.addAsync('FileCollection insert, findOne and remove with callback', subWrapper(sub, function(test, onComplete) {
        let _id;
        return _id = testColl.insert({}, function(err, retid) {
            if (err) { test.fail(err); }
            test.isNotNull(_id, "No _id returned by insert");
            test.isNotNull(retid, "No _id returned by insert callback");
            test.instanceOf(_id, Mongo.ObjectID, "_id is wrong type");
            test.instanceOf(retid, Mongo.ObjectID, "retid is wrong type");
            test.equal(_id, retid, "different ids returned in return and callback");
            const file = testColl.findOne({_id : retid});
            test.isNotNull(file, "Invalid file returned by findOne");
            test.equal(typeof file, "object");
            test.equal(file.length, 0);
            test.equal(file.md5, 'd41d8cd98f00b204e9800998ecf8427e');
            test.instanceOf(file.uploadDate, Date);
            test.equal(file.chunkSize, 16);
            test.equal(file.filename, '');
            test.equal(typeof file.metadata, "object");
            test.instanceOf(file.aliases, Array);
            test.equal(file.contentType, 'application/octet-stream');
            let finishCount = 0;
            const finish = function() {
                finishCount++;
                if (finishCount > 1) {
                    return onComplete();
                }
            };
            var obs = testColl.find({_id}).observeChanges({
                removed(id) {
                    obs.stop();
                    test.ok(EJSON.equals(id, _id), 'Incorrect file _id removed');
                    return finish();
                }
            });
            return testColl.remove({_id : retid}, function(err, result) {
                if (err) { test.fail(err); }
                test.equal(result, 1, "Incorrect number of files removed");
                return finish();
            });
        });
    })
);

Tinytest.add('FileCollection insert and find with options', function(test) {
    const _id = testColl.insert({ filename: 'testfile', metadata: { x: 1 }, aliases: ["foo"], contentType: 'text/plain' });
    test.isNotNull(_id, "No _id returned by insert");
    test.instanceOf(_id, Meteor.Collection.ObjectID);
    const file = testColl.findOne({_id});
    test.isNotNull(file, "Invalid file returned by findOne");
    test.equal(typeof file, "object");
    test.equal(file.length, 0);
    test.equal(file.md5, 'd41d8cd98f00b204e9800998ecf8427e');
    test.instanceOf(file.uploadDate, Date);
    test.equal(file.chunkSize, 16);
    test.equal(file.filename, 'testfile');
    test.equal(typeof file.metadata, "object");
    test.equal(file.metadata.x, 1);
    test.instanceOf(file.aliases, Array);
    test.equal(file.aliases[0], 'foo');
    return test.equal(file.contentType, 'text/plain');
});

Tinytest.addAsync('FileCollection insert and find with options in callback', subWrapper(sub, function(test, onComplete) {
        let _id;
        return _id = testColl.insert({ filename: 'testfile', metadata: { x: 1 }, aliases: ["foo"], contentType: 'text/plain' }, function(err, retid) {
            if (err) { test.fail(err); }
            test.isNotNull(_id, "No _id returned by insert");
            test.isNotNull(retid, "No _id returned by insert callback");
            test.instanceOf(_id, Mongo.ObjectID, "_id is wrong type");
            test.instanceOf(retid, Mongo.ObjectID, "retid is wrong type");
            test.equal(_id, retid, "different ids returned in return and callback");
            const file = testColl.findOne({_id : retid});
            test.isNotNull(file, "Invalid file returned by findOne");
            test.equal(typeof file, "object");
            test.equal(file.length, 0);
            test.equal(file.md5, 'd41d8cd98f00b204e9800998ecf8427e');
            test.instanceOf(file.uploadDate, Date);
            test.equal(file.chunkSize, 16);
            test.equal(file.filename, 'testfile');
            test.equal(typeof file.metadata, "object");
            test.equal(file.metadata.x, 1);
            test.instanceOf(file.aliases, Array);
            test.equal(file.aliases[0], 'foo');
            test.equal(file.contentType, 'text/plain');
            return onComplete();
        });
    })
);

if (Meteor.isServer) {

    Tinytest.addAsync('Proper error handling for missing file on import',
        function(test, onComplete) {
            const bogusfile = "/bogus/file.not";
            return testColl.importFile(bogusfile, {}, bind_env(function(err, doc) {
                    if (!err) { test.fail(err); }
                    return onComplete();
                })
            );
        });

    Tinytest.addAsync('Server accepts good and rejects bad updates', function(test, onComplete) {
        const _id = testColl.insert();
        return testColl.update(_id, { $set: { "metadata.test": 1 } }, function(err, res) {
            if (err) { test.fail(err); }
            test.equal(res, 1);
            return testColl.update(_id, { $inc: { "metadata.test": 1 } }, function(err, res) {
                if (err) { test.fail(err); }
                test.equal(res, 1);
                const doc = testColl.findOne(_id);
                test.equal(doc.metadata.test, 2);
                return testColl.update(_id, { $set: { md5: 1 } }, function(err, res) {
                    test.isUndefined(res);
                    test.instanceOf(err, Meteor.Error);
                    return testColl.update(_id, { $unset: { filename: 1 } }, function(err, res) {
                        test.isUndefined(res);
                        test.instanceOf(err, Meteor.Error);
                        return testColl.update(_id, { foo: "bar" }, function(err, res) {
                            test.isUndefined(res);
                            test.instanceOf(err, Meteor.Error);
                            return onComplete();
                        });
                    });
                });
            });
        });
    });

    Tinytest.addAsync('Insert and then Upsert stream to gridfs and read back, write to file system, and re-import',
        function(test, onComplete) {
            let _id;
            return _id = testColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function(err, _id) {
                if (err) { test.fail(err); }
                const writestream = testColl.upsertStream({ _id });
                writestream.on('close', bind_env(function(file) {
                        test.equal(typeof file, 'object', "Bad file object after upsert stream");
                        test.equal(file.length, 10, "Improper file length");
                        test.equal(file.md5, 'e807f1fcf82d132f9bb018ca6738a19f', "Improper file md5 hash");
                        test.equal(file.contentType, 'text/plain', "Improper contentType");
                        test.equal(typeof file._id, 'object');
                        test.equal(_id, new Mongo.ObjectID(file._id.toHexString()));
                        let readstream = testColl.findOneStream({_id: file._id });
                        readstream.on('data', bind_env(chunk => test.equal(chunk.toString(), '1234567890','Incorrect data read back from stream'))
                        );
                        return readstream.on('end', bind_env(function() {
                                const testfile = path.join(os.tmpdir(), "/FileCollection." + file._id + ".test");
                                return testColl.exportFile(file, testfile, bind_env(function(err, doc) {
                                        if (err) { test.fail(err); }
                                        return testColl.importFile(testfile, {}, bind_env(function(err, doc) {
                                                if (err) { test.fail(err); }
                                                test.equal(typeof doc, 'object', "No document imported");
                                                if (typeof doc === 'object') {
                                                    readstream = testColl.findOneStream({_id: doc._id });
                                                    readstream.on('data', bind_env(chunk => test.equal(chunk.toString(), '1234567890','Incorrect data read back from file stream'))
                                                    );
                                                    return readstream.on('end', bind_env(() => onComplete())
                                                    );
                                                } else {
                                                    return onComplete();
                                                }
                                            })
                                        );
                                    })
                                );
                            })
                        );
                    })
                );
                writestream.write('1234567890');
                return writestream.end();
            });
        });

    Tinytest.addAsync('Just Upsert stream to gridfs and read back, write to file system, and re-import',
        function(test, onComplete) {
            const writestream = testColl.upsertStream({ filename: 'writefile', contentType: 'text/plain' }, bind_env(function(err, file) {
                    test.equal(typeof file, 'object', "Bad file object after upsert stream");
                    test.equal(file.length, 10, "Improper file length");
                    test.equal(file.md5, 'e46c309de99c3dfbd6acd9e77751ae98', "Improper file md5 hash");
                    test.equal(file.contentType, 'text/plain', "Improper contentType");
                    test.equal(typeof file._id, 'object');
                    test.instanceOf(file._id, Mongo.ObjectID, "_id is wrong type");
                    let readstream = testColl.findOneStream({_id: file._id });
                    readstream.on('data', bind_env(chunk => test.equal(chunk.toString(), 'ZYXWVUTSRQ','Incorrect data read back from stream'))
                    );
                    return readstream.on('end', bind_env(function() {
                            const testfile = path.join(os.tmpdir(), "/FileCollection." + file._id + ".test");
                            return testColl.exportFile(file, testfile, bind_env(function(err, doc) {
                                    if (err) { test.fail(err); }
                                    return testColl.importFile(testfile, {}, bind_env(function(err, doc) {
                                            if (err) { test.fail(err); }
                                            test.equal(typeof doc, 'object', "No document imported");
                                            if (typeof doc === 'object') {
                                                readstream = testColl.findOneStream({_id: doc._id });
                                                readstream.on('data', bind_env(chunk => test.equal(chunk.toString(), 'ZYXWVUTSRQ','Incorrect data read back from file stream'))
                                                );
                                                return readstream.on('end', bind_env(() => onComplete())
                                                );
                                            } else {
                                                return onComplete();
                                            }
                                        })
                                    );
                                })
                            );
                        })
                    );
                })
            );
            writestream.write('ZYXWVUTSRQ');
            return writestream.end();
        });
}

Tinytest.addAsync('REST API PUT/GET', function(test, onComplete) {
    let _id;
    return _id = testColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function(err, _id) {
        if (err) { test.fail(err); }
        const url = Meteor.absoluteUrl('test/' + _id);
        return HTTP.put(url, { content: '0987654321'}, function(err, res) {
            if (err) { test.fail(err); }
            return HTTP.call("OPTIONS", url, function(err, res) {
                if (err) { test.fail(err); }
                test.equal(res.headers?.['access-control-allow-origin'], 'http://meteor.local');
                return HTTP.get(url, function(err, res) {
                    if (err) { test.fail(err); }
                    test.equal(res.content, '0987654321');
                    return onComplete();
                });
            });
        });
    });
});

Tinytest.addAsync('REST API GET null id', function(test, onComplete) {
    let _id;
    return _id = testColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function(err, _id) {
        if (err) { test.fail(err); }
        const url = Meteor.absoluteUrl('test/');
        return HTTP.get(url, function(err, res) {
            test.isNotNull(err);
            if (err.response != null) {  // Not sure why, but under phantomjs the error object is different
                test.equal(err.response.statusCode, 404);
            } else {
                console.warn("PhantomJS skipped statusCode check");
            }
            return onComplete();
        });
    });
});

Tinytest.addAsync('maxUploadSize enforced by when HTTP PUT upload is too large', function(test, onComplete) {
    let _id;
    return _id = testColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function(err, _id) {
        if (err) { test.fail(err); }
        const url = Meteor.absoluteUrl('test/' + _id);
        return HTTP.put(url, { content: longString }, function(err, res) {
            test.isNotNull(err);
            if (err.response != null) {  // Not sure why, but under phantomjs the error object is different
                test.equal(err.response.statusCode, 413);
            } else {
                console.warn("PhantomJS skipped statusCode check");
            }
            return onComplete();
        });
    });
});

Tinytest.addAsync('maxUploadSize enforced by when HTTP POST upload is too large', function(test, onComplete) {
    let _id;
    return _id = testColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function(err, _id) {
        if (err) { test.fail(err); }
        const url = Meteor.absoluteUrl('test/' + _id);
        const content = `\
--AaB03x\r
Content-Disposition: form-data; name="blahBlahBlah"\r
Content-Type: text/plain\r
\r
BLAH\r
--AaB03x\r
Content-Disposition: form-data; name="file"; filename="foobar"\r
Content-Type: text/plain\r
\r
${longString}\r
--AaB03x--\r\
`;
        return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content }, function(err, res) {
            test.isNotNull(err);
            if (err.response != null) {  // Not sure why, but under phantomjs the error object is different
                test.equal(err.response.statusCode, 413);
            } else {
                console.warn("PhantomJS skipped statusCode check");
            }
            return onComplete();
        });
    });
});

Tinytest.addAsync('If-Modified-Since header support', function(test, onComplete) {
    let _id;
    return _id = testColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function(err, _id) {
        if (err) { test.fail(err); }
        const url = Meteor.absoluteUrl('test/' + _id);
        return HTTP.get(url, function(err, res) {
            if (err) { test.fail(err); }
            test.equal(res.statusCode, 200, 'Failed without If-Modified-Since header');
            let modified = res.headers['last-modified'];
            test.equal(typeof modified, 'string', 'Invalid Last-Modified response');
            return HTTP.get(url, {headers: {'If-Modified-Since': modified}}, function(err, res) {
                if (err) { test.fail(err); }
                test.equal(res.statusCode, 304, 'Returned file despite present If-Modified-Since');
                return HTTP.get(url, {headers: {'If-Modified-Since': 'hello'}}, function(err, res) {
                    if (err) { test.fail(err); }
                    test.equal(res.statusCode, 200, 'Skipped file despite unparsable If-Modified-Since');
                    modified = new Date(Date.parse(modified) - 2000).toUTCString();  //# past test
                    return HTTP.get(url, {headers: {'If-Modified-Since': modified}}, function(err, res) {
                        if (err) { test.fail(err); }
                        test.equal(res.statusCode, 200, 'Skipped file despite past If-Modified-Since');
                        modified = new Date(Date.parse(modified) + 4000).toUTCString();  //# future test
                        return HTTP.get(url, {headers: {'If-Modified-Since': modified}}, function(err, res) {
                            if (err) { test.fail(err); }
                            test.equal(res.statusCode, 304, 'Returned file despite future If-Modified-Since');
                            return onComplete();
                        });
                    });
                });
            });
        });
    });
});

Tinytest.addAsync('REST API POST/GET/DELETE', function(test, onComplete) {
    let _id;
    return _id = testColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function(err, _id) {
        if (err) { test.fail(err); }
        const url = Meteor.absoluteUrl('test/' + _id);
        const content = `\
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
--AaB03x--\r\
`;
        return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content},
            function(err, res) {
                if (err) { test.fail(err); }
                return HTTP.get(url, function(err, res) {
                    if (err) { test.fail(err); }
                    test.equal(res.content,'ABCDEFGHIJ');
                    return HTTP.del(url, function(err, res) {
                        if (err) { test.fail(err); }
                        return onComplete();
                    });
                });
            });
    });
});

const createContent = function(_id, data, name, chunkNum, chunkSize) {
    if (chunkSize == null) { chunkSize = 16; }
    let totalChunks = Math.floor(data.length / chunkSize);
    if ((totalChunks*chunkSize) !== data.length) { totalChunks += 1; }
    if (chunkNum > totalChunks) { throw new Error("Bad chunkNum"); }
    const begin = (chunkNum - 1) * chunkSize;
    const end = chunkNum === totalChunks ? data.length : chunkNum * chunkSize;

    return `\
--AaB03x\r
Content-Disposition: form-data; name="resumableChunkNumber"\r
Content-Type: text/plain\r
\r
${chunkNum}\r
--AaB03x\r
Content-Disposition: form-data; name="resumableChunkSize"\r
Content-Type: text/plain\r
\r
${chunkSize}\r
--AaB03x\r
Content-Disposition: form-data; name="resumableCurrentChunkSize"\r
Content-Type: text/plain\r
\r
${end - begin}\r
--AaB03x\r
Content-Disposition: form-data; name="resumableTotalSize"\r
Content-Type: text/plain\r
\r
${data.length}\r
--AaB03x\r
Content-Disposition: form-data; name="resumableType"\r
Content-Type: text/plain\r
\r
text/plain\r
--AaB03x\r
Content-Disposition: form-data; name="resumableIdentifier"\r
Content-Type: text/plain\r
\r
${_id._str}\r
--AaB03x\r
Content-Disposition: form-data; name="resumableFilename"\r
Content-Type: text/plain\r
\r
${name}\r
--AaB03x\r
Content-Disposition: form-data; name="resumableRelativePath"\r
Content-Type: text/plain\r
\r
${name}\r
--AaB03x\r
Content-Disposition: form-data; name="resumableTotalChunks"\r
Content-Type: text/plain\r
\r
${totalChunks}\r
--AaB03x\r
Content-Disposition: form-data; name="file"; filename="${name}"\r
Content-Type: text/plain\r
\r
${data.substring(begin, end)}\r
--AaB03x--\r\
`;
};

const createCheckQuery = function(_id, data, name, chunkNum, chunkSize) {
    if (chunkSize == null) { chunkSize = 16; }
    let totalChunks = Math.floor(data.length / chunkSize);
    if ((totalChunks*chunkSize) !== data.length) { totalChunks += 1; }
    if (chunkNum > totalChunks) { throw new Error("Bad chunkNum"); }
    const begin = (chunkNum - 1) * chunkSize;
    const end = chunkNum === totalChunks ? data.length : chunkNum * chunkSize;
    return `?resumableChunkNumber=${chunkNum}&resumableChunkSize=${chunkSize}&resumableCurrentChunkSize=${end-begin}&resumableTotalSize=${data.length}&resumableType=text/plain&resumableIdentifier=${_id._str}&resumableFilename=${name}&resumableRelativePath=${name}&resumableTotalChunks=${totalChunks}`;
};

Tinytest.addAsync('Basic resumable.js REST interface POST/GET/DELETE', (test, onComplete) => testColl.insert({ filename: 'writeresumablefile', contentType: 'text/plain' }, function(err, _id) {
    if (err) { test.fail(err); }
    let url = Meteor.absoluteUrl("test/_resumable");
    const data = 'ABCDEFGHIJ';
    const content = createContent(_id, data, "writeresumablefile", 1);
    return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content },
        function(err, res) {
            if (err) { test.fail(err); }
            url = Meteor.absoluteUrl('test/' + _id);
            return HTTP.get(url, function(err, res) {
                if (err) { test.fail(err); }
                test.equal(res.content, data);
                return HTTP.del(url, function(err, res) {
                    if (err) { test.fail(err); }
                    return onComplete();
                });
            });
        });
}));

Tinytest.addAsync('Basic resumable.js REST interface POST/GET/DELETE, multiple chunks', function(test, onComplete) {

    const data = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345';

    return testColl.insert({ filename: 'writeresumablefile', contentType: 'text/plain' }, function(err, _id) {
        if (err) { test.fail(err); }
        let url = Meteor.absoluteUrl("test/_resumable");
        const content = createContent(_id, data, "writeresumablefile", 1);
        const content2 = createContent(_id, data, "writeresumablefile", 2);
        return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content },
            function(err, res) {
                if (err) { test.fail(err); }
                return HTTP.get(url + createCheckQuery(_id, data, "writeresumablefile", 2), function(err, res) {
                    if (err) { test.fail(err); }
                    test.equal(res.statusCode, 204);
                    return HTTP.call('head', url + createCheckQuery(_id, data, "writeresumablefile", 1), function(err, res) {
                        if (err) { test.fail(err); }
                        test.equal(res.statusCode, 200);
                        return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content2 },
                            function(err, res) {
                                if (err) { test.fail(err); }
                                url = Meteor.absoluteUrl('test/' + _id);
                                return HTTP.get(url, function(err, res) {
                                    if (err) { test.fail(err); }
                                    test.equal(res.content, data);
                                    return HTTP.del(url, function(err, res) {
                                        if (err) { test.fail(err); }
                                        return onComplete();
                                    });
                                });
                            });
                    });
                });
            });
    });
});

Tinytest.addAsync('Basic resumable.js REST interface POST/GET/DELETE, duplicate chunks', function(test, onComplete) {

    const data = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345';

    return testColl.insert({ filename: 'writeresumablefile', contentType: 'text/plain' }, function(err, _id) {
        if (err) { test.fail(err); }
        let url = Meteor.absoluteUrl("test/_resumable");
        const content = createContent(_id, data, "writeresumablefile", 1);
        const content2 = createContent(_id, data, "writeresumablefile", 2);
        return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content2 },
            function(err, res) {
                if (err) { test.fail(err); }
                return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content2 },
                    function(err, res) {
                        if (err) { test.fail(err); }
                        return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content },
                            function(err, res) {
                                if (err) { test.fail(err); }
                                url = Meteor.absoluteUrl('test/' + _id);
                                return HTTP.get(url, function(err, res) {
                                    if (err) { test.fail(err); }
                                    test.equal(res.content, data);
                                    return HTTP.del(url, function(err, res) {
                                        if (err) { test.fail(err); }
                                        return onComplete();
                                    });
                                });
                            });
                    });
            });
    });
});

Tinytest.addAsync('Basic resumable.js REST interface POST/GET/DELETE, duplicate chunks 2', function(test, onComplete) {

    const data = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345';

    return testColl.insert({ filename: 'writeresumablefile', contentType: 'text/plain' }, function(err, _id) {
        if (err) { test.fail(err); }
        let url = Meteor.absoluteUrl("test/_resumable");
        const content = createContent(_id, data, "writeresumablefile", 1);
        const content2 = createContent(_id, data, "writeresumablefile", 2);
        return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content },
            function(err, res) {
                if (err) { test.fail(err); }
                return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content2 },
                    function(err, res) {
                        if (err) { test.fail(err); }
                        return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content },
                            function(err, res) {
                                if (err) { test.fail(err); }
                                url = Meteor.absoluteUrl('test/' + _id);
                                return HTTP.get(url, function(err, res) {
                                    if (err) { test.fail(err); }
                                    test.equal(res.content, data);
                                    return HTTP.del(url, function(err, res) {
                                        if (err) { test.fail(err); }
                                        return onComplete();
                                    });
                                });
                            });
                    });
            });
    });
});

Tinytest.addAsync('Basic resumable.js REST interface POST/GET/DELETE, duplicate chunks 3', function(test, onComplete) {

    const data = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef';

    return testColl.insert({ filename: 'writeresumablefile', contentType: 'text/plain' }, function(err, _id) {
        if (err) { test.fail(err); }
        let url = Meteor.absoluteUrl("test/_resumable");
        const content = createContent(_id, data, "writeresumablefile", 1);
        const content2 = createContent(_id, data, "writeresumablefile", 2);
        const content3 = createContent(_id, data, "writeresumablefile", 3);
        return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content2 },
            function(err, res) {
                if (err) { test.fail(err); }
                return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content },
                    function(err, res) {
                        if (err) { test.fail(err); }
                        return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content2 },
                            function(err, res) {
                                if (err) { test.fail(err); }
                                return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content },
                                    function(err, res) {
                                        if (err) { test.fail(err); }
                                        return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content: content3 },
                                            function(err, res) {
                                                if (err) { test.fail(err); }
                                                url = Meteor.absoluteUrl('test/' + _id);
                                                return HTTP.get(url, function(err, res) {
                                                    if (err) { test.fail(err); }
                                                    test.equal(res.content, data);
                                                    return HTTP.del(url, function(err, res) {
                                                        if (err) { test.fail(err); }
                                                        return onComplete();
                                                    });
                                                });
                                            });
                                    });
                            });
                    });
            });
    });
});

Tinytest.addAsync('maxUploadSize enforced by when resumable.js upload is too large', (test, onComplete) => testColl.insert({ filename: 'writeresumablefile', contentType: 'text/plain' }, function(err, _id) {
    if (err) { test.fail(err); }
    const url = Meteor.absoluteUrl("test/_resumable");
    const content = createContent(_id, longString, "writeresumablefile", 1);
    return HTTP.post(url, { headers: { 'Content-Type': 'multipart/form-data; boundary="AaB03x"'}, content },
        function(err, res) {
            test.isNotNull(err);
            if (err.response != null) {  // Not sure why, but under phantomjs the error object is different
                test.equal(err.response.statusCode, 413);
            } else {
                console.warn("PhantomJS skipped statusCode check");
            }
            return onComplete();
        });
}));

Tinytest.addAsync('REST API valid range requests', function(test, onComplete) {
    let _id;
    return _id = testColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function(err, _id) {
        if (err) { test.fail(err); }
        const url = Meteor.absoluteUrl('test/' + _id);
        return HTTP.put(url, { content: '0987654321'}, function(err, res) {
            if (err) { test.fail(err); }
            return HTTP.get(url, { headers: { 'Range': '0-'}},
                function(err, res) {
                    if (err) { test.fail(err); }
                    test.equal(res.headers['content-range'], 'bytes 0-9/10');
                    test.equal(res.headers['accept-ranges'], 'bytes');
                    test.equal(res.statusCode, 206);
                    test.equal(res.content, '0987654321');
                    return HTTP.get(url, { headers: { 'Range': '0-9'}},
                        function(err, res) {
                            if (err) { test.fail(err); }
                            test.equal(res.headers['content-range'], 'bytes 0-9/10');
                            test.equal(res.headers['accept-ranges'], 'bytes');
                            test.equal(res.statusCode, 206);
                            test.equal(res.content, '0987654321');
                            return HTTP.get(url, { headers: { 'Range': '5-7'}},
                                function(err, res) {
                                    if (err) { test.fail(err); }
                                    test.equal(res.headers['content-range'], 'bytes 5-7/10');
                                    test.equal(res.headers['accept-ranges'], 'bytes');
                                    test.equal(res.statusCode, 206);
                                    test.equal(res.content, '543');
                                    return onComplete();
                                });
                        });
                });
        });
    });
});

Tinytest.addAsync('REST API invalid range requests', function(test, onComplete) {
    let _id;
    return _id = testColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function(err, _id) {
        if (err) { test.fail(err); }
        const url = Meteor.absoluteUrl('test/' + _id);
        return HTTP.put(url, { content: '0987654321'}, function(err, res) {
            if (err) { test.fail(err); }
            return HTTP.get(url, { headers: { 'Range': '0-10'}}, function(err, res) {
                test.isNotNull(err);
                if (err.response != null) {  // Not sure why, but under phantomjs the error object is different
                    test.equal(err.response.statusCode, 416);
                } else {
                    console.warn("PhantomJS skipped statusCode check");
                }
                return HTTP.get(url, { headers: { 'Range': '5-3'}}, function(err, res) {
                    test.isNotNull(err);
                    if (err.response != null) {  // Not sure why, but under phantomjs the error object is different
                        test.equal(err.response.statusCode, 416);
                    } else {
                        console.warn("PhantomJS skipped statusCode check");
                    }
                    return HTTP.get(url, { headers: { 'Range': '-1-5'}}, function(err, res) {
                        test.isNotNull(err);
                        if (err.response != null) {  // Not sure why, but under phantomjs the error object is different
                            test.equal(err.response.statusCode, 416);
                        } else {
                            console.warn("PhantomJS skipped statusCode check");
                        }
                        return HTTP.get(url, { headers: { 'Range': '1-abc'}}, function(err, res) {
                            test.isNotNull(err);
                            if (err.response != null) {  // Not sure why, but under phantomjs the error object is different
                                test.equal(err.response.statusCode, 416);
                            } else {
                                console.warn("PhantomJS skipped statusCode check");
                            }
                            return onComplete();
                        });
                    });
                });
            });
        });
    });
});

Tinytest.addAsync('REST API requests header manipilation', function(test, onComplete) {
    let _id;
    return _id = testColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function(err, _id) {
        if (err) { test.fail(err); }
        const url = Meteor.absoluteUrl('test/' + _id);
        return HTTP.put(url, { content: '0987654321'}, function(err, res) {
            if (err) { test.fail(err); }
            return HTTP.get(url+'?download=true', function(err, res) {
                test.equal(res.headers['content-disposition'], "attachment; filename=\"writefile\"; filename*=UTF-8''writefile");
                test.equal(res.statusCode, 200);
                return HTTP.get(url+'?cache=123456', { headers: { 'Range': '1-5'}},
                    function(err, res) {
                        test.equal(res.headers['cache-control'], 'max-age=123456, private');
                        test.equal(res.statusCode, 206);
                        return HTTP.get(url+'?cache=123', function(err, res) {
                            test.equal(res.headers['cache-control'], 'max-age=123, private');
                            test.equal(res.statusCode, 200);
                            return onComplete();
                        });
                    });
            });
        });
    });
});

Tinytest.addAsync('REST API requests header manipilation, UTF-8', function(test, onComplete) {
    let _id;
    return _id = testColl.insert({ filename: '中文指南.txt', contentType: 'text/plain' }, function(err, _id) {
        if (err) { test.fail(err); }
        const url = Meteor.absoluteUrl('test/' + _id);
        return HTTP.put(url, { content: '0987654321'}, function(err, res) {
            if (err) { test.fail(err); }
            return HTTP.get(url+'?download=true', function(err, res) {
                test.equal(res.headers['content-disposition'], "attachment; filename=\"%E4%B8%AD%E6%96%87%E6%8C%87%E5%8D%97.txt\"; filename*=UTF-8''%E4%B8%AD%E6%96%87%E6%8C%87%E5%8D%97.txt");
                test.equal(res.statusCode, 200);
                return HTTP.get(url+'?cache=123456', { headers: { 'Range': '1-5'}},
                    function(err, res) {
                        test.equal(res.headers['cache-control'], 'max-age=123456, private');
                        test.equal(res.statusCode, 206);
                        return HTTP.get(url+'?cache=123', function(err, res) {
                            test.equal(res.headers['cache-control'], 'max-age=123, private');
                            test.equal(res.statusCode, 200);
                            return onComplete();
                        });
                    });
            });
        });
    });
});

if (Meteor.isClient) {

    const noAllowSub = Meteor.subscribe('noAllowCollPub');
    const noReadSub = Meteor.subscribe('noReadCollPub');
    const denySub = Meteor.subscribe('denyCollPub');

    Tinytest.addAsync('Reject insert without true allow rule', subWrapper(noAllowSub, function(test, onComplete) {
            let _id;
            return _id = noAllowColl.insert({}, function(err, retid) {
                if (err) {
                    test.equal(err.error, 403);
                } else {
                    test.fail(new Error("Insert without allow succeeded."));
                }
                return onComplete();
            });
        })
    );

    Tinytest.addAsync('Reject insert with true deny rule', subWrapper(denySub, function(test, onComplete) {
            let _id;
            return _id = denyColl.insert({}, function(err, retid) {
                if (err) {
                    test.equal(err.error, 403);
                } else {
                    test.fail(new Error("Insert with deny succeeded."));
                }
                return onComplete();
            });
        })
    );

    Tinytest.addAsync('Reject HTTP GET without true allow rule', subWrapper(noReadSub, function(test, onComplete) {
            let _id;
            return _id = noReadColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function(err, _id) {
                if (err) { test.fail(err); }
                const url = Meteor.absoluteUrl('noread/' + _id);
                return HTTP.put(url, { content: '0987654321'}, function(err, res) {
                    if (err) { test.fail(err); }
                    return HTTP.get(url, function(err, res) {
                        test.isNotNull(err);
                        if (err.response != null) {  // Not sure why, but under phantomjs the error object is different
                            test.equal(err.response.statusCode, 403);
                        } else {
                            console.warn("PhantomJS skipped statusCode check");
                        }
                        return onComplete();
                    });
                });
            });
        })
    );

    Tinytest.addAsync('Reject HTTP PUT larger than write allow rule allows', subWrapper(noReadSub, function(test, onComplete) {
            let _id;
            return _id = noReadColl.insert({ filename: 'writefile', contentType: 'text/plain' }, function(err, _id) {
                if (err) { test.fail(err); }
                const url = Meteor.absoluteUrl('noread/' + _id);
                return HTTP.put(url, { content: '0123456789abcdef'}, function(err, res) {
                    test.isNotNull(err);
                    if (err.response != null) {  // Not sure why, but under phantomjs the error object is different
                        test.equal(err.response.statusCode, 413);
                    } else {
                        console.warn("PhantomJS skipped statusCode check");
                    }
                    return onComplete();
                });
            });
        })
    );

    Tinytest.addAsync('Client basic localUpdate test', function(test, onComplete) {
        const id = testColl.insert();
        test.equal((typeof testColl.localUpdate), 'function');
        testColl.localUpdate({ _id: id }, { $set: { 'metadata.test': true } });
        const doc = testColl.findOne({ _id: id });
        test.equal(doc.metadata.test, true);
        return onComplete();
    });

    Tinytest.addAsync('Client localUpdate server method rejection test', function(test, onComplete) {
        const id = testColl.insert();
        return Meteor.call('updateTest', id, true, function(err, res) {
            test.instanceOf(err, Meteor.Error);
            let doc = testColl.findOne({ _id: id });
            test.isUndefined(doc.metadata.test2);
            test.isUndefined(res);
            return Meteor.call('updateTest', id, false, function(err, res) {
                if (err) { test.fail(err); }
                test.equal(res, 1);
                doc = testColl.findOne({ _id: id });
                test.equal(doc.metadata.test2, false);
                return onComplete();
            });
        });
    });

    // Resumable.js tests

    Tinytest.add('Client has Resumable', test => test.instanceOf(testColl.resumable, Resumable, "Resumable object not found"));

    Tinytest.addAsync('Client resumable.js Upload', function(test, onComplete) {
        let thisId = null;

        testColl.resumable.on('fileAdded', file => testColl.insert({ _id: file.uniqueIdentifier, filename: file.fileName, contentType: file.file.type }, function(err, _id) {
            if (err) { test.fail(err); }
            thisId = `${_id._str}`;
            return testColl.resumable.upload();
        }));

        testColl.resumable.on('fileSuccess', function(file) {
            test.equal(thisId, file.uniqueIdentifier);
            const url = Meteor.absoluteUrl('test/' + file.uniqueIdentifier);
            return HTTP.get(url, function(err, res) {
                if (err) { test.fail(err); }
                test.equal(res.content,'ABCDEFGHIJ');
                return HTTP.del(url, function(err, res) {
                    if (err) { test.fail(err); }
                    testColl.resumable.events = [];
                    return onComplete();
                });
            });
        });

        testColl.resumable.on('error', (msg, err) => test.fail(err));

        const myBlob = new Blob([ 'ABCDEFGHIJ' ], { type: 'text/plain' });
        myBlob.name = 'resumablefile';
        return testColl.resumable.addFile(myBlob);
    });

    Tinytest.addAsync('Client resumable.js Upload, Multichunk', function(test, onComplete) {
        let thisId = null;

        testColl.resumable.on('fileAdded', file => testColl.insert({ _id: file.uniqueIdentifier, filename: file.fileName, contentType: file.file.type }, function(err, _id) {
            if (err) { test.fail(err); }
            thisId = `${_id._str}`;
            return testColl.resumable.upload();
        }));

        testColl.resumable.on('fileSuccess', function(file) {
            test.equal(thisId, file.uniqueIdentifier);
            const url = Meteor.absoluteUrl('test/' + file.uniqueIdentifier);
            return HTTP.get(url, function(err, res) {
                if (err) { test.fail(err); }
                test.equal(res.content,'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789');
                return HTTP.del(url, function(err, res) {
                    if (err) { test.fail(err); }
                    testColl.resumable.events = [];
                    return onComplete();
                });
            });
        });

        testColl.resumable.on('error', (msg, err) => test.fail(err));

        const myBlob = new Blob([ 'ABCDEFGHIJ', 'KLMNOPQRSTUVWXYZ', '0123456789' ], { type: 'text/plain' });
        myBlob.name = 'resumablefile';
        return testColl.resumable.addFile(myBlob);
    });
}
