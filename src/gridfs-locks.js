/***********************************************************************
 Copyright (C) 2014-2015 by Vaughn Iverson
 gridfs-locks is free software released under the MIT/X11 license.
 See included LICENSE file for details.
 ************************************************************************/

var eventEmitter = require('events').EventEmitter;

var never = 8000000000000000;  // never + now = 20000 years shy of max Date(), about 250,000 years from now

var isMongo26 = function (db, callback) {
    db.command({buildInfo: 1}, function (err, res) {
        if (err) {
            return callback(err);
        }
        if (res && res.versionArray) {
            retval = ((res.versionArray[0] == 2 && res.versionArray[1] >= 6) || res.versionArray[0] >= 3);
            return callback(null, retval);
        } else {
            return callback(new Error("MongoDB buildInfo returned invalid information"));
        }
    });
};

var isMongoDriver20 = function (db) {
    // This is probably not the best test, but officially I'm not sure
    // how to distinguish which driver is being used.
    if (db.hasOwnProperty('s')) {
        return true;
    } else {
        return false;
    }
};

//
// Parameters:
//
// db:   a valid mongodb connection object  Mandatory
// options object:
//    root:             the string of the root mongodb collection name  Default: 'fs'
//    w:                mongo writeconcern  Default: 1
//    pollingInterval:  Seconds between successive attempts to acquire a lock while waiting  Default: 5 sec
//    lockExpiration:   Seconds until an unrenewed lock expires in the database  Default: Never
//    timeOut:          Seconds to poll when obtaining a lock that is not available.  Default: Do not poll
//    metaData:         side information to store in the lock documents, useful for debugging  Default: null
//
/*
var __LockCollection = exports.LockCollection = function (db, options) {
    console.log('LockCollectin constructor');
    var self = this;
    if (!(self instanceof LockCollection)) {
        return new LockCollection(db, options);
    }

    eventEmitter.call(self);  // We are an eventEmitter

    if (!db || typeof db.collection !== 'function') {
        return emitError(self, "LockCollection 'db' parameter must be a valid Mongodb connection object.");
    }

    if (options && typeof options !== 'object') {
        return emitError(self, "LockCollection 'options' parameter must be an object.");
    }

    options = options || {};

    if (options.root && (typeof options.root !== 'string')) {
        return emitError(self, "LockCollection 'options.root' must be a string or falsy.");
    }

    options.root = options.root || 'fs';
    const collectionName = options.root + '.locks';

    isMongo26(db, function (err, is26) {
        console.log('isMongo26');
        if (err) {
            return emitError(self, err);
        }

        self._isMongo26 = is26;
        //self._isMongoDriver20 = isMongoDriver20(db);

        //db.collection(collectionName, function (err, collection) {
        const collection = db.collection(collectionName);
        collection.createIndex([['files_id', 1]], {unique: true});
        //There are no .then() or callbacks on 'createIndex' anymore.
        //TODO: try/catch the error, although it didn't do much in the og code anyway

        //TODO: This does not seem to be a proper collection object, maybe it is a promise?
        console.log('watis findandmodiffyyyy??');
        console.log(typeof collection.findAndModify);
        console.log(typeof collection.findOneAndUpdate);
        self.collection = collection;

        console.log('isMongo26 must have created indexes');
        self.emit('ready');
        console.log('mongo26 after createindex');
    });


    self.writeConcern = options.w == null ? 1 : options.w;
    self.timeOut = options.timeOut || 0;                  // Locks do not poll by default
    self.pollingInterval = options.pollingInterval || 5;  // 5 secs
    self.lockExpiration = options.lockExpiration || 0;    // Never
    self.metaData = options.metaData || null;             // None

    return self;
};
*/

//LockCollection.prototype = eventEmitter.prototype;

// Create a new Lock object
//
// Parameters:
//
// fileId:         Unique identifier of the resource being locked  Mandatory
// lockCollection: Valid LockCollection object
// options:
//          timeOut: Seconds to poll when obtaining a lock that is not available.  Default: 600
//          lockExpiration: Seconds until an unrenewed lock expires in the database  Default: Never
//          pollingInterval: Seconds between successive attempts to acquire a lock while waiting  Default: 5
//          metaData: side information to store in the lock document, useful for debugging  Default: null
//
var __Lock = exports.Lock = function (fileId, lockCollection, options) {

    if (!(this instanceof Lock)) return new Lock(fileId, lockCollection, options);

    var self = this;

    if (options && typeof options !== 'object') {
        return emitError(self, "Lock 'options' parameter must be an object.");
    }

    if (!(lockCollection instanceof LockCollection)) {
        return emitError(self, "Lock invalid 'lockCollection' object.");
    }

    if (!lockCollection.collection) {
        return emitError(self, "Lock 'lockCollection' must be 'ready'.");
    }

    options = options || {};
    self.lockCollection = lockCollection;
    self.collection = lockCollection.collection;
    self.fileId = fileId;
    self.timeCreated = new Date();
    self.pollingInterval = 1000 * (options.pollingInterval || self.lockCollection.pollingInterval);
    self.lockExpiration = 1000 * (options.lockExpiration || self.lockCollection.lockExpiration);

    // This ensures that locks don't emit expirations immediately
    if (self.lockExpiration && self.lockExpiration < self.pollingInterval * 1.1) {
        self.lockExpiration = self.pollingInterval * 1.1
    }

    self.lockExpireTime = new Date(self.timeCreated.getTime() + (self.lockExpiration || never));
    self.timeOut = 1000 * (options.timeOut || self.lockCollection.timeOut);
    self.metaData = options.metaData || self.lockCollection.metaData;
    self.lockType = null;
    self.query = null;
    self.update = null;
    self.heldLock = null;
    self.expired = false;

    return self;
};

//Lock.prototype = eventEmitter.prototype;

// Remove a currently held write lock.
//
// Parameters:
//
// Emits:
//    'removed':
//         null: The lock document has been removed
//    'error':
//         err: Any error that occurs
//
/*
Lock.prototype.removeLock = function () {

    var self = this;
    var query = {files_id: self.fileId, write_lock: true};

    if (!(self.heldLock) || self.expired) {
        return emitError(self, "Lock.removeLock cannot release an unheld lock.");
    }

    // self.timeCreated = new Date();
    if (self.lockType === 'r') {
        return emitError(self, "Lock.removeLock cannot remove a readLock.");
    } else if (self.lockType[0] === 'w') {

        clearTimeout(self.expiresSoonTimeout);
        clearTimeout(self.expiredTimeout);

        self.collection.findAndRemove(query, [], {w: self.lockCollection.writeConcern}, function (err, doc) {
            if (err) {
                return emitError(self, err);
            }
            if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                doc = doc.value;
            }
            self.lockType = null;
            self.query = null;
            self.update = null;
            self.heldLock = null;
            if (doc == null) {
                return emitError(self, "Lock.removeLock Lock document not found in collection.");
            }
            doc.expires = new Date(never);
            doc.write_lock = false
            self.emit('removed', doc);
        });
    } else {
        return emitError(self, "Lock.removeLock invalid lockType.");
    }

    return self;  // allow chaining
};
*/

// Release a currently held lock.
//
// Parameters:
//
// Emits:
//    'released':
//         doc: The new unheld lock document in the database
//    'error':
//         err: Any error that occurs
//
/*
Lock.prototype.releaseLock = function () {

    var self = this;

    if (self.lockCollection._isMongo26) {  // Begin Mongo 2.6 support

        var query = null,
            update = null;

        if (!(self.heldLock) || self.expired) {
            return emitError(self, "Lock.releaseLock cannot release an unheld lock.");
        }

        clearTimeout(self.expiresSoonTimeout);
        clearTimeout(self.expiredTimeout);

        // self.timeCreated = new Date();
        if (self.lockType === 'r') {

            query = {files_id: self.fileId, read_locks: {$gt: 0}},
                update = {$inc: {read_locks: -1}, $set: {meta: null}};

        } else if (self.lockType[0] === 'w') {

            query = {files_id: self.fileId, write_lock: true},
                update = {$set: {write_lock: false, write_req: false, meta: null}, $currentDate: {expires: true}};

        } else {
            return emitError(self, "Lock.releaseLock invalid lockType.");
        }

        self.collection.findAndModify(
            query,
            [],
            update,
            {w: self.lockCollection.writeConcern, new: true},
            function (err, doc) {

                if (err) {
                    return emitError(self, err);
                }
                if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                    doc = doc.value;
                }

                var lt = self.lockType;
                self.lockType = null;
                self.query = null;
                self.update = null;
                self.heldLock = null;
                if (doc == null) {
                    console.log('about to chuck missing lock error, here is the query');
                    console.dir(query);
                    return emitError(
                        self,
                        `Lock.releaseLock Lock document not found in collection.`);
                }

                // This resets the expire time when there are no locks and this was a release of a read lock
                // This prevents a former long expire time from persisting into new read locks unnecessarily.
                // There is a small time window between the findAndModify above and the one below where a long expire time
                // may be inheritied by a new read lock, but the window should be short enough that this is tolerable
                // because the lock->unlock->lock order of operations could have easily have been lock->lock->unlock
                if ((lt === 'r') && doc && (doc.read_locks == 0)) {
                    query = {files_id: self.fileId, read_locks: 0, write_lock: false};
                    update = {$currentDate: {expires: true}};
                    self.collection.findAndModify(query, [], update, {
                        w: self.lockCollection.writeConcern,
                        new: true
                    }, function (err, doc) {
                        if (err) {
                            console.warn("Error returned from expiration time reset on release", err);
                        }
                        if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                            doc = doc.value;
                        }
                    });
                }
                self.emit('released', doc);
            });

    } else {  // Mongo 2.4 legacy support
        releaseLock_24.bind(self)();
    }

    return self;  // allow chaining
};
*/

// Prevent expiration of a held lock for another lockExpiration seconds
//
// This method is useful to keep alive the locks of longer running operations, permitting the default
// lockExpiration on a LockCollection to be relatively short so that dead locks may be eliminated.
//
// Parameters:  None
//
// Emits:
//    'renewed':
//         doc: The new lock document in the database
//    'error':
//         err: Any error that occurs
//
/*
Lock.prototype.renewLock = function () {
    var self = this;

    if (self.lockCollection._isMongo26) {  // Begin Mongo 2.6 support

        if (!(self.heldLock)) {
            setImmediate(function () {
                self.emit('renewed', null);
            });
            return self
        }

        clearTimeout(self.expiresSoonTimeout);
        clearTimeout(self.expiredTimeout);

        self.lockExpireTime = new Date(new Date().getTime() + (self.lockExpiration || never));

        self.collection.findAndModify({files_id: self.fileId},
            [],
            {$max: {expires: self.lockExpireTime}},  // don't clobber an already extended shared read lock
            {w: self.lockCollection.writeConcern, new: true},
            function (err, doc) {
                if (err) {
                    return emitError(self, err);
                }
                if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                    doc = doc.value;
                }
                if (doc == null) {
                    return setImmediate(function () {
                        self.emit('renewed', null);
                    });
                }
                self.heldLock = doc;
                self.expiresSoonTimeout = setTimeout(emitExpiresSoonEvent.bind(self, ''), 0.9 * (self.lockExpireTime - new Date() - self.pollingInterval));
                self.expiredTimeout = setTimeout(emitExpiredEvent.bind(self, ''), (self.lockExpireTime - new Date() - self.pollingInterval));
                return self.emit('renewed', doc);
            });

    } else {  // Mongo 2.4 legacy support
        renewLock_24.bind(self)();
    }

    return self;
};
*/

// Attempt to obtain a read (non-exclusive) lock on a resource
//
// obtainReadLock will poll MongoDB for an unavailable lock every pollingInterval seconds until
// it succeeds or times out after timeOut seconds of polling. Read locks may be obtained when there
// is no write_lock being held and when there are no active write_req. Any number of read locks
// for a resource may be held simultaneously.
//
// Emits:
//    'locked':
//          doc: The obtained lock document in the database
//    'timed-out':
//          null
//    'expires-soon':
//          null - This lock has exhausted 90% of its lifetime and will soon expire
//    'expired':
//          null - This lock is no longer valid due to expiration
//    'error':
//          err: Any error that occurs
//
/*
Lock.prototype.obtainReadLock = function () {
    var self = this;

    if (self.lockCollection._isMongo26) {  // Begin Mongo 2.6 support
        self.timeCreated = new Date();
        if (self.heldLock) {
            return emitError(self, "Lock.obtainReadLock cannot obtain an already held lock.");
        }
        // Ensure that lock document for files_id exists
        self.timeCreated = new Date();
        self.lockType = 'r';
        self.expired = false;
        timeoutReadLockQuery(self);

    } else {  // Begin Mongo 2.4 legacy support
        obtainReadLock_24.bind(self)();
    }
    return self;
};
*/

// Attempt to obtain a write (exclusive) lock on a resource
//
// obtainWriteLock will poll MongoDB for an unavailable lock every pollingInterval seconds until
// it succeeds or times out after timeOut seconds of polling. A write lock may be obtained when
// there are no read or write locks currently held on a resource. Write locks have priority in that
// a polling request for a write lock will block new read locks from being granted via the write_req
// field in the lock document. Only one write lock for a resource may be held at a time.
//
// Parameters:
//
// testingOptions: Unit Testing options:
//    testCallback: optional, used by Unit testing to have a hook after the write request is written
//       no params
//    testWriteReq: optional, if true, supresses the clearing of the write_req lock when a write lock request times out
//
// Emits:
//    'locked':
//          doc: The obtained lock document in the database
//    'timed-out':
//          null - No parameters in callback
//    'expires-soon':
//          null - This lock has exhausted 90% of its lifetime and will soon expire
//    'expired':
//          null - This lock is no longer valid due to expiration
//    'error':
//          err: Any error that occurs
//
/*
/!**!/Lock.prototype.obtainWriteLock = function (testingOptions) {
    var self = this;

    if (self.lockCollection._isMongo26) {  // Begin Mongo 2.6 support

        if (self.heldLock) {
            return emitError(self, "Lock.obtainWriteLock cannot obtain an already held lock.");
        }
        testingOptions = testingOptions || {};
        // Ensure that lock document for files_id exists
        self.timeCreated = new Date();
        self.lockType = 'w';
        self.expired = false;
        timeoutWriteLockQuery(self, testingOptions);

    } else {
        obtainWriteLock_24.bind(self)(testingOptions);
    }

    return self;
};
*/

// Private function to help with properly emitting errors

var emitError = function (self, err) {
    if (typeof err == 'string') err = new Error(err);
    setImmediate(function () {
        self.emit('error', err);
    });
    return self;
}

// Private functions that implement expiration events

var emitExpiredEvent = function () {
    var self = this;
    var heldLock = self.heldLock;
    self.heldLock = null;
    self.expired = true
    self.emit('expired', heldLock);
}

var emitExpiresSoonEvent = function () {
    var self = this;
    self.emit('expires-soon', self.heldLock);
}

// Private function that implements polling for locks in the database

var timeoutReadLockQuery = function (self, options) {

    options = options || {};

    // Read locks can break write locks with write_req after more than one polling cycle
    now = new Date();
    self.lockExpireTime = new Date(now.getTime() + (self.lockExpiration || never));

    self.query = {
        files_id: self.fileId,
        $or: [
            {
                write_lock: false,
                write_req: false
            },
            {expires: {$lt: new Date(now - 2 * self.pollingInterval)}}
        ]
    };

    self.update = {
        $inc: {
            read_locks: 1,
            reads: 1
        },
        $set: {
            write_lock: false,
            write_req: false,
            meta: self.metaData
        },
        $max: {expires: self.lockExpireTime},
        $setOnInsert: {
            files_id: self.fileId,
            writes: 0
        }
    };


    //self.collection.findAndModify(
    //This will need wrapasync as the callback wont exist anymore
    self.collection.findOneAndUpdate(
        self.query,
       // [],
        self.update,
        {w: self.lockCollection.writeConcern, new: true, upsert: true},
        function (err, doc) {
            if (err && ((err.name !== 'MongoError') || (err.code !== 11000))) {
                return emitError(self, err);
            }
            if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                doc = doc.value;
            }
            if (!doc) {
                if (new Date().getTime() - self.timeCreated >= self.timeOut) {
                    return self.emit('timed-out');
                }
                return setTimeout(timeoutReadLockQuery, self.pollingInterval, self, options);
            } else {
                self.heldLock = doc;
                if (self.lockExpiration) {
                    self.expiresSoonTimeout = setTimeout(emitExpiresSoonEvent.bind(self),
                        0.9 * (self.lockExpireTime - new Date().getTime() - self.pollingInterval));
                    self.expiredTimeout = setTimeout(emitExpiredEvent.bind(self),
                        (self.lockExpireTime - new Date().getTime() - self.pollingInterval));
                }
                return self.emit('locked', doc);
            }
        }
    );
};

// Private function that implements polling for locks in the database

var timeoutWriteLockQuery = function (self, options) {

    options = options || {};

    now = new Date();
    self.lockExpireTime = new Date(now.getTime() + (self.lockExpiration || never));

    self.query = {
        files_id: self.fileId,
        $or: [
            {
                expires: {$lt: now},
                write_req: true
            },
            {
                write_lock: false,
                read_locks: 0
            }
        ]
    };

    self.update = {
        $set: {
            write_lock: true,
            write_req: false,
            read_locks: 0,
            expires: self.lockExpireTime,
            meta: self.metaData
        },
        $inc: {writes: 1},
        $setOnInsert: {
            files_id: self.fileId,
            reads: 0
        }
    };

    self.collection.findAndModify(self.query,
        [],
        self.update,
        {w: self.lockCollection.writeConcern, new: true, upsert: true},
        function (err, doc) {
            if (err && ((err.name !== 'MongoError') || (err.code !== 11000))) {
                return emitError(self, err);
            }
            if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                doc = doc.value;
            }
            if (doc) {
                self.heldLock = doc;
                if (self.lockExpiration) {
                    self.expiresSoonTimeout = setTimeout(emitExpiresSoonEvent.bind(self),
                        0.9 * (self.lockExpireTime - new Date().getTime() - self.pollingInterval));
                    self.expiredTimeout = setTimeout(emitExpiredEvent.bind(self),
                        (self.lockExpireTime - new Date().getTime() - self.pollingInterval));
                }
                return self.emit('locked', doc);

            } else {  // !doc
                if (new Date().getTime() - self.timeCreated >= self.timeOut) {
                    // Clear the write_req flag, since this obtainWriteLock has timed out
                    self.collection.findAndModify({files_id: self.fileId, write_req: true},
                        [],
                        {$set: {write_req: false}},
                        {w: self.lockCollection.writeConcern, new: true},
                        function (err, doc) {
                            if (err) {
                                return emitError(self, err);
                            }
                            if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                                doc = doc.value;
                            }
                        }
                    );
                    return self.emit('timed-out');
                } else {
                    // write_req gets set every time because claimed/released write locks and timed out write requests clear it
                    self.collection.findAndModify({files_id: self.fileId, write_req: false},
                        [],
                        {$set: {write_req: true}},
                        {new: true},
                        function (err, doc) {
                            if (err) {
                                return emitError(self, err);
                            }
                            if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                                doc = doc.value;
                            }
                            self.emit('write-req-set');
                        });
                    return setTimeout(timeoutWriteLockQuery, self.pollingInterval, self, options);
                }
            }
        }
    );
};

////////////////////////////////////////////////////////////
// MongoDB 2.4 helper functions
// Private functions that mirror the MongoDB 2.6 functions
// above, but using MongoDB 2.4 compatible queries.

var initializeLockDoc_24 = function (self, callback) {
    self.collection.findAndModify({files_id: self.fileId},
        [],
        {
            $setOnInsert: {
                files_id: self.fileId,
                expires: self.timeCreated,
                read_locks: 0,
                write_lock: false,
                write_req: false,
                reads: 0,
                writes: 0,
                meta: null
            }
        },
        {w: self.lockCollection.writeConcern, upsert: true, new: true},
        callback);
};

var releaseLock_24 = function () {
    var self = this;

    if (!(self.heldLock) || self.expired) {
        return emitError(self, "Lock.releaseLock cannot release an unheld lock.");
    }

    clearTimeout(self.expiresSoonTimeout);
    clearTimeout(self.expiredTimeout);

    if (self.lockType === 'r') {
        var query = {files_id: self.fileId, read_locks: {$gt: 1}},
            update = {$inc: {read_locks: -1}, $set: {meta: null}};

        // Case for read_locks > 1
        self.collection.findAndModify(query, [], update, {
            w: self.lockCollection.writeConcern,
            new: true
        }, function (err, doc) {
            if (err) {
                return emitError(self, err);
            }
            if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                doc = doc.value;
            }
            if (doc) {
                self.lockType = null;
                self.query = null;
                self.update = null;
                self.heldLock = null;
                return self.emit('released', doc);

            } else {

                query = {files_id: self.fileId, read_locks: 1};
                update = {$set: {read_locks: 0, expires: new Date(), meta: null}};

                // Case for read_locks == 1
                self.collection.findAndModify(query, [], update, {
                    w: self.lockCollection.writeConcern,
                    new: true
                }, function (err, doc) {
                    if (err) {
                        return emitError(self, err);
                    }
                    if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                        doc = doc.value;
                    }
                    if (doc) {
                        self.lockType = null;
                        self.query = null;
                        self.update = null;
                        self.heldLock = null;
                        return self.emit('released', doc);
                    } else {
                        // If another readLock released between the above two findAndModify calls they can both fail... so keep trying.
                        // Avoid an infinite loop when lock document no longer exists
                        self.collection.findOne({files_id: self.fileId, read_locks: {$gt: 0}}, function (err, doc) {
                            if (err) {
                                return emitError(self, err);
                            }
                            if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                                doc = doc.value;
                            }
                            if (doc == null) {
                                return emitError(self, "Lock.releaseLock Valid read Lock document not found in collection. " + JSON.stringify(self.heldLock));
                            } else {
                                self.releaseLock();
                            }
                        });
                    }
                });
            }
        });

    } else if (self.lockType[0] === 'w') {

        var query = {files_id: self.fileId, write_lock: true},
            update = {$set: {write_lock: false, write_req: false, expires: new Date(), meta: null}};

        self.collection.findAndModify(query, [], update, {
            w: self.lockCollection.writeConcern,
            new: true
        }, function (err, doc) {
            if (err) {
                return emitError(self, err);
            }
            if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                doc = doc.value;
            }
            self.lockType = null;
            self.query = null;
            self.update = null;
            self.heldLock = null;
            if (doc == null) {
                return emitError(self, "Lock.releaseLock Lock document not found in collection.");
            }
            self.emit('released', doc);
        });

    } else {
        return emitError(self, "Lock.releaseLock invalid lockType.");
    }
};

var renewLock_24 = function () {
    var self = this;
    if (!(self.heldLock)) {
        setImmediate(function () {
            self.emit('renewed', null);
        });
        return self
    }

    clearTimeout(self.expiresSoonTimeout);
    clearTimeout(self.expiredTimeout);

    self.lockExpireTime = new Date(new Date().getTime() + (self.lockExpiration || never));

    self.collection.findAndModify({files_id: self.fileId, expires: {$lt: self.lockExpireTime}},
        [],
        {$set: {expires: self.lockExpireTime}},
        {w: self.lockCollection.writeConcern, new: true},
        function (err, doc) {
            if (err) {
                return emitError(self, err);
            }
            if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                doc = doc.value;
            }
            if (doc == null) {
                self.collection.findOne({files_id: self.fileId}, function (err, doc) {
                    if (err) {
                        return emitError(self, err);
                    }
                    if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                        doc = doc.value;
                    }
                    if (doc == null) {
                        return setImmediate(function () {
                            self.emit('renewed', null);
                        });
                    }
                    self.heldLock = doc;
                    self.expiresSoonTimeout = setTimeout(emitExpiresSoonEvent.bind(self, ''), 0.9 * (self.lockExpireTime - new Date() - self.pollingInterval));
                    self.expiredTimeout = setTimeout(emitExpiredEvent.bind(self, ''), (self.lockExpireTime - new Date() - self.pollingInterval));
                    return self.emit('renewed', doc);
                });
            } else {
                self.heldLock = doc;
                self.expiresSoonTimeout = setTimeout(emitExpiresSoonEvent.bind(self, ''), 0.9 * (self.lockExpireTime - new Date() - self.pollingInterval));
                self.expiredTimeout = setTimeout(emitExpiredEvent.bind(self, ''), (self.lockExpireTime - new Date() - self.pollingInterval));
                return self.emit('renewed', doc);
            }
        });
    return self;
};

var obtainReadLock_24 = function () {
    var self = this;
    self.timeCreated = new Date();
    if (self.heldLock) {
        return emitError(self, "Lock.obtainReadLock cannot obtain an already held lock.");
    }
    // Ensure that lock document for files_id exists
    self.timeCreated = new Date();
    initializeLockDoc_24(self, function (err, doc) {
        if (err) {
            return emitError(self, err);
        }
        if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
            doc = doc.value;
        }
        self.lockType = 'r';
        self.expired = false;
        timeoutReadLockQuery_24(self);
    });
    return self;
};

var obtainWriteLock_24 = function (testingOptions) {
    var self = this;
    if (self.heldLock) {
        return emitError(self, "Lock.obtainWriteLock cannot obtain an already held lock.");
    }
    testingOptions = testingOptions || {};
    // Ensure that lock document for files_id exists
    self.timeCreated = new Date();
    initializeLockDoc_24(self, function (err, doc) {
        if (err) {
            return emitError(self, err);
        }
        if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
            doc = doc.value;
        }
        self.expired = false;
        self.lockType = 'w';
        timeoutWriteLockQuery_24(self, testingOptions);
    });
    return self;
};

// Private function that implements polling for locks in the database

var timeoutReadLockQuery_24 = function (self, options) {

    function gotLock(doc) {
        self.heldLock = doc;
        if (self.lockExpiration) {
            self.expiresSoonTimeout = setTimeout(emitExpiresSoonEvent.bind(self),
                0.9 * (self.lockExpireTime - new Date().getTime() - self.pollingInterval));
            self.expiredTimeout = setTimeout(emitExpiredEvent.bind(self),
                (self.lockExpireTime - new Date().getTime() - self.pollingInterval));
        }
        return self.emit('locked', doc);
    };

    options = options || {};

    // Read locks can break write locks with write_req after more than one polling cycle
    self.lockExpireTime = new Date(new Date().getTime() + (self.lockExpiration || never));
    self.query = {
        files_id: self.fileId,
        $or: [{write_lock: false, write_req: false, read_locks: 0},
            {write_lock: false, write_req: false, expires: {$lte: self.lockExpireTime}},
            {expires: {$lt: new Date(new Date() - 2 * self.pollingInterval)}}]
    };
    self.update = {
        $inc: {read_locks: 1, reads: 1},
        $set: {write_lock: false, write_req: false, expires: self.lockExpireTime, meta: self.metaData}
    };

    self.collection.findAndModify(self.query,
        [],
        self.update,
        {w: self.lockCollection.writeConcern, new: true},
        function (err, doc) {
            if (err) {
                return emitError(self, err);
            }
            if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                doc = doc.value;
            }
            if (!doc) {
                // Try again without trying to update the expire time
                self.lockExpireTime = new Date(new Date().getTime() + (self.lockExpiration || never));
                self.query = {
                    files_id: self.fileId,
                    write_lock: false,
                    write_req: false,
                    expires: {$gt: self.lockExpireTime}
                };
                self.update = {$inc: {read_locks: 1, reads: 1}, $set: {meta: self.metaData}};

                self.collection.findAndModify(self.query,
                    [],
                    self.update,
                    {w: self.lockCollection.writeConcern, new: true},
                    function (err, doc) {
                        if (err) {
                            return emitError(self, err);
                        }
                        if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                            doc = doc.value;
                        }
                        if (!doc) {
                            if (new Date().getTime() - self.timeCreated >= self.timeOut) {
                                return self.emit('timed-out');
                            }
                            return setTimeout(timeoutReadLockQuery_24, self.pollingInterval, self, options);
                        } else {
                            return gotLock(doc);
                        }
                    }
                );
            } else {
                return gotLock(doc);
            }
        }
    );
};

// Private function that implements polling for locks in the database

var timeoutWriteLockQuery_24 = function (self, options) {
    options = options || {};

    self.query = {
        files_id: self.fileId,
        $or: [{expires: {$lt: new Date()}, write_req: true},
            {write_lock: false, read_locks: 0}]
    };
    self.lockExpireTime = new Date(new Date().getTime() + (self.lockExpiration || never));
    self.update = {
        $set: {
            write_lock: true,
            write_req: false,
            read_locks: 0,
            expires: self.lockExpireTime,
            meta: self.metaData
        }, $inc: {writes: 1}
    };

    self.collection.findAndModify(self.query,
        [],
        self.update,
        {w: self.lockCollection.writeConcern, new: true},
        function (err, doc) {
            if (err) {
                return emitError(self, err);
            }
            if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                doc = doc.value;
            }
            if (doc) {
                self.heldLock = doc;
                if (self.lockExpiration) {
                    self.expiresSoonTimeout = setTimeout(emitExpiresSoonEvent.bind(self),
                        0.9 * (self.lockExpireTime - new Date().getTime() - self.pollingInterval));
                    self.expiredTimeout = setTimeout(emitExpiredEvent.bind(self),
                        (self.lockExpireTime - new Date().getTime() - self.pollingInterval));
                }
                return self.emit('locked', doc);
            }
            if (new Date().getTime() - self.timeCreated >= self.timeOut) {
                // Clear the write_req flag, since this obtainWriteLock has timed out
                self.collection.findAndModify({files_id: self.fileId, write_req: true},
                    [],
                    {$set: {write_req: false}},
                    {w: self.lockCollection.writeConcern, new: true},
                    function (err, doc) {
                        if (err) {
                            return emitError(self, err);
                        }
                        if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                            doc = doc.value;
                        }
                    }
                );
                return self.emit('timed-out');
            } else {
                // write_req gets set every time because claimed/released write locks and timed out write requests clear it
                self.collection.findAndModify({files_id: self.fileId, write_req: false},
                    [],
                    {$set: {write_req: true}},
                    {new: true},
                    function (err, doc) {
                        if (err) {
                            return emitError(self, err);
                        }
                        if (self.lockCollection._isMongoDriver20 && doc && doc.hasOwnProperty('value')) {
                            doc = doc.value;
                        }
                        self.emit('write-req-set');
                    });
                return setTimeout(timeoutWriteLockQuery_24, self.pollingInterval, self, options);
            }
        }
    );
};
