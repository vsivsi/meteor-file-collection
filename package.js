
Package.describe({
  name: 'gridfs-collection',
  summary: 'GridFS based collection'
});

Npm.depends({
  // Switch to 1.4.0 once it is out
  // mongodb: '1.4.0',
  mongodb: 'https://github.com/vsivsi/node-mongodb-native/tarball/4b59ff3b30df6a068b03cb10144f587563664bff',
  'gridfs-locking-stream': '0.1.2',
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
