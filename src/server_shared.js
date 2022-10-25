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


if (Meteor.isServer) {

    const through2 = Npm.require('through2');

    share.defaultResponseHeaders =
        {'Content-Type': 'text/plain'};

    share.check_allow_deny = function(type, userId, file, fields) {

        const checkRules = function(rules) {
            let res = false;
            for (let func of Array.from(rules[type])) {
                if (!res) {
                    res = func(userId, file, fields);
                }
            }
            return res;
        };

        return !checkRules(this.denys) && checkRules(this.allows);
    };

    share.bind_env = function(func) {
        if (func != null) {
            return Meteor.bindEnvironment(func, function(err) { throw err; });
        } else {
            return func;
        }
    };

    share.safeObjectID = function(s) {
        if (s?.match(/^[0-9a-f]{24}$/i)) {  // Validate that _id is a 12 byte hex string
            return new Mongo.ObjectID(s);
        } else {
            return null;
        }
    };

    share.streamChunker = function(size) {
        if (size == null) { size = share.defaultChunkSize; }
        const makeFuncs = function(size) {
            let bufferList = [ new Buffer.alloc(0) ];
            let total = 0;
            const flush = function(cb) {
                const outSize = total > size ? size : total;
                if (outSize > 0) {
                    const outputBuffer = Buffer.concat(bufferList, outSize);
                    this.push(outputBuffer);
                    total -= outSize;
                }
                const lastBuffer = bufferList.pop();
                const newBuffer = lastBuffer.slice(lastBuffer.length - total);
                bufferList = [ newBuffer ];
                if (total < size) {
                    return cb();
                } else {
                    return flush.bind(this)(cb);
                }
            };
            const transform = function(chunk, enc, cb) {
                bufferList.push(chunk);
                total += chunk.length;
                if (total < size) {
                    return cb();
                } else {
                    return flush.bind(this)(cb);
                }
            };
            return [transform, flush];
        };
        return through2.apply(this, makeFuncs(size));
    };
}
