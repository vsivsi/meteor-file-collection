/***************************************************************************
###     Copyright (C) 2014 by Vaughn Iverson
###     fileCollection is free software released under the MIT/X11 license.
###     See included LICENSE file for details.
***************************************************************************/

Package.describe({
  name: 'filecollection',
  summary: "Files stored in Meteor collections, based on MongoDB's GridFS filestore",
  git: "https://github.com/vsivsi/meteor-file-collection.git"
});

Npm.depends({
  mongodb: '1.4.7',
  'gridfs-locking-stream': '0.2.2',
  'gridfs-locks': '1.2.1',
  dicer: '0.2.3',
  async: '0.9.0',
  express: '4.6.1',
  'cookie-parser': '1.3.2'
});

Package.onUse(function(api) {
  api.versionsFrom('METEOR@0.9.0');

  api.use('coffeescript', ['server','client']);
  api.use('webapp', 'server');
  api.addFiles('gridFS.coffee', ['server','client']);
  api.addFiles('resumable/resumable.js', 'client')
  api.addFiles('server_shared.coffee', 'server');
  api.addFiles('gridFS_server.coffee', 'server');
  api.addFiles('resumable_server.coffee', 'server');
  api.addFiles('http_access_server.coffee', 'server');
  api.addFiles('resumable_client.coffee', 'client');
  api.addFiles('gridFS_client.coffee', 'client');
  api.export('FileCollection');
  api.export('fileCollection');
});

Package.onTest(function (api) {
  api.use(['fileCollection', 'coffeescript', 'tinytest', 'test-helpers', 'http']);
  api.addFiles('file_collection_tests.coffee', ['server', 'client']);
});
