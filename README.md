# fileCollection

fileCollection is a [Meteor.js](https://www.meteor.com/) [package](https://atmospherejs.com/package/collectionFS) that cleanly extends Meteor's `Collection` metaphor for efficiently dealing with collections of files and their data. File Collections are fully reactive, so if you know how to use Meteor [Collections](http://docs.meteor.com/#collections), you already know most of what you need to begin working with fileCollection.

```js
myFiles = new FileCollection('myFiles');

// Find a file document by name

thatFile = myFiles.findOne({ filename: 'lolcat.gif' });

// or get a file's data as a stream

thatFileStream = myFiles.findOneStream({ filename: 'lolcat.gif' });

// Write the file data someplace...
```

### Feature summary

Under the hood, file data is stored entirely within the Meteor MongoDB instance using a Mongo technology called [gridFS](http://docs.mongodb.org/manual/reference/gridfs/). Your fileCollection and the underlying gridFS collection remain perfectly in sync because they *are* the same collection; and fileCollection is automatically safe for concurrent read/write access to files via [MongoDB based locking](https://github.com/vsivsi/gridfs-locks). fileCollection also provides a simple way to enable secure HTTP (GET, POST, PUT, DELETE) interfaces to your files, and additionally has built-in support for robust and resumable file uploads using the excellent [Resumable.js](http://www.resumablejs.com/) library.

### Design philosophy

My goal in writing this package was to stay true to the spirit of Meteor and build something that can be made efficient, secure and to "just work" with a minimum of fuss.

If you've been searching for ways to deal with file data on Meteor, you've probably also encountered [collectionFS](https://atmospherejs.com/package/collectionFS). If not, you should definitely check it out. It's a great set of packages written by smart people, and I even pitched in to help with a rewrite of their [gridFS support](https://atmospherejs.com/package/cfs-gridfs).

Here's the difference in a nutshell: collectionFS is a Ferrari, and fileCollection is a Fiat.

They do approximately the same thing using some of the same technologies, but reflect different design priorities. fileCollection is much simpler and somewhat less flexible; but if it meets your needs you'll find it has a lot fewer moving parts and may be significantly more efficient to work with and use.

If you're trying to quickly prototype an idea or you know that you just need a straightforward way of dealing with files, you should definitely try fileCollection.

However, if you find your project needs all of the bells and whistles that collectionFS offers, then you'll have your answer.

## Example

Enough words, time for some more code...

The block below implements a `FileCollection` on server, including support for owner-secured HTTP file upload using `Resumable.js` and HTTP download. It also sets up the client to provide drag and drop chunked file uploads to the collection. The only things missing here are UI templates and some helper functions. See the `sampleApp` subdirectory for a complete working version written in [CoffeeScript](http://coffeescript.org/).

```js
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
    function () {
      return myFiles.find({ 'metadata._Resumable': { $exists: false },
                   'metadata.owner': this.userId });
    }
  );

  // Allow rules for security. Should look familiar!
  // Without these, no file writes would be allowed
  myFiles.allow({
    insert: function (userId, file) {
      // Assign the proper owner when a file is created
      file.metadata = file.metadata || {};
      file.metadata.owner = userId;
      return true;
    },
    remove: function (userId, file) {
      // Only owners can delete
      if (userId !== file.metadata.owner) {
        return false;
      } else {
        return true;
      }
    },
    read: function (userId, file) {
      // Only owners can retrieve a file via HTTP GET/HEAD
      if (userId !== file.metadata.owner) {
        return false;
      } else {
        return true;
      }
    },
    // This rule secures the HTTP REST interfaces' PUT/POST
    write: function (userId, file, fields) {
      // Only owners can upload file data
      if (userId !== file.metadata.owner) {
        return false;
      } else {
        return true;
      }
    }
  });
}

if (Meteor.isClient) {

  Meteor.subscribe('myData');

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
  });
}
```

## Installation

I've only tested with Meteor v0.8. It may run on Meteor v0.7 as well, I don't know.

Requires [meteorite](https://atmospherejs.com/docs/installing). To add to your project, run:

    mrt add fileCollection

The package exposes a global object `FileCollection` on both client and server.

If you'd like to try out the sample app, you can clone the repo from github:

```
git clone --recursive \
    https://github.com/vsivsi/meteor-file-collection.git \
    fileCollection
```

Then go to the `sampleApp` subdirectory and run meteorite to launch:

```
cd fileCollection/sampleApp/
mrt
```

You should now be able to point your browser to `http://localhost:3000/` and play with the sample app.

To run tests (using Meteor tiny-test) run from within the fileCollection subdirectory:

    meteor test-packages ./

Load `http://localhost:3000/` and the tests should run in your browser and on the server.

## Use

Below you'll find the [MongoDB gridFS `files` data model](http://docs.mongodb.org/manual/reference/gridfs/#the-files-collection). This is also the schema used by fileCollection because fileCollection *is* gridFS.

```js
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
*    For this reason, `_id`, `length`, `chunkSize`, `uploadDate` and `md5` are read-only in fileCollection.
*    Some of the attributes belong to you. Your application can do whatever you want with them.
*    `filename`, `contentType`, `aliases` and `metadata` are yours. Go to town.
*    `contentType` should probably be a valid [MIME Type](https://en.wikipedia.org/wiki/MIME_type)
*    `filename` is *not* guaranteed unique. `_id` is a better bet if you want to be sure of what you're getting.

Sound complicated? It really isn't and fileCollection is here to help.

First off, when you create a new file you use `myFiles.insert(...)` and just populate whatever attributes you care about. Then fileCollection does the rest. You are guaranteed to get a valid gridFS file, even if you just do this: `id = myFiles.insert();`

Likewise, when you run `myFiles.update(...)` on the server, fileCollection tries really hard to make sure that you aren't clobbering one of the "read-only" attributes with your update modifier. For safety, clients are never allowed to directly `update`, although you can selectively give them that power via `Meteor.methods()`.

### Limits and performance

There are essentially no hard limits on the number or size of files other than what your hardware will support.

At no point in normal operation is a file-sized data buffer ever in memory. All of the file data import/export mechanisms are [stream based](http://nodejs.org/api/stream.html#stream_stream), so even very active servers should not see much memory dedicated to file transfers.

File data is never copied within a collection. During chunked file uploading, file chunk references are changed, but the data itself is never copied. This makes fileCollection particularly efficient when handling multi-gigabyte files.

fileCollection uses robust multiple reader / exclusive writer file locking on top of gridFS, so essentially any number of readers and writers of shared files may peacefully coexist without risk of file corruption. Note that if you have other applications reading/writing directly to a gridFS collection (e.g. a node.js program, not using Meteor/fileCollection), it will need to use the [`gridfs-locks`](https://www.npmjs.org/package/gridfs-locks) or [`gridfs-locking-stream`](https://www.npmjs.org/package/gridfs-locking-stream) npm packages to safely inter-operate with fileCollection.

### Security

You may have noticed that the gridFS `files` data model says nothing about file ownership. That's your job. If you look again at the example code block above, you will see a bare bones `Meteor.userId` based ownership scheme implemented with the attribute `file.metadata.owner`. As with any Meteor Collection, allow/deny rules are needed to enforce and defend that document attribute, and fileCollection implements that in *almost* the same way that ordinary Meteor Collections do. Here's how they're a little different:

*    A file is always initially created as a valid zero-length gridFS file using `insert` on the client/server. When it takes place on the client, the `insert` allow/deny rules apply.
*    The `remove` allow/deny rules work just as you would expect for client calls, and they also secure the HTTP DELETE method when it's used.
*    The `read` allow/deny rules secure access to file data requested via HTTP GET. These rules have no effect on client `file()` or `findOne()` methods; these operations are secured by `Meteor.publish()` as with any meteor collection.
*    The `write` allow/deny rules secure writing file *data* to a previously inserted file via HTTP methods. This means that an HTTP POST/PUT cannot create a new file by itself. It needs to have been inserted first, and only then can data be added to it using HTTP.
*    There are no `update` allow/deny rules because clients are always prohibited from directly updating a file document's attributes.
*    All HTTP methods are disabled by default. When enabled, they can be authenticated to a Meteor `userId` by using a currently valid authentication token passed either in the HTTP request header or as an URL query parameter.

## API

The `FileCollection` API is essentially an extension of the [Meteor Collection API](http://docs.meteor.com/#collections), with almost all of the same methods and a few new file specific ones mixed in.

The big loser is `upsert()`, it's gone in `FileCollection`. If you try to call it, you'll get an error. `update()` is also disabled on the client side, but it can be safely used on the server to implement `Meteor.Method()` calls for clients to use.

### fc = new FileCollection([name], [options])
#### Create a new `FileCollection` object - Server and Client

```js

// create a new FileCollection with all default values

fc = new FileCollection('fs',  // base name of collection
  { resumable: false,          // Disable resumable.js upload support
    chunkSize: 2*1024*1024,    // Use 2MB chunks for gridFS and resumable
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

**Deprecation notice:** Through version 0.1.14, the global `FileCollection` object was called `fileCollection` (with lowercase "f"). This will still work through version v0.2.0, after which it will be removed.

**Note:** The same `FileCollection` call should be made on both the client and server.

`name` is the root name of the underlying MongoDB gridFS collection. If omitted, it defaults to `'fs'`, the default gridFS collection name. Internally, three collections are used for each `FileCollection` instance:

*     `[name].files` - This is the collection you actually see when using fileCollection
*     `[name].chunks` - This collection contains the actual file data chunks. It is managed automatically.
*     `[name].locks` - This collection is used by `gridfs-locks` to make concurrent reading/writing safe.

`FileCollection` is a subclass of `Meteor.Collection`, however it doesn't support the same `[options]`.
Meteor Collections support `connection`, `idGeneration` and `transform` options. Currently, fileCollection only supports the default Meteor server connection, although this may change in the future. All `_id` values used by `FileCollection` are MongoDB style IDs. The Meteor Collection transform functionality is unsupported in `FileCollection`.

Here are the options `FileCollection` does support:

*    `options.resumable` - `<boolean>`  When `true`, exposes the [Resumable.js API](http://www.resumablejs.com/) on the client and the matching resumable HTTP support on the server.
*    `options.chunkSize` - `<integer>`  Sets the gridFS and Resumable.js chunkSize in bytes. Values of 1 MB or greater are probably best with a maximum of 8 MB. Partial chunks are not padded, so there is no storage space benefit to using smaller chunk sizes.
*    `options.baseURL` - `<string>`  Sets the base route for all HTTP interfaces defined on this collection. Default value is `/gridfs/[name]`
*    `options.locks` - `<object>`  Locking parameters, the defaults should be fine and you shouldn't need to set this, but see the `gridfs-locks` [`LockCollection` docs](https://github.com/vsivsi/gridfs-locks#lockcollectiondb-options) for more information.
*    `option.http` - <array of objects>  HTTP interface configuration objects, described below:

#### Configuring HTTP methods

Each object in the `option.http` array defines one HTTP request interface on the server, and has these three attributes:

*    `obj.method` - `<string>`  The HTTP request method to define, one of `get`, `post`, `put`, or `delete`.
*    `obj.path` - `<string>`  An [express.js style](http://expressjs.com/4x/api.html#req.params) route path with parameters.  This path will be added to the path specified by `options.baseURL`.
*    `obj.lookup` - `<function>`  A function that is called when an HTTP request matches the `method` and `path`. It is provided with the values of the route parameters and any URL query parameters, and it should return a mongoDB query object which can be used to find a file that matches those parameters.

When arranging http interface definition objects in the array provided to `options.http`, be sure to put more specific paths for a given HTTP method before more general ones. For example: `\hash\:md5` should come before `\:filename\:_id` because `"hash"` would match to filename, and so `\hash\:md5` would never match if it came second. Obviously this is a contrived example to demonstrate that order is significant.

Note that an authenticated userId is not provided to the `lookup` function. UserId based permissions should be managed using the allow/deny rules described later on.

Here are some example HTTP interface definition objects to get you started:

```js
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

// GET a file based on a query type and numeric coordinates metadata
{ method: 'get',
  path:   '/tile/:z/:x/:y',
  lookup: function (params, query) {
    return { "metadata.x": parseInt(params.x), // Note that all params
             "metadata.y": parseInt(params.y), // (execept _id) are strings
             "metadata.z": parseInt(params.z),
             contentType: query.type} }}
```

Authentication of HTTP requests is performed using Meteor login tokens. When Meteor [Accounts](http://docs.meteor.com/#accounts_api) are used in an application, a logged in client can see its current token using `Accounts._storedLoginToken()`. Tokens are passed in HTTP requests using either the HTTP header `X-Auth-Token: [token]` or in a specific URL query parameter `?X-Auth-Token=[token]`. If the token matches a valid logged in user, then that userId will be provided to any allow/deny rules that are called for permission for an action.

For clients that aren't humans logged-in using browsers, it is possible to authenticate with Meteor using the DDP protocol and programmatically obtain a token. See the [ddp-login](https://www.npmjs.org/package/ddp-login) npm package for a node.js library and command-line utility capable of logging into Meteor (similar libraries also exist for other languages such as Python).

URLs used to HTTP GET file data within a browser can be configured to automatically trigger a "File SaveAs..." download by using the `?download=true` query in the request URL. Similarly, if the `?filename=[filename.ext]` query is used, a "File SaveAs..." download will be invoked, but using the specified filename as the defaul, rather than the GridFS `filename` as is the case with `?download=true`.

HTTP PUT requests write the data from the request body directly into the file. By contrast, HTTP POST requests assume that the body is formatted as MIME multipart/form-data (as an old-school browser form based file upload would generate), and the data written to the file is taken from the part named `"file"`.  Below are example [cURL](`https://en.wikipedia.org/wiki/CURL#cURL`) commands that successfully invoke each of the four possible HTTP methods.

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
     -H 'X-Auth-Token: zrtrotHrDzwA4nC5'

# POST with file in multipart/form-data
curl -X POST 'http://127.0.0.1:3000/gridfs/fs/38a14c8fef2d6cef53c70792' \
     -F 'file=@"lolcat.gif";type=image/gif' -H 'X-Auth-Token: zrtrotHrDzwA4nC5'

# PUT with file in request body
curl -X PUT 'http://127.0.0.1:3000/gridfs/fs/38a14c8fef2d6cef53c70792' \
     -H 'Content-Type: image/gif' -H 'X-Auth-Token: zrtrotHrDzwA4nC5' \
     -T "lolcat.gif"

# DELETE the file
curl -X DELETE 'http://127.0.0.1:3000/gridfs/fs/38a14c8fef2d6cef53c70792' \
     -H 'X-Auth-Token: zrtrotHrDzwA4nC5'
```

Below are the methods defined on the returned `FileCollection` object

### fc.resumable
#### Resumable.js API object - Client only

```js
fc.resumable.assignDrop($(".fileDrop"));  // Assign a file drop target

// When a file is dropped on the target (or added some other way)
myData.resumable.on('fileAdded', function (file) {
  // file contains a resumable,js file object, do something with it...
}
```

`fc.resumable` is a ready to use, preconfigured `Resumable` object that is available when a `FileCollection` is created with `options.resumable == true`. `fc.resumable` contains the results of calling `new Resumable([options])` where all of the options have been specified by fileCollection to work with its server side support. See the [Resumable.js documentation](http://www.resumablejs.com/) for more details on how to use it.

**NOTE:** when using Resumable.js to perform file uploads, it is normal to see 404 errors in the client console that look something like:
```
Failed to load resource: the server responded with a status of 404 (Not Found)
http://localhost:3000/gridfs/fs/_resumable?resumableChunkNumber=1&  ...
```
This is a side-effect of Resumable.js feature called `testChunks` which is fully supported by fileCollection. You can read more about it in [this issue on GitHub](https://github.com/vsivsi/meteor-file-collection/issues/5).

### fc.find(selector, [options])
#### Find any number of files - Server and Client

```js
// Count the number of likely lolcats in collection, this is reactive
lols = fc.find({ 'contentType': 'image/gif'}).count();
```

`fc.find()` is identical to [Meteor's `Collection.find()`](http://docs.meteor.com/#find)

### fc.findOne(selector, [options])
#### Find a single file. - Server and Client

```js
// Grab the file document for a known lolcat
// This is not the file data, see fc.findOneStream() for that!
myLol = fc.findOne({ 'filename': 'lolcat.gif'});
```

`fc.findOne()` is identical to [Meteor's `Collection.findOne()`](http://docs.meteor.com/#findone)

### fc.insert([file], [callback])
#### Insert a new zero-length file. - Server and Client

```js
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

```js
// Make it go away, data and all
fc.remove(
  { filename: 'nyancat.flv' }
  // Callback here, if you want to be absolultely sure it's really gone...
);
```

`fc.remove()` is nearly the same as [Meteor's `Collection.remove()`](http://docs.meteor.com/#remove), except that in addition to removing the file document, it also removes the file data chunks and locks from the gridFS store. For safety, undefined and empty selectors (`undefined`, `null` or `{}`) are all rejected. Client calls are subjected to any `'remove'`  allow/deny rules (which default to deny all removes).

### fc.update(selector, modifier, [options], [callback])
#### Update application controlled gridFS file attributes. - Server only

```js
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
*     any gridFS document level attributes would be removed
*     non-gridFS attributes would be added

Since `fc.update()` only runs on the server, it is *not* subjected to any allow/deny rules.

### fc.allow(options)
#### Allow client insert and remove, and HTTP data updates, subject to your limitations. - Server only

**Deprecation notice:** Through version 0.1.18, HTTP GET requests were not impacted by allow/deny rules. As of v0.1.19, you may now implement `'read'` allow/deny rules that affect whether any given HTTP GET request will succeed. HTTP GET requests without any `'read'` allow/deny rules will still work until version v0.2.0, after which such requests will return error 403. To enable unrestricted HTTP GET access to files in a fileCollection:

```js
fc.allow({
  read: function (userId, file) { return true; }  // Anyone can read via HTTP GET, yay!
});
```

**Deprecation notice:** Through version 0.1.18, HTTP POST/PUT requests were controlled by `'update'` allow/deny rules. As of v0.1.19, you may now implement `'write'` allow/deny rules that operate in the same way. The use of `'update'` rules for this purpose is being deprecated to avoid confusion with `'update'` rules on Meteor Collections and to highlight that these rules apply to HTTP interfaces only. HTTP POST/PUT requests will continue to work with `'update'` allow/deny rules until version v0.2.0, after which such requests will return error 403. To enable unrestricted HTTP POST/PUT access to files in a fileCollection:

```js
fc.allow({
  write: function (userId, file, fields) { return true; }  // Anyone can write a file via HTTP, yay!
});
```

`fc.allow(options)` is essentially the same as [Meteor's `Collection.allow()`](http://docs.meteor.com/#allow), except that the Meteor Collection `fetch` and `transform` options are not supported by `FileCollection`.

`insert` rules are essentially the same as for ordinary Meteor collections.

`remove` rules also apply to HTTP DELETE requests.

In addition to Meteor's `insert` and `remove` rules, fileCollection also uses `read` and `write` rules. These are used to secure access to file data via HTTP GET and POST/PUT requests, respectively.

`write` rules are analogous to `update` rules on Meteor collections, except that they apply only to HTTP PUT/POST requests modifying file data, and will only see changes to the `length` and `md5` fields (in the `fieldnames` parameter) for that reason. Because MongoDB updates are not directly involved, no `modifier` is provided to the `write` function.

`read` rules apply only to HTTP GET/HEAD requests retrieving file data, and have the same parameters and `insert` and `remove` rules.


### fc.deny(options)
#### Override allow rules. - Server only

```js
fc.deny({
  remove: function (userId, file) { return true; }  // Nobody can remove, boo!
});
```

`fc.deny(options)` is the same as [Meteor's `Collection.deny()`](http://docs.meteor.com/#deny), except that the Meteor Collection `fetch` and `transform` options are not supported by `FileCollection`. See `fc.allow()` above for more deatils.

### fc.findOneStream(selector, [options], [callback])
#### Find a fileCollection file and return a readable stream for its data. - Server only

```js
// Get a readable data stream for a known lolcat
lolStream = fc.findOneStream({ 'filename': 'lolcat.gif'});
```

`fc.findOneStream()` is like `fc.findOne()` except instead of returning the `files` document for the found file, it returns a [Readable stream](http://nodejs.org/api/stream.html#stream_class_stream_readable) for the found file's data.

The only available options are `options.sort` and `options.skip` which have the same behavior as they do for Meteor's [`Collection.findOne()`](http://docs.meteor.com/#findone).

The returned stream is a gridfs-locking-stream `readStream`, which has some [special methods and events it emits](https://github.com/vsivsi/gridfs-locking-stream#locking-options). You probably won't need to use these, but the stream will emit `'expires-soon'` and `'expired'` events if its read lock is getting too old, and it has three methods that can be used to control locking:
*     `stream.heldLock()` - Returns the gridfs-locks [`Lock` object](https://github.com/vsivsi/gridfs-locks#lock) held by the stream
*     `stream.renewLock([callback])` - Renews the held lock for another expiration interval
*     `stream.releaseLock([callback])` - Releases the held lock if you are done with the stream.

This last call, `stream.releaseLock()` may be useful if you use `file.findOneStream()` and then do not read the file to the end (which would cause the lock to release automatically).  In this case, calling `stream.releaseLock()` is nice because it frees the lock before the expiration time is up. This would probably only matter for applications with lots of writers and readers contending for the same files, but it's good to know it exists. The values used for the locking parameters are set when the fileCollection is created via the `options.locks` option.

When the stream has ended, the `callback` is called with the gridFS file document.

### fc.upsertStream(file, [options], [callback])
#### Create/update a fileCollection file and return a writable stream to its data. - Server only

```js
// Get a writeable data stream to re-store all that is right and good
nyanStream = fc.upsertStream({ filename: 'nyancat.flv',
                               contentType: 'video/x-flv',
                               metadata: { caption: 'Not again!'}
                             });
```

`fc.upsertStream()` is a little bit like Meteor's `Collection.upsert()` only really not... If the `file` parameter contains an `_id` field, then the call will work on the file with that `_id`. If a file with that `_id` doesn't exist, or if no `_id` is provided, then a new file is `insert`ed into the fileCollection. Any application owned gridFS attributes (`filename`, `contentType`, `aliases`, `metadata`) that are present in the `file` parameter will be used for the file, whether it is being inserted, or updated.

Once that is done, `fc.upsertStream()` returns a [writable stream](http://nodejs.org/api/stream.html#stream_class_stream_writable) for the file.

The only available option is `options.mode` which has two valid values:
*     `options.mode = 'w'` - Default. Overwrite the existing file data if any.
*     `options.mode = 'w+'` - Append any written data to the existing file data if any.

The returned stream is a gridfs-locking-stream `writeStream`, which has some [special methods and events it emits](https://github.com/vsivsi/gridfs-locking-stream#locking-options). You probably won't need to use these, but the stream will emit `'expires-soon'` and `'expired'` events if its exclusive write lock is getting too old, and it has three methods that can be used to control locking:
*     `stream.heldLock()` - Returns the gridfs-locks [`Lock` object](https://github.com/vsivsi/gridfs-locks#lock) held by the stream
*     `stream.renewLock([callback])` - Renews the held lock for another expiration interval
*     `stream.releaseLock([callback])` - Releases the held lock if you are done with the stream.

You probably won't need these, but it's good to know they're there. The values used for the locking parameters are set when the fileCollection is created via the `options.locks` option.

When the write stream has closed, the `callback` is called as `callback(error, file)`, where file is the gridFS file document following the write.

### fc.exportFile(selector, filePath, callback)
#### Export a fileCollection file to the local fileSystem. - Server only

```js
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
#### Import a local filesystem file into a fileCollection file. - Server only

```js
// Write a file to wherever it belongs in the filesystem
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
