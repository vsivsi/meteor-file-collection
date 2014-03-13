
Package.describe({
  name: 'gridfs-collection',
  summary: 'GridFS based collection'
});

Npm.depends({
  mongodb: '1.3.23',
  'gridfs-stream': '0.4.1'
});

Package.on_use(function(api) {
  api.use(['coffeescript']);
  api.add_files('gridFS.coffee', ['server','client']);
  api.export('gridFS');
});

// Package.on_test(function(api) {
// });
