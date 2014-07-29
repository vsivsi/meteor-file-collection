## Revision history

### v.NEXT

* Added additional error checking when receiving a 'close' event.
* Don't automatically index the fileCollection.

### v0.2.3

* Added additional checking that `_id` values in URLs are 24-digit hex strings before attempting to make them into ObjectIds
* Bumped express.js to latest version

### v0.2.2

* Fixed #15
* Updated README for new sample apps.
* Updated Resumable.js

### v0.2.1

* Added sanity checking of input to `fc.allow()` and `fc.deny()`
* Allow options to be truly optional w/ callback in `findOneStream()` and `upsertStream()`
* Fixed reversed/broken sort/skip options on `findOneStream()`
* Fixed an issue where `ObjectID`s in file metadata change type after `upsertStream()`
* Updated resumable.js
* Documentation improvements.

### v0.2.0

* `fc.allow` and `fc.deny` now support rules for the `'read'` operation, which secures HTTP GET/HEAD requests.
* `fc.allow` and `fc.deny` now support rules for the `'write'` operation, which impacts HTTP POST/PUT requests. `'write'` allow/deny rules are replacing the use of `'update'` rules, and work identically. The reason for the change is to avoid confusion with the `'update'` rules on Meteor collections and to better match the new `'read'` rules. `'update'` rules continue to work, but are now deprecated.
* HTTP GET requests now support the `?filename=somename.txt` query. This is similar to the `?download=true` option, except that the default filename used by the browser "Save As..." dialog is specified by the request URL.
* Added support for sending X-Auth-Token as an HTTP Cookie. This is safer than using the `?X-Auth-Token` URL query, which continues to work, but is now deprecated.
* When using the built-in Resumable.js upload support, if you create `'write'` allow/deny rules that depend on `userId` you must set an `X-Auth-Token` cookie. See the client [example code in README.md](https://github.com/vsivsi/meteor-file-collection#example) for an example of how to do this.
* Acceptance tests are now written in Coffeescript.
* Version updates for most Npm packages.
* Documentation improvements.
* The sample application has been moved to its own [GitHub repo](https://github.com/vsivsi/meteor-file-job-sample-app).
* Thanks to @elbowz for multiple feature suggestions.

### v0.1.18

* Allow/Deny rules are now called in the same order as in Meteor (deny rules go first).

### v0.1.17

* Fixed another issue when calling deprecated fileCollection object without new.

### v0.1.16

* Fixed issue when calling deprecated fileCollection object without new.

### v0.1.15

* Added FileCollection export
* Updated docs to use FileCollection and note that fileCollection is deprecated and will be removed in 0.2.0
* Added deprecation warning to console.warn for fileCollection use
* Bumped express version

### v0.1.14

* Improved documentation. Thanks to @renarl for suggestion.
* Updated express version.

### v0.1.13

* Updated versions of resumable, async, mongodb, gridfs-locks, gridfs-locking-stream and express
* Documentation improvements

### v0.1.12

* Fixed typos in documentation. Thanks to @dawjdh

### v0.1.11

* Fixed sample code in README.md. Thanks to @rcy

### v0.1.10

* Fixed resumable.js upload crash

### v0.1.9

* Fix missing filenames in resumable.js uploads caused by changes in mongodb 1.4.3
* upsertStream now correctly updates gridFS attributes when provided

### v0.1.8

* Updates for Meteor v0.8.1.1
* Documentation improvements
* Updated npm package versions

### v0.1.7

* Bumped package versions to fix more mongodb 2.4.x backwards compatility issues

### v0.1.6

* Bumped gridfs-locks version to fix a mongodb 2.4.x backwards compatility issue

### v0.1.0 - v0.1.5

* Initial revision and documentation improvements.
