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
import {Mongo, MongoInternals} from 'meteor/mongo';

//const mongodb = Npm.require('mongodb');
const {MongoClient} = require("mongodb");

import grid from './gridfs-locking-stream';

const ObjectID = require("bson-objectid");

const fs = Npm.require('fs');
const path = Npm.require('path');

import crypto from "crypto";

//Keep track of the chunks received so the md5 generation can be fired ONLY when the file has completed uploading
const chunksReceived = {};

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

        this.bucket = new MongoInternals.NpmModule.GridFSBucket(
            MongoInternals.defaultRemoteCollectionDriver().mongo.db,
            {bucketName: this.root}
        );

        if (!(this instanceof FileCollection)) {
            return new FileCollection(this.root, options);
        }

        if (!(this instanceof Mongo.Collection)) {
            throw new Meteor.Error('The global definition of Mongo.Collection has changed since the file-collection package was loaded. Please ensure that any packages that redefine Mongo.Collection are loaded before file-collection.');
        }

        this.chunkSize = options.chunkSize != null ? options.chunkSize : share.defaultChunkSize;

        //this.db = Meteor.wrapAsync(mongodb.MongoClient.connect)(process.env.MONGO_URL, {});
        //const db = Meteor.wrapAsync(()=>mongodb.MongoClient.connect(process.env.MONGO_URL, {}));
        //process.env.MONGO_URL =  mongodb://127.0.0.1:27017/panda, we only need the first part before panda
        const client = new MongoClient(process.env.MONGO_URL);

        this.db = client.db('panda');//db;//Meteor.wrapAsync(mongodb.MongoClient.connect)(process.env.MONGO_URL, {});

        //DB, mongo driver dependency injection, root name of gridfs collection
        this.gfs = new grid(this.db, MongoClient, this.root);

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

            this.db.collection(`${this.root}.files`).createIndex({
                'metadata._Resumable.resumableIdentifier': 1,
                'metadata._Resumable.resumableChunkNumber': 1,
                length: 1
            }, indexOptions);
        }

        this.maxUploadSize = options.maxUploadSize != null ? options.maxUploadSize : -1; // Negative is no limit...


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
                    console.error('denied, chunksize incorrect');
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

        //Create a stub in the 'chunksReceived' so we can keep track of progress
        //TODO: only do this if resumable upload
        chunksReceived[file._id.toHexString()] = new Set();

        if (file == null) {
            file = {};
        }
        if (callback == null) {
            callback = undefined;
        }
        file = share.insert_func(file, this.chunkSize);
        const insert = super.insert(file, callback);
        return insert;
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
            const result = super.update(selector, modifier, options, callback);

            let sel = selector;
            if (sel.toHexString) sel = {_id: selector.toHexString()};

            return result;
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

    upsertStream(file, callback) {
        const self = this;
        const writeStream = this.bucket.openUploadStream( //https://mongodb.github.io/node-mongodb-native/4.12/classes/GridFSBucket.html#openUploadStream
            file.filename,//filename
            {//options https://mongodb.github.io/node-mongodb-native/4.12/interfaces/GridFSBucketWriteStreamOptions.html
                metadata: {contentType: file.contentType, ...file.metadata},
                contentType: file.contentType, //TODO: this will be deprecated
            }
        )

        if (writeStream) {
            //The finish event will occur on every chunk, we need to make sure it is the last one.
            //Trying to fire this from resumable_server.js just doesn't work.  I think only the raw db is available there.
            writeStream.on('finish', function (retFile) {
                if (retFile?.metadata._Resumable) { //todo: maybe still generate md5 for non-resumable somehow.
                    //This superfluous, as there is a proper complete callback in resumable_server,
                    //there does not seem to be easy access to this class there though, so

                    const chunkNumber = retFile.metadata._Resumable.resumableChunkNumber;
                    const totalChunks = retFile.metadata._Resumable.resumableTotalChunks;
                    const contentType = retFile.metadata._Resumable.resumableType;
                    const identifier = retFile.metadata._Resumable.resumableIdentifier;
                    const receivedChunks = chunksReceived[identifier];
                    receivedChunks.add(chunkNumber);
                    if (receivedChunks.size === totalChunks) {
                        delete chunksReceived[identifier];
                        const targetId = new Mongo.ObjectID(identifier);
                        //We have to generate the MD5 ourselves as this functionality was removed from mongo 6
                        let file = self.findOne({_id: targetId}); //TODO, see if this should be resumableIdentifier

                        //Todo: move these to shared ops
                        let retries = 100;
                        const retryDelay = 100;//ms
                        function md5WhenReady() {
                            file = self.findOne({_id: targetId}); //TODO, see if this should be resumableIdentifier
                            if (!file.length) {
                                retries--;
                                Meteor.setTimeout(() => {
                                    if (retries) md5WhenReady();
                                    else console.error(`Timeout waiting for upload to complete.  MD5 not generated for `)
                                }, retryDelay);
                            } else {
                                const stream = self.findOneStream({_id: file._id});
                                const getMd5 = Meteor.wrapAsync(callback => {
                                    const hash = crypto.createHash('md5'); //TODO: is options/encoding needed?
                                    stream.pipe(hash);
                                    hash.on('finish', () => callback(null, hash.digest('hex')));
                                });
                                const md5 = getMd5();

                                self.update(
                                    {_id: targetId}, //TODO: check type of ID
                                    {
                                        $set: {
                                            md5: md5, //TODO: this will eventually be deprecated
                                            'metadata.md5': md5,
                                            'metadata.contentType': contentType,
                                        }
                                    },
                                    null,
                                    (e, r) => {
                                    }
                                );
                            }
                        }
                        md5WhenReady();
                    }
                    return callback ? callback(null, retFile) : null;
                }
            });
            writeStream.on('error', err => callback ? callback(err) : null);
            writeStream.on('close', function (error) {
            });

            return writeStream;
        }

        return null;
    }

    findOneStream(selector, options, callback) {
        let bsonOID;

        if (selector && selector.hasOwnProperty('_id')) {
            bsonOID = new ObjectID(selector._id.toHexString());
        } else if (selector) {// if (selector.hasOwnProperty('md5')) {
            //TODO, this can work as a normal selector
            bsonOID = Meteor.wrapAsync(cb => {
                this.bucket.find(selector).forEach((result) => {
                    if (!result) return cb(`no file found for ${JSON.stringify(selector)}`);
                    return cb(null, result._id);
                });
            })();
        } else {
            return console.error('Please provide _id or md5 in selector');
        }
        return this.bucket.openDownloadStream(bsonOID);
    }

    //remove is no longer needed.  calling super.remove works perfectly fine, I confirmed the file data is deleted
    /*    remove(selector, callback) {
            console.log('remove method called');
            if (callback == null) {
                callback = undefined;
            }
            callback = share.bind_env(callback);
            if (selector != null) {
                let ret = 0;
                this.find(selector).forEach(file => {
                    const res = Meteor.wrapAsync(callback => {
                        const objectID = new ObjectID(`${file._id._str}`);
                        //The normal collection remove method works just fine
                        super.remove({_id:objectID}, callback)
                    })();
                    return ret += res ? 1 : 0;
                });
                return ret;
            } else {
                const err = new Meteor.Error("Remove with an empty selector is not supported");
                if (callback != null) {
                    callback(err);
                } else {
                    throw err;
                }
            }
        }*/

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

