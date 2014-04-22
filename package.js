/***************************************************************************
###     Copyright (C) 2014 by Vaughn Iverson
###     fileCollection is free software released under the MIT/X11 license.
###     See included LICENSE file for details.
***************************************************************************/

Package.describe({
  name: 'fileCollection',
  summary: "Files stored in Meteor collections, based on MongoDB's GridFS filestore"
});

Npm.depends({
  mongodb: '1.4.0',
  'gridfs-locking-stream': '0.1.2',
  'gridfs-locks': '1.0.1',
  dicer: '0.2.3',
  async: '0.7.0',
  express: '4.0.0'
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
  api.export('fileCollection');
});

Package.on_test(function (api) {
  api.use(['fileCollection', 'tinytest', 'test-helpers', 'http']);
  api.add_files('file_collection_tests.js', ['server', 'client']);
});
