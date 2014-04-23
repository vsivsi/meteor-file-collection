# fileCollection

`fileCollection` is a [Meteor.js](https://www.meteor.com/) smart [package](https://atmospherejs.com/package/collectionFS) that cleanly extends Meteor's `Collection` metaphor for efficiently dealing with collections of files and their data. If you know how to use Meteor's [Collections](http://docs.meteor.com/#collections), you already know 90% of what you need to begin working with `fileCollection`.

```js
files = new fileCollection('myFiles');

// Find file a document by name

thatFile = files.findOne({ filename: 'lolcat.gif' });

// or get a file's data as a stream

thatFileStream = files.findOneStream({ filename: 'lolcat.gif' });

// Write the file data someplace...
```

#### Feature summary

Under the hood, file data is stored entirely within the Meteor MongoDB instance using a Mongo technology called [gridFS](http://docs.mongodb.org/manual/reference/gridfs/). Your fileCollections and the underlying gridFS collection remain perfectly in sync because they *are* the same collection; and `fileCollection` is automatically safe for concurrent read/write access to files via [MongoDB based locking](https://github.com/vsivsi/gridfs-locks). `fileCollection` also provides a simple way to enable secure HTTP (GET, POST, PUT, DELETE) interfaces to your files, and additionally has built-in support for robust and resumable file uploads using the excellent [Resumable.js](http://www.resumablejs.com/) library.

#### Design philosophy

My goal in writing this package was to stay true to the spirit of Meteor and build something that can be made efficient, secure and to "just work" with a minimum of fuss.

If you've been searching for ways to deal with file data on Meteor, you've probably also encountered [collectionFS](https://atmospherejs.com/package/collectionFS). If not, you should definitely check it out. It's a great set of packages written by smart people, and I even pitched in to help with a rewrite of their [gridFS support](https://atmospherejs.com/package/cfs-gridfs).

Here's the difference in a nutshell: collectionFS is a Ferrari, and fileCollection is a Fiat. They do approximately the same thing, using some of the same technologies, but reflect different design priorities. `fileCollection` is much simpler and somewhat less flexible; but if it does what you need you'll probably find it has a lot fewer moving parts and may be quite a bit more efficient.

If you're trying to quickly prototype an idea, or you know that you just need a simple way of dealing with files, you should try out fileCollection. However, if you find you need all of the bells and whistles, collectionFS is probably a better fit for your project.

### Example

Enough words, time for some more code...

The block below implements a `fileCollection` on server, including support for owner-secured HTTP file upload using `Resumable.js` and HTTP download. It also sets up the client to provide drag and drop chunked file uploads to the collection. The only things missing here are UI templates and some helper functions. See the `sampleApp` subdirectory for a complete working version written in [CoffeeScript](http://coffeescript.org/).

```js
// Create a file collection, and enable file upload and download using HTTP

files = new fileCollection('myFiles',
  { resumable: true,
    http: [
      { method: 'get',
        path: '/:md5',  // this will be at route "/gridfs/myFiles/:md5"
        lookup: function (params, query) {
          return { md5: params.md5 }
      }
    ]
  }
);

if (Meteor.isServer) {

  // Only publish files owned by this userId, and ignore
  // file chunks being used by Resumable.js for current uploads
  Meteor.publish('myData',
    function () {
      files.find({ 'metadata._Resumable': { $exists: false },
                   'metadata.owner': this.userId })
    }
  );

  // Allow rules for security. Should look familiar!
  // Without these, no file writes would be allowed
  files.allow({
    remove: function (userId, file) {
      // Only owners can delete
      if (userId !== file.metadata.owner) {
        return false;
      } else {
        return true;
      }
    },
    // Client file document updates are all denied, implement Methods for that
    // This rule secures the HTTP REST interfaces' PUT/POST
    update: function (userId, file, fields) {
      // Only owners can upload file data
      if (userId !== file.metadata.owner) {
        return false;
      } else {
        return true;
      }
    },
    insert: function (userId, file) {
      // Assign the proper owner when a file is created
      file.metadata = file.metadata or {};
      file.metadata.owner = userId;
      return true;
    }
  });
}

if (Meteor.isClient) {

  Meteor.subscribe('myData');

  Meteor.startup(function() {
    // This assigns a file upload drop zone to some DOM node
    files.resumable.assignDrop($(".fileDrop"));

    // When a file is added via drag and drop
    myData.resumable.on('fileAdded', function (file) {
      // Create a new file in the file collection to upload
      files.insert({
        _id: file.uniqueIdentifier,  // This is the ID resumable will use
        filename: file.fileName,
        contentType: file.file.type
        },
        function (err, _id) {
          if (err) {
            return console.error("File creation failed!", err);
          }
          // Once the file exists on the server, start uploading
          myData.resumable.upload();
        });
    });
  });
}
```

## Installation

I've only tested with Meteor v0.8. It may run on Meteor v0.7 as well, I don't know.

Requires [meteorite](https://atmospherejs.com/docs/installing). To add to your project, run:

    mrt add fileCollection

The package exposes a global object `fileCollection` on both client and server.

To run tests (using Meteor tiny-test) run from within your project's `package` subdir:

    meteor test-packages ./fileCollection/

## Use

Before going any further, it will pay to take a minute to familiarize yourself with the [MongoDB gridFS `files` data model](http://docs.mongodb.org/manual/reference/gridfs/#the-files-collection). This is the schema used by `fileCollection` because fileCollection *is* gridFS.

Now that you've seen the data model, here are a few things to keep in mind about it:

1.    Some of the attributes belong to gridFS, and you may **lose data** if you mess around with these:
2.    `_id`, `length`, `chunkSize`, `uploadDate` and `md5` should be considered read-only.
3.    Some the attributes belong to you. You can do whatever you want with them.
4.    `filename`, `contentType`, `aliases` and `metadata` are yours. Go to town.
5.    `contentType` should probably be a valid [MIME Type](https://en.wikipedia.org/wiki/MIME_type)
6.    `filename` is *not* guaranteed unique. `_id` is a better bet if you want to be sure of what you're getting.

Sound complicated? It really isn't and `fileCollection` is here to help.

First off, when you create a new file you use `file.insert(...)` and just populate whatever attributes you care about. Then `fileCollection` does the rest. You are guaranteed to get a valid gridFS file, even if you just do this: `id = file.insert();`

Likewise, when you run `update` on the server, it tries really hard to make sure that you aren't clobbering one of the "read-only" attributes with your update modifier. And for safety clients aren't allowed to directly `update` at all, although you can selectively give them that power via `Meteor.methods()`.

### Limits and performance

There are essentially no hard limits on the number or size of files other than what your hardware will support.

At no point in normal operation is a file-sized data buffer ever in memory. All of the file data import/export mechanisms are [stream based](http://nodejs.org/api/stream.html#stream_stream), so even very active servers should not see much memory dedicated to file transfers.

File data is never copied within a collection. During chunked file uploading, file chunk reference pointers are moved, but the data itself is never copied. This makes fileCollection particularly efficient when handling multi-gigabyte files.

fileCollection uses robust multiple reader / exclusive writer file locking on top of gridFS, so essentially any number of readers and writers of shared files may peacefully coexist without risk of file corruption. Note that if you have other applications reading/writing directly to a gridFS collection (e.g. a node.js program, not using Meteor/fileCollection), it will need to use the [`gridfs-locks`](https://www.npmjs.org/package/gridfs-locks) or [`gridfs-locking-stream`](https://www.npmjs.org/package/gridfs-locking-stream) npm packages to safely interoperate with `fileCollection`.

### Security

You may have noticed that the gridFS `files` data model says nothing about file ownership. That's your job. If you look again at the example code block above, you will see a bare bones `Meteor.userId` based ownership scheme implemented with the attribute `file.metadata.owner`. As with any Meteor Collection, allow/deny rules are needed to enforce and defend that document attribute, and `fileCollection` implements that in *almost* the same way that ordinary Meteor Collections do. Here's how they're a little different:

*    A file is always initially created as a valid zero-length gridFS file using `insert` on the client/server. When it takes place on the client, the `insert` allow/deny rules apply.
*    Clients are always denied from directly updating a file document's attributes. The `update` allow/deny rules secure writing file *data* to a previously inserted file via HTTP methods. This means that an HTTP POST/PUT cannot create a new file by itself. It needs to have been inserted first, and only then can data be added to it using HTTP.
*    The `remove` allow/deny rules work just as you would expect for client calls, and they also secure the HTTP DELETE method when it's used.
*    All HTTP REST interfaces are disabled by default, and when enabled can be authenticated to a Meteor `userId` by using a currently valid authentication token.

## API

The `fileCollection` API is essentially an extension of the [Meteor Collection API](http://docs.meteor.com/#collections), with almost all of the same methods and a few file specific ones mixed in.

The big loser is `upsert()`, it's gone in collectionFS. If you try to call it, you'll get an error. `update()` is also disabled on the client side, but it can be safely used on the server to implement `Meteor.Method()` calls for clients to use.

### new fileCollection()



### file.find()

### file.findOne()

### file.insert()

### file.update()

### file.remove()

### file.allow()

### file.deny()

### file.upsertStream()

### file.findOneStream()

### file.importFile()

### file.exportFile()
