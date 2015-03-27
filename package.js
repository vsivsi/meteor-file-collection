/***************************************************************************
###     Copyright (C) 2014-2015 by Vaughn Iverson
###     fileCollection is free software released under the MIT/X11 license.
###     See included LICENSE file for details.
***************************************************************************/

Package.describe({
  summary: 'Collections that efficiently store files using MongoDB GridFS, with built-in HTTP support',
  name: 'vsivsi:file-collection',
  version: '1.0.5',
  git: 'https://github.com/vsivsi/meteor-file-collection.git'
});

Npm.depends({
  mongodb: '2.0.25',
  'gridfs-locking-stream': '1.0.2',
  'gridfs-locks': '1.3.2',
  dicer: '0.2.4',
  async: '0.9.0',
  express: '4.12.3',
  'cookie-parser': '1.3.4'
});

Package.onUse(function(api) {
  api.use('coffeescript@1.0.6', ['server','client']);
  api.use('webapp@1.2.0', 'server');
  api.use('mongo@1.1.0', ['server', 'client']);
  api.addFiles('gridFS.coffee', ['server','client']);
  api.addFiles('resumable/resumable.js', 'client')
  api.addFiles('server_shared.coffee', 'server');
  api.addFiles('gridFS_server.coffee', 'server');
  api.addFiles('resumable_server.coffee', 'server');
  api.addFiles('http_access_server.coffee', 'server');
  api.addFiles('resumable_client.coffee', 'client');
  api.addFiles('gridFS_client.coffee', 'client');
  api.export('FileCollection');
});

Package.onTest(function (api) {
  api.use(['vsivsi:file-collection', 'coffeescript', 'tinytest', 'test-helpers', 'http']);
  api.addFiles('file_collection_tests.coffee', ['server', 'client']);
});
