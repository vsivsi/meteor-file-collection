# file-collection

[![Build Status](https://travis-ci.org/vsivsi/meteor-file-collection.svg)](https://travis-ci.org/vsivsi/meteor-file-collection)

## Introduction

file-collection is a Meteor.js package that cleanly extends Meteor's Collection metaphor to efficiently manage collections of files and their data. File Collections are fully reactive, and if you know how to use Meteor Collections, you already know most of what you need to begin working with this package.

Major features:

* HTTP upload and download including support for Meteor authentication
* Client and Server integration of [resumable.js](http://resumablejs.com/) for robust chunked uploading
* Also compatible with traditional HTTP POST or PUT file uploading
* HTTP range requests support random access for resumable downloads, media seeking, etc.
* Robust file locking allows safe replacement and removal of files even on a busy server
* External changes to the underlying file store automatically synchronize with the Meteor collection
* Designed for efficient handling of millions of small files as well as huge files 10GB and above

These features (and more) are possible because file-collection tightly integrates MongoDB [gridFS](http://docs.mongodb.org/manual/reference/gridfs/) with Meteor Collections, without any intervening plumbing or unnecessary layers of abstraction.

#### Quick server-side example

```javascript
myFiles = new FileCollection('myFiles',
  { resumable: true,    // Enable built-in resumable.js chunked upload support
    http: [             // Define HTTP route
      { method: 'get',  // Enable a GET endpoint
        path: '/:md5',  // this will be at route "/gridfs/myFiles/:md5"
        lookup: function (params, query) {  // uses express style url params
          return { md5: params.md5 };       // a query mapping url to myFiles
}}]});

// You can add publications and allow/deny rules here to securely
// access myFiles from clients.
// On the server, you can access everything without limitation:

// Find a file document by name
thatFile = myFiles.findOne({ filename: 'lolcat.gif' });

// or get a file's data as a node.js Stream2
thatFileStream = myFiles.findOneStream({ filename: 'lolcat.gif' });

// Easily remove a file and its data
result = myFiles.remove(thatFile._id);
```

### Feature summary

Under the hood, file data is stored entirely within the Meteor MongoDB instance using a Mongo technology called [gridFS](http://docs.mongodb.org/manual/reference/gridfs/). Your file collection and the underlying gridFS collection remain perfectly in sync because they *are* the same collection; and file collections are automatically safe for concurrent read/write access to files via [MongoDB based locking](https://github.com/vsivsi/gridfs-locks). The file-collection package also provides a simple way to enable secure HTTP (GET, POST, PUT, DELETE) interfaces to your files, and additionally has built-in support for robust and resumable file uploads using the excellent [Resumable.js](http://www.resumablejs.com/) library.

### What's new in v1.3?

*   CORS/Cordova support via the ability to define custom HTTP OPTIONS request handlers
*   Global and per-request file upload size limits via the new `maxUploadSize` option

Additional changes are detailed in the HISTORY file.

### Design philosophy

**Update: CollectionFS appears to no longer be actively maintained, so caveat emptor.**

My goal in writing this package was to stay true to the spirit of Meteor and build something efficient and secure that "just works" with a minimum of fuss.

If you've been searching for ways to deal with file data on Meteor, you've probably also encountered [collectionFS](https://atmospherejs.com/cfs/standard-packages). If not, you should definitely check it out. It's a great set of packages written by smart people, and I even pitched in to help with a rewrite of their MongoDB gridFS support.

Here's the difference in a nutshell: collectionFS is a Ferrari, and file-collection is a Fiat.

They do approximately the same thing using some of the same technologies, but reflect different design priorities. file-collection is much simpler and somewhat less flexible; but if it meets your needs you'll find it has a lot fewer moving parts and may be significantly more efficient to work with and use.

If you're trying to quickly prototype an idea or you know that you just need a straightforward way of dealing with files, you should definitely try file-collection. Because it is so much simpler, you may also find that it is easier to understand and customize for the specific needs of your project.

## Example

Enough words, time for some more code...

The block below implements a `FileCollection` on server, including support for owner-secured HTTP file upload using `Resumable.js` and HTTP download. It also sets up the client to provide drag and drop chunked file uploads to the collection. The only things missing here are UI templates and some helper functions. See the [meteor-file-sample-app](https://github.com/vsivsi/meteor-file-sample-app) project for a complete working version written in [CoffeeScript](http://coffeescript.org/).

```javascript
// Create a file collection, and enable file upload and download using HTTP
myFiles = new FileCollection('myFiles',
  { resumable: true,   // Enable built-in resumable.js upload support
    http: [
      { method: 'get',
        path: '/:md5',  // this will be at route "/gridfs/myFiles/:md5"
        lookup: function (params, query) {  // uses express style url params
          return { md5: params.md5 };       // a query mapping url to myFiles
        }
      }
    ]
  }
);

if (Meteor.isServer) {

  // Only publish files owned by this userId, and ignore
  // file chunks being used by Resumable.js for current uploads
  Meteor.publish('myData',
    function (clientUserId) {
      if (clientUserId === this.userId) {
        return myFiles.find({ 'metadata._Resumable': { $exists: false },
                              'metadata.owner': this.userId });
      } else {        // Prevent client race condition:
        return null;  // This is triggered when publish is rerun with a new
                      // userId before client has resubscribed with that userId
      }
    }
  );

  // Allow rules for security. Should look familiar!
  // Without these, no file writes would be allowed
  myFiles.allow({
    // The creator of a file owns it. UserId may be null.
    insert: function (userId, file) {
      // Assign the proper owner when a file is created
      file.metadata = file.metadata || {};
      file.metadata.owner = userId;
      return true;
    },
    // Only owners can remove a file
    remove: function (userId, file) {
      // Only owners can delete
      return (userId === file.metadata.owner);
    },
    // Only owners can retrieve a file via HTTP GET
    read: function (userId, file) {
      return (userId === file.metadata.owner);
    },
    // This rule secures the HTTP REST interfaces' PUT/POST
    // Necessary to support Resumable.js
    write: function (userId, file, fields) {
      // Only owners can upload file data
      return (userId === file.metadata.owner);
    }
  });
}

if (Meteor.isClient) {

  Meteor.startup(function() {

    // This assigns a file upload drop zone to some DOM node
    myFiles.resumable.assignDrop($(".fileDrop"));

    // This assigns a browse action to a DOM node
    myFiles.resumable.assignBrowse($(".fileBrowse"));

    // When a file is added via drag and drop
    myFiles.resumable.on('fileAdded', function (file) {

      // Create a new file in the file collection to upload
      myFiles.insert({
        _id: file.uniqueIdentifier,  // This is the ID resumable will use
        filename: file.fileName,
        contentType: file.file.type
        },
        function (err, _id) {  // Callback to .insert
          if (err) { return console.error("File creation failed!", err); }
          // Once the file exists on the server, start uploading
          myFiles.resumable.upload();
        }
      );
    });

    // This autorun keeps a cookie up-to-date with the Meteor Auth token
    // of the logged-in user. This is needed so that the read/write allow
    // rules on the server can verify the userId of each HTTP request.
    Deps.autorun(function () {
      // Sending userId prevents a race condition
      Meteor.subscribe('myData', Meteor.userId());
      // $.cookie() assumes use of "jquery-cookie" Atmosphere package.
      // You can use any other cookie package you may prefer...
      $.cookie('X-Auth-Token', Accounts._storedLoginToken(), { path: '/' });
    });
  });
}
```

## Installation

I've only tested with Meteor v0.9.x and v1.x.x, and older versions run on Meteor v0.8 as well, but why would you want to do that?

To add to your project, run:

    meteor add vsivsi:file-collection

The package exposes a global object `FileCollection` on both client and server.

If you'd like to try out the sample app, you can clone the repo from github:

```
git clone https://github.com/vsivsi/meteor-file-sample-app.git fcSample
```

Then go to the `fcSample` subdirectory and run meteor to launch:

```
cd fcSample
meteor
```

You should now be able to point your browser to `http://localhost:3000/` and play with the sample app.

A more advanced example that implements a basic image gallery with upload and download support and automatic thumbnail generation using the [job-collection package](https://atmospherejs.com/vsivsi/job-collection) is available here: https://github.com/vsivsi/meteor-file-job-sample-app

To run tests (using Meteor tiny-test):

```
git clone --recursive https://github.com/vsivsi/meteor-file-collection FileCollection
cd FileCollection
meteor test-packages ./
```
Load `http://localhost:3000/` and the tests should run in your browser and on the server.

## Use

Below you'll find the [MongoDB gridFS `files` data model](http://docs.mongodb.org/manual/reference/gridfs/#the-files-collection). This is also the schema used by file-collection because a FileCollection *is* a gridFS collection.

```javascript
{
  "_id" : <ObjectId>,
  "length" : <number>,
  "chunkSize" : <number>
  "uploadDate" : <Date>
  "md5" : <string>

  "filename" : <string>,
  "contentType" : <string>,
  "aliases" : <array of strings>,
  "metadata" : <object>
}
```

Here are a few things to keep in mind about the gridFS file data model:

*    Some of the attributes belong to gridFS, and you may **lose data** if you mess around with these.
*    For this reason, `_id`, `length`, `chunkSize`, `uploadDate` and `md5` are read-only.
*    Some of the attributes belong to you. Your application can do whatever you want with them.
*    `filename`, `contentType`, `aliases` and `metadata` are yours. Go to town.
*    `contentType` should probably be a valid [MIME Type](https://en.wikipedia.org/wiki/MIME_type)
*    `filename` is *not* guaranteed unique. `_id` is a better bet if you want to be sure of what you're getting.

Sound complicated? It really isn't and file-collection is here to help.

First off, when you create a new file you use `myFiles.insert(...)` and just populate whatever attributes you care about. The file-collection package does the rest. You are guaranteed to get a valid gridFS file, even if you just do this: `id = myFiles.insert();`

Likewise, when you run `myFiles.update(...)` on the server, file-collection tries really hard to make sure that you aren't clobbering one of the "read-only" attributes with your update modifier. For safety, clients are never allowed to directly `update`, although you can selectively give them that power via `Meteor.methods()`.

### Limits and performance

There are essentially no hard limits on the number or size of files other than what your hardware will support.

At no point in normal operation is a file-sized data buffer ever in memory. All of the file data import/export mechanisms are [stream based](http://nodejs.org/api/stream.html#stream_stream), so even very active servers should not see much memory dedicated to file transfers.

File data is never copied within a collection. During chunked file uploading, file chunk references are changed, but the data itself is never copied. This makes file-collection particularly efficient when handling multi-gigabyte files.

file-collection uses robust multiple reader / exclusive writer file locking on top of gridFS, so essentially any number of readers and writers of shared files may peacefully coexist without risk of file corruption. Note that if you have other applications reading/writing directly to a gridFS collection (e.g. a node.js program, not using Meteor/file-collection), it will need to use the [`gridfs-locks`](https://www.npmjs.org/package/gridfs-locks) or [`gridfs-locking-stream`](https://www.npmjs.org/package/gridfs-locking-stream) npm packages to safely inter-operate with file-collection.

### Security

You may have noticed that the gridFS `files` data model says nothing about file ownership. That's your job. If you look again at the example code block above, you will see a bare bones `Meteor.userId` based ownership scheme implemented with the attribute `file.metadata.owner`. As with any Meteor Collection, allow/deny rules are needed to enforce and defend that document attribute, and file-collection implements that in *almost* the same way that ordinary Meteor Collections do. Here's how they're a little different:

*    A file is always initially created as a valid zero-length gridFS file using `insert` on the client/server. When it takes place on the client, the `insert` allow/deny rules apply.
*    The `remove` allow/deny rules work just as you would expect for client calls, and they also secure the HTTP DELETE method when it's used.
*    The `read` allow/deny rules secure access to file data requested via HTTP GET. These rules have no effect on client `find()` or `findOne()` methods; these operations are secured by `Meteor.publish()` as with any meteor collection.
*    The `write` allow/deny rules secure writing file *data* to a previously inserted file via HTTP methods. This means that an HTTP POST/PUT cannot create a new file by itself. It needs to have been inserted first, and only then can data be added to it using HTTP.
*    There are no `update` allow/deny rules because clients are always prohibited from directly updating a file document's attributes.
*    All HTTP methods are disabled by default. When enabled, they can be authenticated to a Meteor `userId` by using a currently valid authentication token passed either in the HTTP request header or using an HTTP Cookie.

## API

The `FileCollection` API is essentially an extension of the [Meteor Collection API](http://docs.meteor.com/#collections), with almost all of the same methods and a few new file specific ones mixed in.

The big loser is `upsert()`, it's gone in `FileCollection`. If you try to call it, you'll get an error. `update()` is also disabled on the client side, but it can be safely used on the server to implement `Meteor.Method()` calls for clients to use.

### fc = new FileCollection([name], [options])
#### Create a new `FileCollection` object - Server and Client

```javascript

// create a new FileCollection with all default values

fc = new FileCollection('fs',  // base name of collection
  { resumable: false,          // Disable resumable.js upload support
    resumableIndexName: undefined,    // Not used when resumable is false
    chunkSize: 2*1024*1024 - 1024,    // Use 2MB chunks for gridFS and resumable
    baseURL: '\gridfs\fs',     // Default base URL for all HTTP methods
    locks: {                   // Parameters for gridfs-locks
      timeOut: 360,            // Seconds to wait for an unavailable lock
      pollingInterval: 5,      // Seconds to wait between lock attempts
      lockExpiration: 90       // Seconds until a lock expires
    }
    http: []    // HTTP method definitions, none by default
  }
);
```

**Note:** The same `FileCollection` call should be made on both the client and server.

`name` is the root name of the underlying MongoDB gridFS collection. If omitted, it defaults to `'fs'`, the default gridFS collection name. Internally, three collections are used for each `FileCollection` instance:

*     `[name].files` - This is the collection you actually see when using file-collection
*     `[name].chunks` - This collection contains the actual file data chunks. It is managed automatically.
*     `[name].locks` - This collection is used by `gridfs-locks` to make concurrent reading/writing safe.

`FileCollection` is a subclass of `Meteor.Collection`, however it doesn't support the same `[options]`.
Meteor Collections support `connection`, `idGeneration` and `transform` options. Currently, file-collection only supports the default Meteor server connection, although this may change in the future. All `_id` values used by `FileCollection` are MongoDB style IDs. The Meteor Collection transform functionality is unsupported in `FileCollection`.

Here are the options `FileCollection` does support:

*    `options.resumable` - `<boolean>`  When `true`, exposes the [Resumable.js API](http://www.resumablejs.com/) on the client and the matching resumable HTTP support on the server.
*    `options.resumableIndexName` - `<string>`  When provided and `options.resumable` is `true`, this value will be the name of the internal-use MongoDB index that the server-side resumable.js support attempts to create. This is useful because the default index name MongoDB creates is long (94 chars out of a total maximum namespace length of 127 characters), which may create issues when combined with long collection and/or database names. If this collection already exists the first time an application runs using this setting, it will likely have no effect because an identical index will already exist (under a different name), causing MongoDB to ignore request to create a duplicate index with a different name. In this case, you must manually drop the old index and then restart your application to generate a new index with the requested name.
*    `options.chunkSize` - `<integer>`  Sets the gridFS and Resumable.js chunkSize in bytes. The default value of a little less than 2MB is probably a good compromise for most applications, with the maximum being 8MB - 1. Partial chunks are not padded, so there is no storage space benefit to using small chunk sizes. If you are uploading very large files over a fast network and upload spped matters, then a `chunkSize` of 8MB - 1KB (= 8387584) will likly optimize upload speed. However, if you elect to use such large `chunkSize` values, make sure that the replication oplog of your MongoDB instance is large enough to handle this, or you will risk having your client and server collections lose synchronization during uploads. Meteor's development mode only uses an oplog of 8 MB, which will almost certainly cause problems for high speed uploads to apps using a large `chunkSize`.
For more information on Meteor's use of the MongoDB oplog, see: [Meteor livequery](https://www.meteor.com/livequery).
*    `options.baseURL` - `<string>`  Sets the base route for all HTTP interfaces defined on this collection. Default value is `/gridfs/[name]`
*    `options.locks` - `<object>`  Locking parameters, the defaults should be fine and you shouldn't need to set this, but see the `gridfs-locks` [`LockCollection` docs](https://github.com/vsivsi/gridfs-locks#lockcollectiondb-options) for more information.
*    `option.maxUploadSize` - `<integer>`  Maximum number of bytes permitted for any HTTP POST, PUT or resumable.js file upload.
*    `option.http` - <array of objects>  HTTP interface configuration objects, described below:

#### Configuring HTTP methods

Each object in the `option.http` array defines one HTTP request interface on the server, and has these three attributes:

*    `obj.method` - `<string>`  The HTTP request method to define, one of `get`, `post`, `put`, `delete` (or `options` with a custom handler).
*    `obj.path` - `<string>`  An [express.js style](http://expressjs.com/4x/api.html#req.params) route path with parameters. This path will be added to the path specified by `options.baseURL`.
*    `obj.lookup` - `<function>`  A function that is called when an HTTP request matches the `method` and `path`. It is provided with the values of the route parameters and any URL query parameters, and it should return a mongoDB query object which can be used to find a file that matches those parameters. For POST requests, it is also provided any with MIME/multipart parameters and other file information from the multipart headers.
*    `obj.handler` - `<function>` OPTIONAL! This is an advanced feature that allows the developer to provide a custom "express.js style" request handler to satisfy requests for this specific request interface. For an example of how this works, please see the resumable.js upload support implementation in the source file `resumable_server.coffee`.

When arranging http interface definition objects in the array provided to `options.http`, be sure to put more specific paths for a given HTTP method before more general ones. For example: `\hash\:md5` should come before `\:filename\:_id` because `"hash"` would match to filename, and so `\hash\:md5` would never match if it came second. Obviously this is a contrived example to demonstrate that order is significant.

Note that an authenticated userId is not provided to the `lookup` function. UserId based permissions should be managed using the allow/deny rules described later on.

Here are some example HTTP interface definition objects to get you started:

```javascript
// GET file data by md5 sum
{ method: 'get',
  path:   '/hash/:md5',
  lookup: function (params, query) {
              return { md5: params.md5 } } }

// DELETE a file by _id. Note that the URL parameter ":_id" is a special
// case, in that it will automatically be converted to a Meteor ObjectID
// in the passed params object.
{ method: 'delete',
  path:   '/:_id',
  lookup: function (params, query) {
              return { _id: params._id } } }

// GET a file based on a filename or alias name value
{ method: 'get',
  path:   '/name/:name',
  lookup: function (params, query) {
    return {$or: [ {filename: params.name },
                   {aliases: {$in: [ params.name ]}} ]} }}

// PUT data to a file based on _id and a secret value stored as metadata
// where the secret is supplied as a query parameter e.g. ?secret=sfkljs
{ method: 'put',
  path:   '/write/:_id',
  lookup: function (params, query) {
    return { _id: params._id, "metadata.secret": query.secret} }}


// POST data to a file based on _id and a secret value stored as metadata
// where the secret is supplied as a MIME/Multipart parameter
{ method: 'post',
  path:   '/post/:_id',
  lookup: function (params, query, multipart) {
    return { _id: params._id, "metadata.secret": multipart.params.secret} }}

// GET a file based on a query type and numeric coordinates metadata
{ method: 'get',
  path:   '/tile/:z/:x/:y',
  lookup: function (params, query) {
    return { "metadata.x": parseInt(params.x), // Note that all params
             "metadata.y": parseInt(params.y), // (execept _id) are strings
             "metadata.z": parseInt(params.z),
             contentType: query.type} }}
```

#### CORS / Apache Cordova Support

The HTTP access in file-collection can be configured for compatibility with [Cross Origin Resource Sharing (CORS)](https://en.wikipedia.org/wiki/Cross-origin_resource_sharing) via use of a custom handler for the `'options'`
request method.

This provides a simple way to support accessing file-collection files in [Apache Cordova](https://github.com/meteor/meteor/wiki/Meteor-Cordova-integration) client applications using resumable endpoint:

```javascript
myFiles = new FileCollection('myFiles',
  { resumable: true,    // Enable built-in resumable.js chunked upload support
    http: [             // Define HTTP route
      { 
        method: 'POST',  // Enable a POST endpoint
        path: '/_resumable',  // this will be at route "/gridfs/images/_resumable"
        lookup: function (params, query) {  // uses express style url params
          return {};       // a dummy query
        },
        handler: function (req, res, next) {
            if (req.headers && req.headers.origin) {
                res.setHeader('Access-Control-Allow-Origin', req.headers.origin); // For Cordova
                res.setHeader('Access-Control-Allow-Credentials', true);
            }
            next();
        }
      },
      {
        method: 'head',  // Enable an HEAD endpoint (for CORS)
        path: '/_resumable',  // this will be at route "/gridfs/images/_resumable/"
        lookup: function (params, query) {  // uses express style url params
            return { };       // a dummy query
        },
        handler: function (req, res, next) {  // Custom express.js handler for HEAD
           if (req.headers && req.headers.origin) {
                  res.setHeader('Access-Control-Allow-Origin', req.headers.origin); // For Cordova
                  res.setHeader('Access-Control-Allow-Credentials', true);
              }
            next();
        }
      },
      {
        method: 'options',  // Enable an OPTIONS endpoint (for CORS)
        path: '/_resumable',  // this will be at route "/gridfs/images/_resumable/"
        lookup: function (params, query) {  // uses express style url params
            return { };       // a dummy query
        },
        handler: function (req, res, next) {  // Custom express.js handler for OPTIONS
            res.writeHead(200, {
                'Content-Type': 'text/plain',
                'Access-Control-Allow-Origin': req.headers.origin,  // For Cordova
                'Access-Control-Allow-Credentials': true,
                'Access-Control-Allow-Headers': 'x-auth-token, user-agent',
                'Access-Control-Allow-Methods': 'GET, POST, HEAD, OPTIONS'
            });
            res.end();
            return;
        }
      }
    ]
  }
);
```

**Note!:** Reportedly due to a bug in Cordova, you need to add the following line into your mobile-config.js
```
App.accessRule("blob:*");
```
Please notice that this package will only work with "blob" types when using resumable on Cordova enviroment. If you are using a "file" type remember to convert it to blob before the upload.

#### HTTP authentication

Authentication of HTTP requests is performed using Meteor login tokens. When Meteor [Accounts](http://docs.meteor.com/#accounts_api) are used in an application, a logged in client can see its current token using `Accounts._storedLoginToken()`. Tokens are passed in HTTP requests using either the HTTP header `X-Auth-Token: [token]` or using an HTTP cookie named `X-Auth-Token=[token]`. If the token matches a valid logged in user, then that userId will be provided to any allow/deny rules that are called for permission for an action.

For non-Meteor clients that aren't logged-in humans using browsers, it is possible to authenticate with Meteor using the DDP protocol and programmatically obtain a token. See the [ddp-login](https://www.npmjs.org/package/ddp-login) npm package for a node.js library and command-line utility capable of logging into Meteor (similar libraries also exist for other languages such as Python).

#### HTTP request behaviors

URLs used to HTTP GET file data within a browser can be configured to automatically trigger a "File SaveAs..." download by using the `?download=true` query in the request URL. Similarly, if the `?filename=[filename.ext]` query is used, a "File SaveAs..." download will be invoked, but using the specified filename as the default, rather than the GridFS `filename` as is the case with `?download=true`.

To cache files in the browser use the `?cache=172800` query in the request URL, where 172800 (48h) is the time in seconds. This will set the header response information to `cache-control:max-age=172800, private`. Caching is useful when streaming videos or audio files to avoid unwanted calls to the server.

HTTP PUT requests write the data from the request body directly into the file. By contrast, HTTP POST requests assume that the body is formatted as MIME multipart/form-data (as an old-school browser form based file upload would generate), and the data written to the file is taken from the part named `"file"`. Below are example [cURL](`https://en.wikipedia.org/wiki/CURL#cURL`) commands that successfully invoke each of the four possible HTTP methods.

```sh

# This assumes a baseURL of '/gridfs/fs' and method definitions with a path
# of '/:_id' for each method, for example:

# { method: 'delete',
#   path:   '/:_id',
#   lookup: function (params, query) {
#             return { _id: params._id } } }

# The file with _id = 38a14c8fef2d6cef53c70792 must exist for these to succeed.
# The auth token should match a logged-in userId

# GET the file data
curl -X GET 'http://127.0.0.1:3000/gridfs/fs/38a14c8fef2d6cef53c70792' \
     -H 'X-Auth-Token: 3pl5vbN_ZbKDJ1ko5JteO3ZSTrnQIl5g6fd8XW0U4NQ'

# POST with file in multipart/form-data
curl -X POST 'http://127.0.0.1:3000/gridfs/fs/38a14c8fef2d6cef53c70792' \
     -F 'file=@"lolcat.gif";type=image/gif' \
     -H 'X-Auth-Token: 3pl5vbN_ZbKDJ1ko5JteO3ZSTrnQIl5g6fd8XW0U4NQ'

# PUT with file in request body
curl -X PUT 'http://127.0.0.1:3000/gridfs/fs/38a14c8fef2d6cef53c70792' \
     -H 'Content-Type: image/gif' \
     -H 'X-Auth-Token: 3pl5vbN_ZbKDJ1ko5JteO3ZSTrnQIl5g6fd8XW0U4NQ' \
     -T "lolcat.gif"

# DELETE the file
curl -X DELETE 'http://127.0.0.1:3000/gridfs/fs/38a14c8fef2d6cef53c70792' \
     -H 'X-Auth-Token: 3pl5vbN_ZbKDJ1ko5JteO3ZSTrnQIl5g6fd8XW0U4NQ'
```

Below are the methods defined on the returned `FileCollection` object

### fc.resumable
#### Resumable.js API object - Client only

```javascript
fc.resumable.assignDrop($(".fileDrop"));  // Assign a file drop target

// When a file is dropped on the target (or added some other way)
myData.resumable.on('fileAdded', function (file) {
  // file contains a resumable,js file object, do something with it...
}
```

`fc.resumable` is a ready to use, preconfigured `Resumable` object that is available when a `FileCollection` is created with `options.resumable == true`. `fc.resumable` contains the results of calling `new Resumable([options])` where all of the options have been specified by file-collection to work with its server side support. See the [Resumable.js documentation](http://www.resumablejs.com/) for more details on how to use it.

### fc.find(selector, [options])
#### Find any number of files - Server and Client

```javascript
// Count the number of likely lolcats in collection, this is reactive
lols = fc.find({ 'contentType': 'image/gif'}).count();
```

`fc.find()` is identical to [Meteor's `Collection.find()`](http://docs.meteor.com/#find)

### fc.findOne(selector, [options])
#### Find a single file. - Server and Client

```javascript
// Grab the file document for a known lolcat
// This is not the file data, see fc.findOneStream() for that!
myLol = fc.findOne({ 'filename': 'lolcat.gif'});
```

`fc.findOne()` is identical to [Meteor's `Collection.findOne()`](http://docs.meteor.com/#findone)

### fc.insert([file], [callback])
#### Insert a new zero-length file. - Server and Client

```javascript
// Create a new zero-length file in the collection
// All fields are optional and will get defaults if omitted
_id = fc.insert({
  _id: new Meteor.Collection.ObjectID(),
  filename: 'nyancat.flv',
  contentType: 'video/x-flv',
  metadata: { owner: 'posterity' },
  aliases: [ ]
  }
  // Callback here, if you really care...
);
```

`fc.insert()` is the same as [Meteor's `Collection.insert()`](http://docs.meteor.com/#insert), except that the document is forced to be a [gridFS `files` document](http://docs.mongodb.org/manual/reference/gridfs/#the-files-collection). All attributes not supplied get default values, non-gridFS attributes are silently dropped. Inserts from the client that do not conform to the gridFS data model will automatically be denied. Client inserts will additionally be subjected to any `'insert'` allow/deny rules (which default to deny all inserts).

### fc.remove(selector, [callback])
#### Remove a file and all of its data. - Server and Client

```javascript
// Make it go away, data and all
fc.remove(
  { filename: 'nyancat.flv' }
  // Callback here, if you want to be absolultely sure it's really gone...
);
```

`fc.remove()` is nearly the same as [Meteor's `Collection.remove()`](http://docs.meteor.com/#remove), except that in addition to removing the file document, it also removes the file data chunks and locks from the gridFS store. For safety, undefined and empty selectors (`undefined`, `null` or `{}`) are all rejected. Client calls are subjected to any `'remove'`  allow/deny rules (which default to deny all removes). Returns the number of documents actually removed on the server, except when invoked on the client without a callback. In that case it returns the simulated number of documents removed from the local mini-mongo store.

### fc.update(selector, modifier, [options], [callback])
#### Update application controlled gridFS file attributes. - Server only

Note: A local-only version of update is available on the client. See docs for `fc.localUpdate()` for details.

```javascript
// Update some attributes we own
fc.update(
  { filename: 'keyboardcat.mp4' },
  {
    $set: { 'metadata.comment': 'Play them off...' } },
    $push: { aliases: 'Fatso.mp4' }
  }
  // Optional options here
  // Optional callback here
);
```

`fc.update()` is nearly the same as [Meteor's `Collection.update()`](http://docs.meteor.com/#update), except that it is a server only method, and it will return an error if:

*     any of the gridFS "read-only" attributes would be modified
*     any standard gridFS document level attributes would be removed
*     the `upsert` option is attempted

Since `fc.update()` only runs on the server, it is *not* subjected to any allow/deny rules.

### fc.localUpdate(selector, modifier, [options], [callback])
#### Update local minimongo file attributes. - Client only

**Warning!** Changes made using this function do not persist to the server! You must implement your own Meteor methods to perform persistent updates from a client. For example:

```javascript
// Implement latency compensated update using Meteor methods and localUpdate
Meteor.methods({
  updateFileComment: function (fileId, comment) {
    // Always check method params!
    check(fileId, Mongo.ObjectID);
    check(comment, Match.Where(function (x) {
      check(x, String);
      return x.length <= 140;
    }));
    // You'll probably want to do some kind of ownership check here...

    var update = null;
    // If desired you can avoid this by initializing fc.update
    // on the client to be fc.localUpdate
    if (this.isSimulation) {
      update = fc.localUpdate; // Client stub updates locally for latency comp
    } else { // isServer
      update = fc.update;  // Server actually persists the update
    }
    // Use whichever function the environment dictates
    update({ _id: _id }, {
        $set: { 'metadata.comment': comment }
      }
      // Optional options here
      // Optional callback here
    );
  }
});
```

`fc.localUpdate()` is nearly the same as [Meteor's server-side `Collection.update()`](http://docs.meteor.com/#update), except that it is a client only method, and changes made using it do not propagate to the server. This call is useful for implementing latency compensation in the client UI when performing server updates using a Meteor method. This call can be invoked in the client Method stub to simulate what will be happening on the server. For this reason, this call can perform updates using complex selectors and the `multi` option, unlike client side updates on normal Mongo Collections.

It will return an error if:

*     any of the gridFS "read-only" attributes would be modified
*     any standard gridFS document level attributes would be removed
*     the `upsert` option is attempted

Since `fc.localUpdate()` only changes data on the client, it is *not* subjected to any allow/deny rules.

### fc.allow(options)
#### Allow client insert and remove, and HTTP data accesses and updates, subject to your limitations. - Server only

`fc.allow(options)` is essentially the same as [Meteor's `Collection.allow()`](http://docs.meteor.com/#allow), except that the Meteor Collection `fetch` and `transform` options are not supported by `FileCollection`. In addition to returning true/false, rules may also return a (possibly empty) options object to indicate truth while affecting the behavior of the allowed request.  See the `maxUploadSize` option on `'write'` allow rules as an example. Note that more than one allow rule may apply to a given request, but unlike deny rules, they are not all guaranteed to run. Allow rules are run in the order in which they are defined, and the first one to return a truthy value wins, which can be significant if they return options or otherwise modify state.

`insert` rules are essentially the same as for ordinary Meteor collections.

`remove` rules also apply to HTTP DELETE requests.

In addition to Meteor's `insert` and `remove` rules, file-collection also uses `read` and `write` rules. These are used to secure access to file data via HTTP GET and POST/PUT requests, respectively.

`read` rules apply only to HTTP GET/HEAD requests retrieving file data, and have the same parameters as all other rules.

`write` rules are analogous to `update` rules on Meteor collections, except that they apply only to HTTP PUT/POST requests modifying file data, and will only (and always) see changes to the `length` and `md5` fields. For that reason the `fieldNames` parameter is omitted. Similarly, because MongoDB updates are not directly involved, no `modifier` parameter is provided to the `write` function. Write rules may optionally return an object with a positive integer `maxUploadSize` attribute instead of `true`. This indicates the maximum allowable upload size for this request. If this max upload size is provided, it will override any value provided for the `maxUploadSize` option on the fileCollection as a whole. Nonpositive values of `maxUploadSize` mean there will be no upload size limit for this request.

The parameters for callback functions for all four types of allow/deny rules are the same:

```js
function (userId, file) {
   // userId is Meteor account if authenticated
   // file is the gridFS file record for the matching file
}
```

### fc.deny(options)
#### Override allow rules. - Server only

```javascript
fc.deny({
  remove: function (userId, file) { return true; }  // Nobody can remove, boo!
});
```

`fc.deny(options)` is the same as [Meteor's `Collection.deny()`](http://docs.meteor.com/#deny), except that the Meteor Collection `fetch` and `transform` options are not supported by `FileCollection`. See `fc.allow()` above for more deatils.

### fc.findOneStream(selector, [options], [callback])
#### Find a file collection file and return a readable stream for its data. - Server only

```javascript
// Get a readable data stream for a known lolcat
lolStream = fc.findOneStream({ 'filename': 'lolcat.gif'});
```

`fc.findOneStream()` is like `fc.findOne()` except instead of returning the `files` document for the found file, it returns a [Readable stream](http://nodejs.org/api/stream.html#stream_class_stream_readable) for the found file's data.

`options.range` -- To get partial data from the file, use the `range` option to specify an object with `start` and `end` attributes:

```javascript
stream = fc.findOneStream({ 'filename': 'lolcat.gif'}, { range: { start: 100, end: 200 }})
```

`options.autoRenewLock` -- When true, the read lock on the underlying gridFS file will automatically be renewed before it expires, potentially multiple times. If you need more control over lock expiration behavior in your application, set this option to `false`. Default: `true`

Other available options are `options.sort` and `options.skip` which have the same behavior as they do for Meteor's [`Collection.findOne()`](http://docs.meteor.com/#findone).

The returned stream is a gridfs-locking-stream `readStream`, which has some [special methods and events it emits](https://github.com/vsivsi/gridfs-locking-stream#locking-options). You probably won't need to use these, but the stream will emit `'expires-soon'` and `'expired'` events if its read lock is getting too old, and it has three methods that can be used to control locking:
*     `stream.heldLock()` - Returns the gridfs-locks [`Lock` object](https://github.com/vsivsi/gridfs-locks#lock) held by the stream
*     `stream.renewLock([callback])` - Renews the held lock for another expiration interval
*     `stream.releaseLock([callback])` - Releases the held lock if you are done with the stream.

This last call, `stream.releaseLock()` may be useful if you use `file.findOneStream()` and then do not read the file to the end (which would cause the lock to release automatically). In this case, calling `stream.releaseLock()` is nice because it frees the lock before the expiration time is up. This would probably only matter for applications with lots of writers and readers contending for the same files, but it's good to know it exists. The values used for the locking parameters are set when the `FileCollection` is created via the `options.locks` option.

When the stream has ended, the `callback` is called with the gridFS file document.

### fc.upsertStream(file, [options], [callback])
#### Create/update a file collection file and return a writable stream to its data. - Server only

```javascript
// Get a writeable data stream to re-store all that is right and good
nyanStream = fc.upsertStream({ filename: 'nyancat.flv',
                               contentType: 'video/x-flv',
                               metadata: { caption: 'Not again!'}
                             });
```

`fc.upsertStream()` is a little bit like Meteor's `Collection.upsert()` only really not... If the `file` parameter contains an `_id` field, then the call will work on the file with that `_id`. If a file with that `_id` doesn't exist, or if no `_id` is provided, then a new file is `insert`ed into the file collection. Any application owned gridFS attributes (`filename`, `contentType`, `aliases`, `metadata`) that are present in the `file` parameter will be used for the file.

Once that is done, `fc.upsertStream()` returns a [writable stream](http://nodejs.org/api/stream.html#stream_class_stream_writable) for the file.

`options.autoRenewLock` -- Default: `true`. When true, the write lock on the underlying gridFS file will automatically be renewed before it expires, potentially multiple times. If you need more control over lock expiration behavior in your application, set this option to `false`.

*NOTE! Breaking Change*! Prior to file-collection v1.0, it was possible to specify `options.mode = 'w+'` and append to an existing file. This option is now ignored, and all calls to `fc.upsertStream()` will overwrite any existing data in the file.

The returned stream is a gridfs-locking-stream `writeStream`, which has some [special methods and events it emits](https://github.com/vsivsi/gridfs-locking-stream#locking-options). You probably won't need to use these, but the stream will emit `'expires-soon'` and `'expired'` events if its exclusive write lock is getting too old, and it has three methods that can be used to control locking:
*     `stream.heldLock()` - Returns the gridfs-locks [`Lock` object](https://github.com/vsivsi/gridfs-locks#lock) held by the stream
*     `stream.renewLock([callback])` - Renews the held lock for another expiration interval
*     `stream.releaseLock([callback])` - Releases the held lock if you are done with the stream.

You probably won't need these, but it's good to know they're there. The values used for the locking parameters are set when the `FileCollection` is created via the `options.locks` option.

When the write stream has closed, the `callback` is called as `callback(error, file)`, where file is the gridFS file document following the write.

### fc.exportFile(selector, filePath, callback)
#### Export a file collection file to the local fileSystem. - Server only

```javascript
// Write a file to wherever it belongs in the filesystem
fc.exportFile({ 'filename': 'nyancat.flv'},
              '/dev/null',
              function(err) {
                // Deal with it
              });
```

`fc.exportFile()` is a convenience method that [pipes](http://nodejs.org/api/stream.html#stream_readable_pipe_destination_options) the readable stream produced by `fc.findOneStream()` into a local [file system writable stream](http://nodejs.org/api/fs.html#fs_fs_createwritestream_path_options).

The `selector` parameter works as it does with `fc.findOneStream()`. The `filePath` is the String directory path and filename in the local filesystem to write the file data to. The value of the `filename` attribute in the found gridFS file document is ignored. The callback is mandatory and will be called with a single parameter that will be either an `Error` object or `null` depending on the success of the operation.

### fc.importFile(filePath, file, callback)
#### Import a local filesystem file into a file collection file. - Server only

```javascript
// Read a file into the collection from the filesystem
fc.importFile('/funtimes/lolcat_183.gif',
              { filename: 'lolcat_183.gif',
                contentType: 'image/gif'
              },
              function(err, file) {
                // Deal with it
                // Or file contains all of the details.
              });
```

`fc.importFile()` is a convenience method that [pipes](http://nodejs.org/api/stream.html#stream_readable_pipe_destination_options) a local [file system readable stream](http://nodejs.org/api/fs.html#fs_fs_createreadstream_path_options) into the writable stream produced by a call to `fc.upsertStream()`.

The `file` parameter works as it does with `fc.upsertStream()`. The `filePath` is the String directory path and filename in the local filesystem of the file to open and copy into the gridFS file. The callback is mandatory and will be called with the same callback signature as `fc.upsertStream()`.
