/*
 * decaffeinate suggestions:
 * DS101: Remove unnecessary use of Array.from
 * DS102: Remove unnecessary code created because of implicit returns
 * DS205: Consider reworking code to avoid use of IIFEs
 * DS207: Consider shorter variations of null checks
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/main/docs/suggestions.md
 */
//###########################################################################
//     Copyright (C) 2014-2017 by Vaughn Iverson
//     fileCollection is free software released under the MIT/X11 license.
//     See included LICENSE file for details.
//###########################################################################
import {Meteor} from 'meteor/meteor'
import {Mongo} from 'meteor/mongo';

const mongodb = Npm.require('mongodb');
const grid = Npm.require('gridfs-locking-stream');
const gridLocks = Npm.require('gridfs-locks');
const fs = Npm.require('fs');
const path = Npm.require('path');
const dicer = Npm.require('dicer');
const express = Npm.require('express');

export class FileCollection extends Mongo.Collection {

    constructor(root, options) {
// For CoffeeScript v2 this (aka @) cannot be referenced before a call to super
        if (root == null) {
            root = share.defaultRoot;
        }
        if (options == null) {
            options = {};
        }
        if (Mongo.Collection !== Mongo.Collection.prototype.constructor) {
            throw new Meteor.Error('The global definition of Mongo.Collection has been patched by another package, and the prototype constructor has been left in an inconsistent state. Please see this link for a workaround: https://github.com/vsivsi/meteor-file-sample-app/issues/2#issuecomment-120780592');
        }

        if (typeof root === 'object') {
            options = root;
            root = share.defaultRoot;
        }

        // Call super's constructor
        super(root + '.files', {idGeneration: 'MONGO'});
        this.root = root;

        if (!(this instanceof FileCollection)) {
            return new FileCollection(this.root, options);
        }

        if (!(this instanceof Mongo.Collection)) {
            throw new Meteor.Error('The global definition of Mongo.Collection has changed since the file-collection package was loaded. Please ensure that any packages that redefine Mongo.Collection are loaded before file-collection.');
        }


        this.chunkSize = options.chunkSize != null ? options.chunkSize : share.defaultChunkSize;

        this.db = Meteor.wrapAsync(mongodb.MongoClient.connect)(process.env.MONGO_URL, {});

        this.lockOptions = {
            timeOut: (options.locks != null ? options.locks.timeOut : undefined) != null ? (options.locks != null ? options.locks.timeOut : undefined) : 360,
            lockExpiration: (options.locks != null ? options.locks.lockExpiration : undefined) != null ? (options.locks != null ? options.locks.lockExpiration : undefined) : 90,
            pollingInterval: (options.locks != null ? options.locks.pollingInterval : undefined) != null ? (options.locks != null ? options.locks.pollingInterval : undefined) : 5
        };

        this.locks = gridLocks.LockCollection(this.db, {
                root: this.root,
                timeOut: this.lockOptions.timeOut,
                lockExpiration: this.lockOptions.lockExpiration,
                pollingInterval: this.lockOptions.pollingInterval
            }
        );

        this.gfs = new grid(this.db, mongodb, this.root);

        this.baseURL = options.baseURL != null ? options.baseURL : `/gridfs/${this.root}`;

        // if there are HTTP options, setup the express HTTP access point(s)
        if (options.resumable || options.http) {
            share.setupHttpAccess.bind(this)(options);
        }

        // Default client allow/deny permissions
        this.allows = {read: [], insert: [], write: [], remove: []};
        this.denys = {read: [], insert: [], write: [], remove: []};

        // Default indexes
        if (options.resumable) {
            const indexOptions = {};
            if (typeof options.resumableIndexName === 'string') {
                indexOptions.name = options.resumableIndexName;
            }

            this.db.collection(`${this.root}.files`).ensureIndex({
                'metadata._Resumable.resumableIdentifier': 1,
                'metadata._Resumable.resumableChunkNumber': 1,
                length: 1
            }, indexOptions);
        }

        this.maxUploadSize = options.maxUploadSize != null ? options.maxUploadSize : -1; // Negative is no limit...

        //# Delay this feature until demand is clear. Unit tests / documentation needed.

        // unless options.additionalHTTPHeaders? and (typeof options.additionalHTTPHeaders is 'object')
        //    options.additionalHTTPHeaders = {}
        //
        // for h, v of options.additionalHTTPHeaders
        //    share.defaultResponseHeaders[h] = v

        // Setup specific allow/deny rules for gridFS, and tie-in the application settings
        // FileCollection.__super__ needs to be set up for CoffeeScript v2

        FileCollection.__super__ = Mongo.Collection.prototype;
        FileCollection.__super__.allow.bind(this)({
// Because allow rules are not guaranteed to run,
// all checking is done in the deny rules below
            insert: (userId, file) => true,
            remove: (userId, file) => true
        });

        FileCollection.__super__.deny.bind(this)({

            insert: (userId, file) => {

// Make darn sure we're creating a valid gridFS .files document
                check(file, {
                        _id: Mongo.ObjectID,
                        length: Match.Where(x => {
                            check(x, Match.Integer);
                            return x === 0;
                        }),
                        md5: Match.Where(x => {
                            check(x, String);
                            return x === 'd41d8cd98f00b204e9800998ecf8427e';
                        }), // The md5 of an empty file
                        uploadDate: Date,
                        chunkSize: Match.Where(x => {
                            check(x, Match.Integer);
                            return x === this.chunkSize;
                        }),
                        filename: String,
                        contentType: String,
                        aliases: [String],
                        metadata: Object
                    }
                );

                // Enforce a uniform chunkSize
                if (file.chunkSize !== this.chunkSize) {
                    console.warn("Invalid chunksize");
                    return true;
                }

                // call application rules
                if (share.check_allow_deny.bind(this)('insert', userId, file)) {
                    return false;
                }

                return true;
            },

            update: (userId, file, fields) => {
//# Cowboy updates are not currently allowed from the client. Too much to screw up.
//# For example, if you store file ownership info in a sub document under 'metadata'
//# it will be complicated to guard against that being changed if you allow other parts
//# of the metadata sub doc to be updated. Write specific Meteor methods instead to
//# allow reasonable changes to the "metadata" parts of the gridFS file record.
                return true;
            },

            remove: (userId, file) => {
//# Remove is now handled via the default method override below, so this should
//# never be called.
                return true;
            }
        });

        const self = this; // Necessary in the method definition below

        //# Remove method override for this server-side collection
        Meteor.server.method_handlers[`${this._prefix}remove`] = function (selector) {
            check(selector, Object);

            if (!LocalCollection._selectorIsIdPerhapsAsObject(selector)) {
                throw new Meteor.Error(403, "Not permitted. Untrusted code may only remove documents by ID.");
            }

            const cursor = self.find(selector);

            if (cursor.count() > 1) {
                throw new Meteor.Error(500, "Remote remove selector targets multiple files.\nSee https://github.com/vsivsi/meteor-file-collection/issues/152#issuecomment-278824127");
            }

            const [file] = Array.from(cursor.fetch());

            if (file) {
                if (share.check_allow_deny.bind(self)('remove', this.userId, file)) {
                    return self.remove(file);
                } else {
                    throw new Meteor.Error(403, "Access denied");
                }
            } else {
                return 0;
            }
        };
    }

// Register application allow rules
    allow(allowOptions) {
        return (() => {
            const result = [];
            for (let type in allowOptions) {
                const func = allowOptions[type];
                if (!(type in this.allows)) {
                    throw new Meteor.Error(`Unrecognized allow rule type '${type}'.`);
                }
                if (typeof func !== 'function') {
                    throw new Meteor.Error(`Allow rule ${type} must be a valid function.`);
                }
                result.push(this.allows[type].push(func));
            }
            return result;
        })();
    }

// Register application deny rules
    deny(denyOptions) {
        return (() => {
            const result = [];
            for (let type in denyOptions) {
                const func = denyOptions[type];
                if (!(type in this.denys)) {
                    throw new Meteor.Error(`Unrecognized deny rule type '${type}'.`);
                }
                if (typeof func !== 'function') {
                    throw new Meteor.Error(`Deny rule ${type} must be a valid function.`);
                }
                result.push(this.denys[type].push(func));
            }
            return result;
        })();
    }

    insert(file, callback) {
        if (file == null) {
            file = {};
        }
        if (callback == null) {
            callback = undefined;
        }
        file = share.insert_func(file, this.chunkSize);
        return super.insert(file, callback);
    }

// Update is dangerous! The checks inside attempt to keep you out of
// trouble with gridFS. Clients can't update at all. Be careful!
// Only metadata, filename, aliases and contentType should ever be changed
// directly by a server.

    update(selector, modifier, options, callback) {
        let err;

        if (callback == null && typeof options === 'function') callback = options;

        options = options || {};

        if (options.upsert != null) {
            err = new Meteor.Error("Update does not support the upsert option");
            if (callback != null && typeof callback === 'function') {
                callback(err);
                return callback(err);
            } else {
                throw err;
            }
        }

        if (share.reject_file_modifier(modifier) && !options.force) {
            err = new Meteor.Error("Modifying gridFS read-only document elements is a very bad idea!");
            if (callback != null) {
                return callback(err);
            } else {
                throw err;
            }
        } else {
            return super.update(selector, modifier, options, callback);
        }
    }

    upsert(selector, modifier, options, callback) {
        const err = new Meteor.Error("File Collections do not support 'upsert'");
        if (callback != null) {
            return callback(err);
        } else {
            throw err;
        }
    }

    upsertStream(file, options, callback) {
        let found;
        if (!options) {
            options = {};
        }
        if (callback == null) {
            callback = undefined;
        }
        if ((callback == null) && (typeof options === 'function')) {
            callback = options;
            options = {};
        }
        callback = share.bind_env(callback);
        const cbCalled = false;
        const mods = {};
        if (file.filename != null) {
            mods.filename = file.filename;
        }
        if (file.aliases != null) {
            mods.aliases = file.aliases;
        }
        if (file.contentType != null) {
            mods.contentType = file.contentType;
        }
        if (file.metadata != null) {
            mods.metadata = file.metadata;
        }

        if (options.autoRenewLock === null) {
            options.autoRenewLock = true;
        }

        if (options.mode === 'w+') {
            throw new Meteor.Error("The ability to append file data in upsertStream() was removed in version 1.0.0");
        }

        // Make sure that we have an ID and it's valid
        if (file._id) {
            found = this.findOne({_id: file._id});
        }

        if (!file._id || !found) {
            file._id = this.insert(mods);
        } else if (Object.keys(mods).length > 0) {
            this.update({_id: file._id}, {$set: mods});
        }

        const writeStream = Meteor.wrapAsync(this.gfs.createWriteStream.bind(this.gfs))({
            root: this.root,
            _id: mongodb.ObjectID(`${file._id._str}`),
            mode: 'w',
            timeOut: this.lockOptions.timeOut,
            lockExpiration: this.lockOptions.lockExpiration,
            pollingInterval: this.lockOptions.pollingInterval
        });

        if (writeStream) {

            if (options.autoRenewLock) {
                writeStream.on('expires-soon', () => {
                    return writeStream.renewLock(function (e, d) {
                        if (e || !d) {
                            return console.warn(`Automatic Write Lock Renewal Failed: ${file._id._str}`, e);
                        }
                    });
                });
            }

            if (callback != null) {
                writeStream.on('close', function (retFile) {
                    if (retFile) {
                        retFile._id = new Mongo.ObjectID(retFile._id.toHexString());
                        return callback(null, retFile);
                    }
                });
                writeStream.on('error', err => callback(err));
            }

            return writeStream;
        }

        return null;
    }

    findOneStream(selector, options, callback) {
        if (options == null) {
            options = {};
        }
        if (callback == null) {
            callback = undefined;
        }
        if ((callback == null) && (typeof options === 'function')) {
            callback = options;
            options = {};
        }

        callback = share.bind_env(callback);
        const opts = {};
        if (options.sort != null) {
            opts.sort = options.sort;
        }
        if (options.skip != null) {
            opts.skip = options.skip;
        }
        const file = this.findOne(selector, opts);

        if (file) {
            if (options.autoRenewLock == null) {
                options.autoRenewLock = true;
            }

            // Init the start and end range, default to full file or start/end as specified
            const range = {
                start: (options.range != null ? options.range.start : undefined) != null ? (options.range != null ? options.range.start : undefined) : 0,
                end: (options.range != null ? options.range.end : undefined) != null ? (options.range != null ? options.range.end : undefined) : file.length - 1
            };

            const readStream = Meteor.wrapAsync(this.gfs.createReadStream.bind(this.gfs))({
                root: this.root,
                _id: mongodb.ObjectID(`${file._id._str}`),
                timeOut: this.lockOptions.timeOut,
                lockExpiration: this.lockOptions.lockExpiration,
                pollingInterval: this.lockOptions.pollingInterval,
                range: {
                    startPos: range.start,
                    endPos: range.end
                }
            });

            if (readStream) {
                if (options.autoRenewLock) {
                    readStream.on('expires-soon', () => {
                        return readStream.renewLock(function (e, d) {
                            if (e || !d) {
                                return console.warn(`Automatic Read Lock Renewal Failed: ${file._id._str}`, e);
                            }
                        });
                    });
                }

                if (callback != null) {
                    readStream.on('close', () => callback(null, file));
                    readStream.on('error', err => callback(err));
                }
                return readStream;
            }
        }

        return null;
    }

    remove(selector, callback) {
        if (callback == null) {
            callback = undefined;
        }
        callback = share.bind_env(callback);
        if (selector != null) {
            let ret = 0;
            this.find(selector).forEach(file => {
                const res = Meteor.wrapAsync(this.gfs.remove.bind(this.gfs))({
                    _id: mongodb.ObjectID(`${file._id._str}`),
                    root: this.root,
                    timeOut: this.lockOptions.timeOut,
                    lockExpiration: this.lockOptions.lockExpiration,
                    pollingInterval: this.lockOptions.pollingInterval
                });
                return ret += res ? 1 : 0;
            });
            (callback != null) && callback(null, ret);
            return ret;
        } else {
            const err = new Meteor.Error("Remove with an empty selector is not supported");
            if (callback != null) {
                callback(err);
                return;
            } else {
                throw err;
            }
        }
    }

    importFile(filePath, file, callback) {
        callback = share.bind_env(callback);
        filePath = path.normalize(filePath);
        if (file == null) {
            file = {};
        }
        if (file.filename == null) {
            file.filename = path.basename(filePath);
        }
        const readStream = fs.createReadStream(filePath);
        readStream.on('error', share.bind_env(callback));
        const writeStream = this.upsertStream(file);
        return readStream.pipe(share.streamChunker(this.chunkSize)).pipe(writeStream)
            .on('close', share.bind_env(d => callback(null, d)))
            .on('error', share.bind_env(callback));
    }

    exportFile(selector, filePath, callback) {
        callback = share.bind_env(callback);
        filePath = path.normalize(filePath);
        const readStream = this.findOneStream(selector);
        const writeStream = fs.createWriteStream(filePath);
        return readStream.pipe(writeStream)
            .on('finish', share.bind_env(callback))
            .on('error', share.bind_env(callback));
    }
}

