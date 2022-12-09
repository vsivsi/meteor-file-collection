/***************************************************************************
###     Copyright (C) 2014-2017 by Vaughn Iverson
###     fileCollection is free software released under the MIT/X11 license.
###     See included LICENSE file for details.
***************************************************************************/

const currentVersion = '2.0.0';

Package.describe({
  summary: 'Collections that efficiently store files using MongoDB GridFS, with built-in HTTP support',
  name: 'vsivsi:file-collection',
  version: currentVersion,
  git: 'https://github.com/vsivsi/meteor-file-collection.git'
});

Npm.depends({
  // latest mongodb driver is 2.2.x, but early revs, currently seems broken
  mongodb: '4.12.1',
  dicer: '0.2.5',
  async: '2.1.4',
  express: '4.14.1',
  'cookie-parser': '1.4.3',
  // Version 2.x of through2 is Streams3, so don't go there yet!
  through2: '0.6.5',
  flushwritable: '1.0.0',
  'bson-objectid': '2.0.4',
});

//https://github.com/meteor/meteor/issues/7273
Package.onUse(function(api) {
  api.use('webapp@1.3.13', 'server');
  api.use('mongo@1.1.15', ['server', 'client']);
  api.use('minimongo@1.0.20', 'server');
  api.use('check@1.2.5', ['server', 'client']);
  //This is needed for ES6 imports/exports to work
  api.use('ecmascript');
  api.addFiles('src/resumable.js', 'client');
  api.addFiles('src/gridFS.js', ['server','client']);
  api.addFiles('src/server_shared.js', 'server');
  api.addFiles('src/gridFS_server.js', 'server');
  api.addFiles('src/resumable_server.js', 'server');
  api.addFiles('src/http_access_server.js', 'server');
  api.addFiles('src/resumable_client.js', 'client');
  api.addFiles('src/gridFS_client.js', 'client');
  api.addFiles('src/gridfs-locking-stream.js', 'server');
  api.addFiles('src/gridfs-locks.js', 'server');
  api.addFiles('src/gridfs-stream.js', 'server');
  api.addFiles('src/readstream.js', 'server');
  api.addFiles('src/writestream.js', 'server');

  api.mainModule('src/exports.js');
  //api.export('FileCollection');
});

Package.onTest(function (api) {
  api.use('vsivsi:file-collection@' + currentVersion, ['server', 'client']);
  api.use('tinytest@1.0.12', ['server', 'client']);
  api.use('test-helpers@1.0.11', ['server','client']);
  api.use('http@1.2.11', ['server','client']);
  api.use('ejson@1.0.13',['server','client']);
  api.use('mongo@1.1.15', ['server', 'client']);
  api.use('check@1.2.5', ['server', 'client']);
  api.use('tracker@1.1.2', 'client');
  api.addFiles('test/file_collection_tests.js', ['server', 'client']);
});
