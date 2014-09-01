/***************************************************************************
###     Copyright (C) 2014 by Vaughn Iverson
###     fileCollection is free software released under the MIT/X11 license.
###     See included LICENSE file for details.
***************************************************************************/

Package.describe({
  summary: 'Collections that efficiently store files using MongoDB GridFS, with built-in HTTP down/upload support',
  name: 'vsivsi:file-collection',
  version: '0.3.0',
  git: 'https://github.com/vsivsi/meteor-file-collection.git'
});

Npm.depends({
  mongodb: '1.4.9',
  'gridfs-locking-stream': '0.2.2',
  'gridfs-locks': '1.2.1',
  dicer: '0.2.3',
  async: '0.9.0',
  express: '4.8.7',
  'cookie-parser': '1.3.2'
});

Package.on_use(function(api) {
  api.use('coffeescript', ['server','client']);
  api.use('webapp', 'server');
  api.add_files('gridFS.coffee', ['server','client']);
  api.add_files('resumable/resumable.js', 'client')
  api.add_files('server_shared.coffee', 'server');
  api.add_files('gridFS_server.coffee', 'server');
  api.add_files('resumable_server.coffee', 'server');
  api.add_files('http_access_server.coffee', 'server');
  api.add_files('resumable_client.coffee', 'client');
  api.add_files('gridFS_client.coffee', 'client');
  api.export('FileCollection');
  api.export('fileCollection');
});

Package.on_test(function (api) {
  api.use(['vsivsi:file-collection', 'coffeescript', 'tinytest', 'test-helpers', 'http']);
  api.add_files('file_collection_tests.coffee', ['server', 'client']);
});
