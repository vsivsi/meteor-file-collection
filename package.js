/***************************************************************************
###     Copyright (C) 2014-2015 by Vaughn Iverson
###     fileCollection is free software released under the MIT/X11 license.
###     See included LICENSE file for details.
***************************************************************************/

var currentVersion = '1.1.2';

Package.describe({
  summary: 'Collections that efficiently store files using MongoDB GridFS, with built-in HTTP support',
  name: 'vsivsi:file-collection',
  version: currentVersion,
  git: 'https://github.com/vsivsi/meteor-file-collection.git'
});

Npm.depends({
  mongodb: '2.0.33',
  'gridfs-locking-stream': '1.0.4',
  'gridfs-locks': '1.3.3',
  dicer: '0.2.4',
  async: '1.2.0',
  express: '4.12.4',
  'cookie-parser': '1.3.5',
  through2: '0.6.5'
});

Package.onUse(function(api) {
  api.use('coffeescript@1.0.6', ['server','client']);
  api.use('webapp@1.2.0', 'server');
  api.use('mongo@1.1.0', ['server', 'client']);
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
  api.use('vsivsi:file-collection@' + currentVersion, ['server', 'client']);
  api.use('coffeescript@1.0.6', ['server', 'client']);
  api.use('tinytest@1.0.5', ['server', 'client']);
  api.use('test-helpers@1.0.4', ['server','client']);
  api.use('http@1.1.0', ['server','client']);
  api.addFiles('test/file_collection_tests.coffee', ['server', 'client']);
});
