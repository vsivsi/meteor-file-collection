/***************************************************************************
###     Copyright (C) 2014-2016 by Vaughn Iverson
###     fileCollection is free software released under the MIT/X11 license.
###     See included LICENSE file for details.
***************************************************************************/

var currentVersion = '1.3.7';

Package.describe({
  summary: 'Collections that efficiently store files using MongoDB GridFS, with built-in HTTP support',
  name: 'vsivsi:file-collection',
  version: currentVersion,
  git: 'https://github.com/vsivsi/meteor-file-collection.git'
});

Npm.depends({
  // latest mongodb driver is 2.2.x, but early revs, currently seems broken
  mongodb: '2.1.21',
  'gridfs-locking-stream': '1.1.1',
  'gridfs-locks': '1.3.4',
  dicer: '0.2.5',
  async: '1.5.2',
  express: '4.14.0',
  'cookie-parser': '1.4.3',
  // Version 2.x of through2 is Streams3, so don't go there yet!
  through2: '0.6.5'
});

Package.onUse(function(api) {
  api.use('coffeescript@1.11.1_4', ['server','client']);
  api.use('webapp@1.3.12', 'server');
  api.use('mongo@1.1.14', ['server', 'client']);
  api.use('minimongo@1.0.19', 'server');
  api.use('check@1.2.4', ['server', 'client']);
  // api.use('jquery@1.11.10', 'client');
  api.addFiles('resumable/resumable.js', 'client');
  api.addFiles('src/gridFS.coffee', ['server','client']);
  api.addFiles('src/server_shared.coffee', 'server');
  api.addFiles('src/gridFS_server.coffee', 'server');
  api.addFiles('src/resumable_server.coffee', 'server');
  api.addFiles('src/http_access_server.coffee', 'server');
  api.addFiles('src/resumable_client.coffee', 'client');
  api.addFiles('src/gridFS_client.coffee', 'client');
  api.export('FileCollection');
});

Package.onTest(function (api) {
  // api.use('jquery@1.11.10', 'client');
  api.use('vsivsi:file-collection@' + currentVersion, ['server', 'client']);
  api.use('coffeescript@1.11.1_4', ['server', 'client']);
  api.use('tinytest@1.0.12', ['server', 'client']);
  api.use('test-helpers@1.0.11', ['server','client']);
  api.use('http@1.2.10', ['server','client']);
  api.use('ejson@1.0.13',['server','client']);
  api.use('mongo@1.1.14', ['server', 'client']);
  api.use('check@1.2.4', ['server', 'client']);
  api.use('tracker@1.1.1', 'client');
  api.addFiles('test/file_collection_tests.coffee', ['server', 'client']);
});
