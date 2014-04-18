
Package.describe({
  name: 'gridfs-collection',
  summary: 'GridFS based collection'
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
  api.add_files('resumable_server.coffee', 'server');
  api.add_files('gridFS_server.coffee', 'server');
  api.add_files('resumable_client.coffee', 'client');
  api.add_files('gridFS_client.coffee', 'client');
  api.export('gridFSCollection');
});

// Package.on_test(function(api) {
// });
