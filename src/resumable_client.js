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

import Resumable from "./resumable";

if (Meteor.isClient) {

    // This is a polyfill for bind(), added to make phantomjs 1.9.7 work
    if (!Function.prototype.bind) {
        Function.prototype.bind = function (oThis) {
            if (typeof this !== "function") {
                // closest thing possible to the ECMAScript 5 internal IsCallable function
                throw new TypeError("Function.prototype.bind - what is trying to be bound is not callable");
            }

            const aArgs = Array.prototype.slice.call(arguments, 1);
            const fToBind = this;
            const fNOP = function () {
            };
            const fBound = function () {
                const func = (this instanceof fNOP && oThis) ? this : oThis;
                return fToBind.apply(func, aArgs.concat(Array.prototype.slice.call(arguments)));
            };

            fNOP.prototype = this.prototype;

            fBound.prototype = new fNOP();
            return fBound;
        };
    }

    share.setup_resumable = function () {
        let url = `${this.baseURL}${share.resumableBase}`;
        if (Meteor.isCordova) {
            url = Meteor.absoluteUrl(url.replace(/^\//, ''));
        }
        const r = new Resumable({
            target: url,
            generateUniqueIdentifier(file) {
                return `${new Mongo.ObjectID().toHexString()}`;
            },
            fileParameterName: 'file',
            chunkSize: this.chunkSize,
            testChunks: true,
            testMethod: 'HEAD',
            permanentErrors: [204, 404, 415, 500, 501],
            simultaneousUploads: 3,
            maxFiles: undefined,
            maxFilesErrorCallback: undefined,
            prioritizeFirstAndLastChunk: false,
            query: undefined,
            headers: {},
            maxChunkRetries: 5,
            withCredentials: true
        });

        if (!r.support) {
            return this.resumable = null;
        } else {
            return this.resumable = r;
        }
    };
}
