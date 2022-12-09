/*
 * decaffeinate suggestions:
 * DS101: Remove unnecessary use of Array.from
 * DS102: Remove unnecessary code created because of implicit returns
 * DS207: Consider shorter variations of null checks
 * Full docs: https://github.com/decaffeinate/decaffeinate/blob/main/docs/suggestions.md
 */
//###########################################################################
//     Copyright (C) 2014-2017 by Vaughn Iverson
//     fileCollection is free software released under the MIT/X11 license.
//     See included LICENSE file for details.
//###########################################################################

import {WebApp} from "meteor/webapp";
import gridLocks from './gridfs-locks';

import grid from './gridfs-locking-stream';

if (Meteor.isServer) {

    const express = Npm.require('express');
    const cookieParser = Npm.require('cookie-parser');

    const Dicer = Npm.require('dicer');

    const find_mime_boundary = function (req) {
        const RE_BOUNDARY = /^multipart\/.+?(?:; boundary=(?:(?:"(.+)")|(?:([^\s]+))))$/i;
        const result = RE_BOUNDARY.exec(req.headers['content-type']);
        return result?.[1] || result?.[2];
    };

    // Fast MIME Multipart parsing of generic HTTP POST request bodies
    const dice_multipart = function (req, res, next) {
        next = share.bind_env(next);

        if ((req.method !== 'POST') || !!req.diced) {
            next();
            return;
        }

        req.diced = true; // Don't reenter for the same request on multiple routes

        let responseSent = false;
        const handleFailure = function (msg, err, retCode) {
            if (err == null) {
                err = "";
            }
            if (retCode == null) {
                retCode = 500;
            }
            console.error(`${msg} \n`, err);
            if (!responseSent) {
                responseSent = true;
                res.writeHead(retCode, share.defaultResponseHeaders);
                return res.end();
            }
        };

        const boundary = find_mime_boundary(req);

        if (!boundary) {
            handleFailure("No MIME multipart boundary found for dicer");
            return;
        }

        const params = {};
        let count = 0;
        let fileStream = null;
        let fileType = 'text/plain';
        let fileName = 'blob';

        const dicer = new Dicer({boundary});

        dicer.on('part', function (part) {
            part.on('header', function (header) {
                const RE_FILE = /^form-data; name="file"; filename="([^"]+)"/;
                const RE_PARAM = /^form-data; name="([^"]+)"/;
                for (let k in header) {
                    const v = header[k];
                    if (k === 'content-type') {
                        fileType = v;
                    }
                    if (k === 'content-disposition') {
                        const re = RE_FILE.exec(v);
                        const param = RE_PARAM.exec(v)?.[1];
                        if (re) {
                            fileStream = part;
                            fileName = re[1];
                        } else if (param) {
                            let data = '';
                            count++;
                            part.on('data', d => data += d.toString());
                            part.on('end', function () {
                                count--;
                                params[param] = data;
                                if ((count === 0) && fileStream) {
                                    req.multipart = {
                                        fileStream,
                                        fileName,
                                        fileType,
                                        params
                                    };
                                    responseSent = true;
                                    return next();
                                }
                            });
                        } else {
                            console.warn("Dicer part", v);
                        }
                    }
                }


                if ((count === 0) && fileStream) {
                    req.multipart = {
                        fileStream,
                        fileName,
                        fileType,
                        params
                    };
                    responseSent = true;
                    return next();
                }
            });

            return part.on('error', err => handleFailure('Error in Dicer while parsing multipart:', err));
        });

        dicer.on('error', err => handleFailure('Error in Dicer while parsing parts:', err));

        dicer.on('finish', function () {
            if (!fileStream) {
                return handleFailure("Error in Dicer, no file found in POST");
            }
        });

        return req.pipe(dicer);
    };

    // Handle a generic HTTP POST file upload

    // This curl command should be properly handled by this code:
    // % curl -X POST 'http://127.0.0.1:3000/gridfs/fs/38a14c8fef2d6cef53c70792' \
    //        -F 'file=@"universe.png";type=image/png' -H 'X-Auth-Token: zrtrotHrDzwA4nC5'

    const post = function (req, res, next) {
        // Handle filename or filetype data when included
        if (req.multipart.fileType) {
            req.gridFS.contentType = req.multipart.fileType;
        }
        if (req.multipart.fileName) {
            req.gridFS.filename = req.multipart.fileName;
        }

        // Write the file data.  No chunks here, this is the whole thing
        const stream = this.upsertStream(req.gridFS);
        if (stream) {
            return req.multipart.fileStream.pipe(share.streamChunker(this.chunkSize)).pipe(stream)
                .on('close', function (retFile) {
                    if (retFile) {
                        res.writeHead(200, share.defaultResponseHeaders);
                        return res.end();
                    }
                }).on('error', function (err) {
                    res.writeHead(500, share.defaultResponseHeaders);
                    return res.end();
                });
        } else {
            res.writeHead(410, share.defaultResponseHeaders);
            return res.end();
        }
    };

    // Handle a generic HTTP GET request
    // This also handles HEAD requests
    // If the request URL has a "?download=true" query, then a browser download response is triggered

    const get = function (req, res, next) {
        let end, statusCode, stream;
        const headers = {};
        for (let h in share.defaultResponseHeaders) {
            const v = share.defaultResponseHeaders[h];
            headers[h] = v;
        }

        //# If If-Modified-Since header present, and parses to a date, then we
        //# return 304 (Not Modified Since) if the modification date is less than
        //# the specified date, or they both format to the same UTC string
        //# (which can deal with some sub-second rounding caused by formatting).
        if (req.headers['if-modified-since']) {
            const since = Date.parse(req.headers['if-modified-since']); //# NaN if invaild
            if (since && req.gridFS.uploadDate && ((req.headers['if-modified-since'] === req.gridFS.uploadDate.toUTCString()) || (since >= req.gridFS.uploadDate.getTime()))) {
                res.writeHead(304, headers);
                res.end();
                return;
            }
        }

        // If range request in the header
        if (req.headers['range']) {
// Set status code to partial data
            statusCode = 206;

            // Pick out the range required by the browser
            const parts = req.headers["range"].replace(/bytes=/, "").split("-");
            const start = parseInt(parts[0], 10);
            end = (parts[1] ? parseInt(parts[1], 10) : req.gridFS.length - 1);

            // Unable to handle range request - Send the valid range with status code 416
            if ((start < 0) || (end >= req.gridFS.length) || (start > end) || isNaN(start) || isNaN(end)) {
                headers['Content-Range'] = "bytes */" + req.gridFS.length;
                res.writeHead(416, headers);
                res.end();
                return;
            }

            // Determine the chunk size
            const chunksize = (end - start) + 1;

            // Construct the range request header
            headers['Content-Range'] = 'bytes ' + start + '-' + end + '/' + req.gridFS.length;
            headers['Accept-Ranges'] = 'bytes';
            headers['Content-Type'] = req.gridFS.contentType;
            headers['Content-Length'] = chunksize;
            headers['Last-Modified'] = req.gridFS.uploadDate.toUTCString();

            // Read the partial request from gridfs stream
            if (req.method !== 'HEAD') {
                stream = this.findOneStream(
                    {_id: req.gridFS._id}
                    , {
                        range: {
                            start,
                            end
                        }
                    }
                );
            }

// Otherwise prepare to stream the whole file
        } else {
// Set default status code
            statusCode = 200;

            // Set default headers
            headers['Content-Type'] = req.gridFS.contentType;
            headers['Content-MD5'] = req.gridFS.md5 || req.gridFS.metadata.md5; //Mongo 6 has no MD5 at root record
            headers['Content-Length'] = req.gridFS.length;
            headers['Last-Modified'] = req.gridFS.uploadDate.toUTCString();


            // Open file to stream
            if (req.method !== 'HEAD') {
                stream = this.findOneStream({_id: req.gridFS._id});
            }
        }

        // Trigger download in browser, optionally specify filename.
        if ((req.query.download && (req.query.download.toLowerCase() === 'true')) || req.query.filename) {
            const filename = encodeURIComponent(req.query.filename != null ? req.query.filename : req.gridFS.filename);
            headers['Content-Disposition'] = `attachment; filename=\"${filename}\"; filename*=UTF-8''${filename}`;
        }

        // If specified in url query set cache to specified value, might want to add more options later.
        if (req.query.cache && !isNaN(parseInt(req.query.cache))) {
            headers['Cache-Control'] = "max-age=" + parseInt(req.query.cache) + ", private";
        }

        // HEADs don't have a body
        if (req.method === 'HEAD') {
            res.writeHead(204, headers);
            res.end();
            return;
        }

        // Stream file
        if (stream) {
            res.writeHead(statusCode, headers);
            return stream.pipe(res)
                .on('close', () => res.end()).on('error', function (err) {
                    res.writeHead(500, share.defaultResponseHeaders);
                    return res.end(err);
                });
        } else {
            res.writeHead(410, share.defaultResponseHeaders);
            return res.end();
        }
    };

    // Handle a generic HTTP PUT request

    // This curl command should be properly handled by this code:
    // % curl -X PUT 'http://127.0.0.1:3000/gridfs/fs/7868f3df8425ae68a572b334' \
    //        -T "universe.png" -H 'Content-Type: image/png' -H 'X-Auth-Token: tEPAwXbGwgfGiJL35'

    const put = function (req, res, next) {
// Handle content type if it's present
        if (req.headers['content-type']) {
            req.gridFS.contentType = req.headers['content-type'];
        }

        // Write the file
        const stream = this.upsertStream(req.gridFS);
        if (stream) {
            return req.pipe(share.streamChunker(this.chunkSize)).pipe(stream)
                .on('close', function (retFile) {
                    if (retFile) {
                        res.writeHead(200, share.defaultResponseHeaders);
                        return res.end();
                    } else {
                    }
                }).on('error', function (err) {
                    res.writeHead(500, share.defaultResponseHeaders);
                    return res.end(err);
                });
        } else {
            res.writeHead(404, share.defaultResponseHeaders);
            return res.end(`${req.url} Not found!`);
        }
    };

    // Handle a generic HTTP DELETE request

    // This curl command should be properly handled by this code:
    // % curl -X DELETE 'http://127.0.0.1:3000/gridfs/fs/7868f3df8425ae68a572b334' \
    //        -H 'X-Auth-Token: tEPAwXbGwgfGiJL35'

    const del = function (req, res, next) {
        this.remove(req.gridFS);
        res.writeHead(204, share.defaultResponseHeaders);
        return res.end();
    };

    // Setup all of the application specified paths and file lookups in express
    // Also performs allow/deny permission checks for POST/PUT/DELETE
    const build_access_point = function (http) {

        // Loop over the app supplied http paths
        for (let r of Array.from(http)) {

            if (r.method.toUpperCase() === 'POST') {
                this.router.post(r.path, dice_multipart);
            }

            // Add an express middleware for each application REST path
            this.router[r.method](r.path, (r => {
                    return (req, res, next) => {

                        // params and queries literally named "_id" get converted to ObjectIDs automatically
                        if (req.params?._id != null) {
                            req.params._id = share.safeObjectID(req.params._id);
                        }
                        if (req.query?._id != null) {
                            req.query._id = share.safeObjectID(req.query._id);
                        }

                        // Build the path lookup mongoDB query object for the gridFS files collection
                        const lookup = r.lookup?.bind(this)(req.params || {}, req.query || {}, req.multipart);
                        if (lookup == null) {
                            // No lookup returned, so bailing
                            res.writeHead(500, share.defaultResponseHeaders);
                            res.end();
                        } else {
                            // Perform the collection query
                            let opts;
                            req.gridFS = this.findOne(lookup);
                            if (!req.gridFS) {
                                res.writeHead(404, share.defaultResponseHeaders);
                                res.end();
                                return;
                            }

                            // Make sure that the requested method is permitted for this file in the allow/deny rules
                            switch (req.method) {
                                case 'HEAD':
                                case 'GET':
                                    if (!share.check_allow_deny.bind(this)('read', req.meteorUserId, req.gridFS)) {
                                        res.writeHead(403, share.defaultResponseHeaders);
                                        res.end();
                                        return;
                                    }
                                    break;
                                case 'POST':
                                case 'PUT':
                                    req.maxUploadSize = this.maxUploadSize;
                                    if (!(opts = share.check_allow_deny.bind(this)('write', req.meteorUserId, req.gridFS))) {
                                        res.writeHead(403, share.defaultResponseHeaders);
                                        res.end();
                                        return;
                                    }
                                    if ((opts.maxUploadSize != null) && (typeof opts.maxUploadSize === 'number')) {
                                        req.maxUploadSize = opts.maxUploadSize;
                                    }
                                    if (req.maxUploadSize > 0) {
                                        if (req.headers['content-length'] == null) {
                                            res.writeHead(411, share.defaultResponseHeaders);
                                            res.end();
                                            return;
                                        }
                                        if (!(parseInt(req.headers['content-length']) <= req.maxUploadSize)) {
                                            res.writeHead(413, share.defaultResponseHeaders);
                                            res.end();
                                            return;
                                        }
                                    }
                                    break;
                                case 'DELETE':
                                    if (!share.check_allow_deny.bind(this)('remove', req.meteorUserId, req.gridFS)) {
                                        res.writeHead(403, share.defaultResponseHeaders);
                                        res.end();
                                        return;
                                    }
                                    break;
                                case 'OPTIONS': // Should there be a permission for options?
                                    if (!share.check_allow_deny.bind(this)('read', req.meteorUserId, req.gridFS) &&
                                        !share.check_allow_deny.bind(this)('write', req.meteorUserId, req.gridFS) &&
                                        !share.check_allow_deny.bind(this)('remove', req.meteorUserId, req.gridFS)) {
                                        res.writeHead(403, share.defaultResponseHeaders);
                                        res.end();
                                        return;
                                    }
                                    break;
                                default:
                                    res.writeHead(500, share.defaultResponseHeaders);
                                    res.end();
                                    return;
                            }

                            return next();
                        }
                    };
                })(r)
            );

            // Add an express middleware for each custom request handler
            if (typeof r.handler === 'function') {
                this.router[r.method](r.path, r.handler.bind(this));
            }
        }

        // Add all of generic request handling methods to the express route
        return this.router.route('/*')
            .all(function (req, res, next) {   // There needs to be a valid req.gridFS object here
                if (req.gridFS != null) {
                    next();
                    return;
                } else {
                    res.writeHead(404, share.defaultResponseHeaders);
                    return res.end();
                }
            }).head(get.bind(this))// Generic HTTP method handlers
            .get(get.bind(this))
            .put(put.bind(this))
            .post(post.bind(this))
            .delete(del.bind(this))
            .all(function (req, res, next) {   // Unkown methods are denied
                res.writeHead(500, share.defaultResponseHeaders);
                return res.end();
            });
    };

    // Performs a meteor userId lookup by hashed access token

    const lookup_userId_by_token = function (authToken) {
        const userDoc = Meteor.users?.findOne({
            'services.resume.loginTokens': {
                $elemMatch: {
                    hashedToken: Accounts?._hashLoginToken(authToken)
                }
            }
        });
        return userDoc?._id || null;
    };

    // Express middleware to convert a Meteor access token provided in an HTTP request
    // to a Meteor userId attached to the request object as req.meteorUserId

    const handle_auth = function (req, res, next) {
        if (req.meteorUserId == null) {
            // Lookup userId if token is provided in HTTP header
            if (req.headers?.['x-auth-token'] != null ||
                req.cookies?.['X-Auth-Token'] != null
            ) {
                if(req.headers['x-auth-token'])
                    req.meteorUserId = lookup_userId_by_token(req.headers['x-auth-token']);
                // Or as a URL query of the same name
                else if(req.cookies['X-Auth-Token'])
                    req.meteorUserId = lookup_userId_by_token(req.cookies['X-Auth-Token']);
            } else {
                req.meteorUserId = null;
            }
        }
        return next();
    };

    // Set up all of the middleware, including optional support for Resumable.js chunked uploads
    share.setupHttpAccess = function (options) {

        // Set up support for resumable.js if requested
        if (options.resumable) {
            if (options.http == null) {
                options.http = [];
            }
            let resumableHandlers = [];
            const otherHandlers = [];
            for (let h of Array.from(options.http)) {
                if (h.path === share.resumableBase) {
                    resumableHandlers.push(h);
                } else {
                    otherHandlers.push(h);
                }
            }
            resumableHandlers = resumableHandlers.concat(share.resumablePaths);
            options.http = resumableHandlers.concat(otherHandlers);
        }

        // Don't setup any middleware unless there are routes defined
        if (options.http?.length > 0) {
            const r = express.Router();
            r.use(express.query()); // Parse URL query strings
            r.use(cookieParser()); // Parse cookies
            r.use(handle_auth); // Turn x-auth-tokens into Meteor userIds
            WebApp.rawConnectHandlers.use(this.baseURL, share.bind_env(r));

            // Setup application HTTP REST interface
            this.router = express.Router();
            build_access_point.bind(this)(options.http, this.router);
            return WebApp.rawConnectHandlers.use(this.baseURL, share.bind_env(this.router));
        }
    };
}
