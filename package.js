
Package.describe({
  name: 'gridfs-collection',
  summary: 'GridFS based collection'
});

Npm.depends({
  mongodb: '1.4.0',
  'gridfs-locking-stream': '0.1.2',
  'gridfs-locks': '1.0.1',
  dicer: '0.2.3'
});

Package.on_use(function(api) {
  api.use('coffeescript', ['server','client']);
  api.use('webapp', 'server');
  api.add_files('gridFS.coffee', ['server','client']);
  api.export('gridFS');
});

// Package.on_test(function(api) {
// });
