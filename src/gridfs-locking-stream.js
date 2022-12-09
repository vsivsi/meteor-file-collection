/***************************************************************************
 ###  Copyright (C) 2014-2015 by Vaughn Iverson
 ###  gridfs-locking-stream is free software released under the MIT/X11 license.
 ###  See included LICENSE file for details.
 ***************************************************************************/

/**
 * Module dependencies.
 */

//var Lock = require('gridfs-locks').Lock;
import {Lock} from "./gridfs-locks";
//var LockCollection = require('gridfs-locks').LockCollection;
import {LockCollection} from "./gridfs-locks";

//var GridWriteStream = require('gridfs-stream/lib/writestream');
import {GridWriteStream} from "./writestream";
//var GridReadStream = require('gridfs-stream/lib/readstream');
import {GridReadStream} from "./readstream";

/**
 * Grid constructor
 *
 * @param {mongo.Db} db - an open mongo.Db instance
 * @param {mongo} [mongo] - the native driver you are using
 * @param {String} [root] - the root name of the GridFS collection to use
 */

export function Grid (db, mongo, root) {
    if (!(this instanceof Grid)) {
        return new Grid(db, mongo, root);
    }
    const self = this;

    if (!mongo) mongo = Grid.mongo ? Grid.mongo : undefined;

    if (!mongo) throw new Error('missing mongo argument\nnew Grid(db, mongo)');
    if (!db) throw new Error('missing db argument\nnew Grid(db, mongo)');

    // the db must already be open b/c there is no `open` event emitted
    // in old versions of the driver
    self.db = db;
    self.mongo = mongo;
    self.root = root || self.mongo.GridStore.DEFAULT_ROOT_COLLECTION;
}

/**
 * Creates a writable stream.
 *
 * @param {Object} [options]
 * @return Stream
 */

Grid.prototype.createLockCollection = function (options, callback) {
    const self = this;
    self.root = options.root;
    const lockColl = LockCollection(self.db, options).once('ready',
        function () {
            self._locks = lockColl;
            lockColl.removeAllListeners();
            callback(null);
        }
    ).once('error', function (err) {
        lockColl.removeAllListeners();
        return callback(err);
    });
};

/**
 * Creates a writable stream.
 *
 * @param {Object} [options]
 * @return Stream
 */

Grid.prototype.createWriteStream = function (options, callback) {
    const self = this;

    function lockAndWrite() {
        const lock = Lock(options._id, self._locks, options);
        lock.obtainWriteLock().on('locked',
            function (l) {
                const stream = new GridWriteStream(self, options);
                stream.releaseLock = function (callback) {
                    lock.releaseLock();
                    if (callback) {
                        lock.once('released', function (l) { lock.removeAllListeners(); callback(null, l); });
                        lock.once('error', function (e) { lock.removeAllListeners(); callback(e); });
                    }
                };
                stream.renewLock = function (callback) {
                    lock.renewLock();
                    if (callback) {
                        const errorCb = function (e) { lock.removeAllListeners(); callback(e); }
                        lock.once('renewed', function (l) {
                            lock.removeListener('error', errorCb);
                            callback(null, l);
                        });
                        lock.once('error', errorCb);
                    }
                };
                stream.heldLock = function () {
                    return lock.heldLock;
                };
                stream.lockReleased = function (callback) {
                    if (lock.heldLock) {
                        lock.once('released', function (ld) { callback(null, ld); });
                    } else {
                        setImmediate(function () { callback(null, null); });
                    }
                };
                stream.on('error', function (err) {
                    if (lock.heldLock) {
                        lock.releaseLock();
                    }
                }).on('close', function (file) {
                    if (lock.heldLock) {
                        lock.releaseLock();
                    } else {
                        console.warn(`Warning: gridfs-locking-stream Write Lock Expired for file!0!`);
                        console.dir(lock.fileId);
                    }
                });
                lock.removeAllListeners();
                lock.on('expires-soon', function () { stream.emit('expires-soon'); });
                lock.on('expired', function () { stream.destroy(); stream.emit('expired'); });
                callback(null, stream, l);
            }
        ).once('timed-out', function () {
                callback(null, null);
            }
        ).once('error', function (err) {
                callback(err);
            }
        );
    }

    if (!options._id) {
        // New file
        options._id = new self.mongo.ObjectID();
    }

    if (options.root && self.root !== options.root) {
        throw new Error('Root name of Grid object cannot be changed: ' + options.root + " !== " + self.root);
    }

    options.root = self.root;

        lockAndWrite();

};

/**
 * Creates a readable stream. Pass at least a filename or _id option
 *
 * @param {Object} options
 * @param {function} callback
 * @return Stream
 */

Grid.prototype.createReadStream = function (options, callback) {
    const self = this;

    function lockAndRead() {
        const lock = Lock(options._id, self._locks, options);
        lock.obtainReadLock().on('locked',
            function (l) {
                const stream = new GridReadStream(self, options);
                const tryReleaseLock = function () {
                    let releasePending = false;
                    return function () {
                        if (lock.heldLock && !releasePending) {
                            releasePending = true;
                            lock.releaseLock();
                        } else if (!lock.heldLock) {
                            console.warn('Warning: gridfs-locking-stream Read Lock Expired for file', lock.fileId);
                        }
                    };
                }();
                stream.releaseLock = function (callback) {
                    lock.releaseLock();
                    if (callback) {
                        lock.once('released', function (l) { lock.removeAllListeners(); callback(null, l); });
                        lock.once('error', function (e) { lock.removeAllListeners(); callback(e); });
                    }
                };
                stream.renewLock = function (callback) {
                    lock.renewLock();
                    if (callback) {
                        const errorCb = function (e) { lock.removeAllListeners(); callback(e); }
                        lock.once('renewed', function (l) {
                            lock.removeListener('error', errorCb);
                            callback(null, l);
                        });
                        lock.once('error', errorCb);
                    }
                };
                stream.heldLock = function () {
                    return lock.heldLock;
                };
                stream.lockReleased = function (callback) {
                    if (lock.heldLock) {
                        lock.once('released', function (ld) { callback(null, ld); });
                    } else {
                        setImmediate(function () { callback(null, null); });
                    }
                };
                stream.on('error', tryReleaseLock)
                    .on('close', tryReleaseLock)
                    .on('end', tryReleaseLock);
                lock.removeAllListeners();
                lock.on('expires-soon', function () { stream.emit('expires-soon'); });
                lock.on('expired', function () {
                    stream.destroy();
                    stream.emit('expired');
                });
                callback(null, stream, l);
            }).once('timed-out', function () {
                callback(null, null);
            }
        ).once('error', function (err) {
                callback(err);
            }
        );
    }

    if (!options._id) {
        throw new Error('No "_id" provided for GridFS file. Filenames are not unique.');
    }

    if (options.root && self.root !== options.root) {
        throw new Error('Root name of Grid object cannot be changed: ' + options.root + " !== " + self.root);
    }

    options.root = self.root;

};

/**
 * The collection used to store file data in mongodb.
 * @return {Collection}
 */

Object.defineProperty(Grid.prototype, 'files', {
    get: function () {
        const self = this;
        if (!self._col)
            self._col = self.db.collection(self.root + ".files");
        return self._col;
    }
});

/**
 * The collection used to store lock data in mongodb.
 * @return {Collection}
 */

// Add a property for the locks collection?  Probably.

Object.defineProperty(Grid.prototype, 'locks', {
    get: function () {
        var self = this;
        if (self._locks) {
            return self._locks.collection;
        } else {
            return self.db.collection(root + ".locks");
        }
    }
});

/**
 * Removes a file by passing any options with an _id
 *
 * @param {Object} options
 * @param {Function} callback
 */

Grid.prototype.remove = function (options, callback) {
    const self = this;

    if (!options._id) {
        throw new Error('No "_id" provided for GridFS file. Filenames are not unique.');
    }
    const _id = self.tryParseObjectId(options._id) || options._id;

    self.mongo.GridStore.unlink(self.db, _id, options, function (err) {
        if(err)return callback(err);
        callback(null, true);
    });
};

/**
 * Checks if a file exists by passing an _id
 *
 * @param {Object} options
 * @param {Function} callback
 */

Grid.prototype.exist = function (options, callback) {
    let _id;
    if (options._id) {
        _id = this.tryParseObjectId(options._id) || options._id;
    }
    return this.mongo.GridStore.exist(this.db, _id, callback);
};

/**
 * Attemps to parse `string` into an ObjectId
 *
 * @param {GridReadStream} self
 * @param {String|ObjectId} string
 * @return {ObjectId|Boolean}
 */

Grid.prototype.tryParseObjectId = function tryParseObjectId (string) {
    const self = this;
    try {
        return new self.mongo.ObjectID(string);
    } catch (_) {
        return false;
    }
};

/**
 * expose
 */

module.exports = exports = Grid;
