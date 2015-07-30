/***************************************************************************
###     Copyright (C) 2014-2015 by Vaughn Iverson
###     fileCollection is free software released under the MIT/X11 license.
###     See included LICENSE file for details.
***************************************************************************/

var currentVersion = '1.3.0';

Package.describe({
  summary: 'Collections that efficiently store files using MongoDB GridFS, with built-in HTTP support',
  name: 'vsivsi:file-collection',
  version: currentVersion,
  git: 'https://github.com/vsivsi/meteor-file-collection.git'
});

Npm.depends({
  mongodb: '2.0.39',
  'gridfs-locking-stream': '1.0.5',
  'gridfs-locks': '1.3.4',
  dicer: '0.2.4',
  async: '1.3.0',
  express: '4.13.1',
  'cookie-parser': '1.3.5',
  // Version 2.x of through2 is Streams3, so don't go there yet!
  through2: '0.6.5',
  'js-git': '0.7.7',
  'git-blob-stream': '0.0.1'
});

Package.onUse(function(api) {
  api.use('coffeescript@1.0.6', ['server','client']);
  api.use('webapp@1.2.0', 'server');
  api.use('mongo@1.1.0', ['server', 'client']);
  api.use('minimongo@1.0.8', 'server');
  api.use('meteorhacks:async@1.0.0', 'server');
  api.addFiles('resumable/resumable.js', 'client');
  api.addFiles('src/gridFS.coffee', ['server','client']);
  api.addFiles('src/server_shared.coffee', 'server');
  api.addFiles('src/gridFS_server.coffee', 'server');
  api.addFiles('src/resumable_server.coffee', 'server');
  api.addFiles('src/http_access_server.coffee', 'server');
  api.addFiles('src/resumable_client.coffee', 'client');
  api.addFiles('src/gridFS_client.coffee', 'client');
  api.addFiles('src/git.coffee', 'server');
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
