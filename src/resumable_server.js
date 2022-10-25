/*
 * decaffeinate suggestions:
 * DS102: Remove unnecessary code created because of implicit returns
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/main/docs/suggestions.md
 */
//###########################################################################
//     Copyright (C) 2014-2017 by Vaughn Iverson
//     fileCollection is free software released under the MIT/X11 license.
//     See included LICENSE file for details.
//###########################################################################

if (Meteor.isServer) {

    const express = Npm.require('express');
    const mongodb = Npm.require('mongodb');
    const grid = Npm.require('gridfs-locking-stream');
    const gridLocks = Npm.require('gridfs-locks');
    const dicer = Npm.require('dicer');
    const async = Npm.require('async');

    // This function checks to see if all of the parts of a Resumable.js uploaded file are now in the gridFS
    // Collection. If so, it completes the file by moving all of the chunks to the correct file and cleans up

    const check_order = function(file, callback) {
        const fileId = mongodb.ObjectID(`${file.metadata._Resumable.resumableIdentifier}`);
        const lock = gridLocks.Lock(fileId, this.locks, {}).obtainWriteLock();
        lock.on('locked', () => {

            const files = this.db.collection(`${this.root}.files`);

            const cursor = files.find(
                {
                    'metadata._Resumable.resumableIdentifier': file.metadata._Resumable.resumableIdentifier,
                    length: {
                        $ne: 0
                    }
                },
                {
                    fields: {
                        length: 1,
                        metadata: 1
                    },
                    sort: {
                        'metadata._Resumable.resumableChunkNumber': 1
                    }
                }
            );

            return cursor.count((err, count) => {
                if (err) {
                    lock.releaseLock();
                    return callback(err);
                }

                if (!(count >= 1)) {
                    cursor.close();
                    lock.releaseLock();
                    return callback();
                }

                if (count !== file.metadata._Resumable.resumableTotalChunks) {
                    cursor.close();
                    lock.releaseLock();
                    return callback();
                }

                // Manipulate the chunks and files collections directly under write lock
                const chunks = this.db.collection(`${this.root}.chunks`);

                cursor.batchSize(file.metadata._Resumable.resumableTotalChunks + 1);

                return cursor.toArray((err, parts) => {

                    if (err) {
                        lock.releaseLock();
                        return callback(err);
                    }

                    return async.eachLimit(parts, 5,
                        (part, cb) => {
                            if (err) {
                                console.error("Error from cursor.next()", err);
                                cb(err);
                            }
                            if (!part) { return cb(new Meteor.Error("Received null part")); }
                            const partId = mongodb.ObjectID(`${part._id}`);
                            const partlock = gridLocks.Lock(partId, this.locks, {}).obtainWriteLock();
                            partlock.on('locked', () => {
                                return async.series([
                                        // Move the chunks to the correct file
                                        cb => chunks.update({ files_id: partId, n: 0 },
                                            { $set: { files_id: fileId, n: part.metadata._Resumable.resumableChunkNumber - 1 }},
                                            cb),
                                        // Delete the temporary chunk file documents
                                        cb => files.remove({ _id: partId }, cb)
                                    ],
                                    (err, res) => {
                                        if (err) { return cb(err); }
                                        if (part.metadata._Resumable.resumableChunkNumber !== part.metadata._Resumable.resumableTotalChunks) {
                                            partlock.removeLock();
                                            return cb();
                                        } else {
                                            // check for a final hanging gridfs chunk
                                            return chunks.update({ files_id: partId, n: 1 },
                                                { $set: { files_id: fileId, n: part.metadata._Resumable.resumableChunkNumber }},
                                                function(err, res) {
                                                    partlock.removeLock();
                                                    if (err) { return cb(err); }
                                                    return cb();
                                                });
                                        }
                                    });
                            });
                            partlock.on('timed-out', () => cb(new Meteor.Error('Partlock timed out!')));
                            partlock.on('expired', () => cb(new Meteor.Error('Partlock expired!')));
                            return partlock.on('error', function(err) {
                                console.error(`Error obtaining partlock ${part._id}`, err);
                                return cb(err);
                            });
                        },
                        err => {
                            if (err) {
                                lock.releaseLock();
                                return callback(err);
                            }
                            // Build up the command for the md5 hash calculation
                            const md5Command = {
                                filemd5: fileId,
                                root: `${this.root}`
                            };
                            // Send the command to calculate the md5 hash of the file
                            return this.db.command(md5Command, function(err, results) {
                                if (err) {
                                    lock.releaseLock();
                                    return callback(err);
                                }
                                // Update the size and md5 to the file data
                                return files.update({ _id: fileId }, { $set: { length: file.metadata._Resumable.resumableTotalSize, md5: results.md5 }},
                                    (err, res) => {
                                        lock.releaseLock();
                                        return callback(err);
                                    });
                            });
                        });
                });
            });
        });

        lock.on('expires-soon', () => lock.renewLock().once('renewed', function(ld) {
            if (!ld) {
                return console.warn("Resumable upload lock renewal failed!");
            }
        }));
        lock.on('expired', () => callback(new Meteor.Error("File Lock expired")));
        lock.on('timed-out', () => callback(new Meteor.Error("File Lock timed out")));
        return lock.on('error', err => callback(err));
    };

    // Handle HTTP POST requests from Resumable.js

    const resumable_post_lookup = (params, query, multipart) => ({
        _id: share.safeObjectID(multipart?.params?.resumableIdentifier)
    });

    const resumable_post_handler = function(req, res, next) {

        // This has to be a resumable POST
        if (!req.multipart?.params?.resumableIdentifier) {
            console.error("Missing resumable.js multipart information");
            res.writeHead(501, share.defaultResponseHeaders);
            res.end();
            return;
        }

        const resumable = req.multipart.params;
        resumable.resumableTotalSize = parseInt(resumable.resumableTotalSize);
        resumable.resumableTotalChunks = parseInt(resumable.resumableTotalChunks);
        resumable.resumableChunkNumber = parseInt(resumable.resumableChunkNumber);
        resumable.resumableChunkSize = parseInt(resumable.resumableChunkSize);
        resumable.resumableCurrentChunkSize = parseInt(resumable.resumableCurrentChunkSize);

        if (req.maxUploadSize > 0) {
            if (!(resumable.resumableTotalSize <= req.maxUploadSize)) {
                res.writeHead(413, share.defaultResponseHeaders);
                res.end();
                return;
            }
        }

        // Sanity check the chunk sizes that are critical to reassembling the file from parts
        if (((req.gridFS.chunkSize !== resumable.resumableChunkSize) ||
                (!(resumable.resumableChunkNumber <= resumable.resumableTotalChunks)) ||
                (!((resumable.resumableTotalSize/resumable.resumableChunkSize) <= (resumable.resumableTotalChunks+1))) ||
                (resumable.resumableCurrentChunkSize !== resumable.resumableChunkSize)) &&
            ((resumable.resumableChunkNumber !== resumable.resumableTotalChunks) ||
                (!(resumable.resumableCurrentChunkSize < (2*resumable.resumableChunkSize))))) {

            res.writeHead(501, share.defaultResponseHeaders);
            res.end();
            return;
        }

        const chunkQuery = {
            length: resumable.resumableCurrentChunkSize,
            'metadata._Resumable.resumableIdentifier': resumable.resumableIdentifier,
            'metadata._Resumable.resumableChunkNumber': resumable.resumableChunkNumber
        };

        // This is to handle duplicate chunk uploads in case of network weirdness
        const findResult = this.findOne(chunkQuery, { fields: { _id: 1 }});

        if (findResult) {
            // Duplicate chunk... Don't rewrite it.
            // console.warn "Duplicate chunk detected: #{resumable.resumableChunkNumber}, #{resumable.resumableIdentifier}"
            res.writeHead(200, share.defaultResponseHeaders);
            return res.end();
        } else {
            // Everything looks good, so write this part
            req.gridFS.metadata._Resumable = resumable;
            const writeStream = this.upsertStream({
                filename: `_Resumable_${resumable.resumableIdentifier}_${resumable.resumableChunkNumber}_${resumable.resumableTotalChunks}`,
                metadata: req.gridFS.metadata
            });

            if (!writeStream) {
                res.writeHead(404, share.defaultResponseHeaders);
                res.end();
                return;
            }

            return req.multipart.fileStream.pipe(share.streamChunker(this.chunkSize)).pipe(writeStream)
                .on('close', share.bind_env(retFile => {
                    if (retFile) {
                        // Check to see if all of the parts are now available and can be reassembled
                        return check_order.bind(this)(req.gridFS, function(err) {
                            if (err) {
                                console.error("Error reassembling chunks of resumable.js upload", err);
                                res.writeHead(500, share.defaultResponseHeaders);
                            } else {
                                res.writeHead(200, share.defaultResponseHeaders);
                            }
                            return res.end();
                        });
                    } else {
                        console.error("Missing retFile on pipe close");
                        res.writeHead(500, share.defaultResponseHeaders);
                        return res.end();
                    }
                })).on('error', share.bind_env(err => {
                        console.error("Piping Error!", err);
                        res.writeHead(500, share.defaultResponseHeaders);
                        return res.end();
                    })
                );
        }
    };

    const resumable_get_lookup = function(params, query) {
        const q = { _id: share.safeObjectID(query.resumableIdentifier) };
        return q;
    };

    // This handles Resumable.js "test GET" requests, that exist to determine
    // if a part is already uploaded. It also handles HEAD requests, which
    // should be a bit more efficient and resumable.js now supports
    const resumable_get_handler = function(req, res, next) {
        const {
            query
        } = req;
        const chunkQuery = {
            $or: [
                {
                    _id: share.safeObjectID(query.resumableIdentifier),
                    length: parseInt(query.resumableTotalSize)
                },
                {
                    length: parseInt(query.resumableCurrentChunkSize),
                    'metadata._Resumable.resumableIdentifier': query.resumableIdentifier,
                    'metadata._Resumable.resumableChunkNumber': parseInt(query.resumableChunkNumber)
                }
            ]
        };

        const result = this.findOne(chunkQuery, { fields: { _id: 1 }});
        if (result) {
            // Chunk is present
            res.writeHead(200, share.defaultResponseHeaders);
        } else {
            // Chunk is missing
            res.writeHead(204, share.defaultResponseHeaders);
        }

        return res.end();
    };

    // Setup the GET and POST HTTP REST paths for Resumable.js in express
    share.resumablePaths = [
        {
            method: 'head',
            path: share.resumableBase,
            lookup: resumable_get_lookup,
            handler: resumable_get_handler
        },
        {
            method: 'post',
            path: share.resumableBase,
            lookup: resumable_post_lookup,
            handler: resumable_post_handler
        },
        {
            method: 'get',
            path: share.resumableBase,
            lookup: resumable_get_lookup,
            handler: resumable_get_handler
        }
    ];
}
