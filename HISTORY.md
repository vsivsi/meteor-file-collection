## Revision history

### 0.1.18

*    Allow/Deny rules are now called in the same order as in Meteor (deny rules go first).

### 0.1.17

*    Fixed another issue when calling deprecated fileCollection object without new.

### 0.1.16

*    Fixed issue when calling deprecated fileCollection object without new.

### 0.1.15

*    Added FileCollection export
*    Updated docs to use FileCollection and note that fileCollection is deprecated and will be removed in 0.2.0
*    Added deprecation warning to console.warn for fileCollection use
*    Bumped express version

### 0.1.14

*    Improved documentation. Thanks to @renarl for suggestion.
*    Updated express version.

### 0.1.13

*    Updated versions of resumable, async, mongodb, gridfs-locks, gridfs-locking-stream and express
*    Documentation improvements

### 0.1.12

*    Fixed typos in documentation. Thanks to @dawjdh

### 0.1.11

*    Fixed sample code in README.md. Thanks to @rcy

### 0.1.10

*    Fixed resumable.js upload crash

### 0.1.9

*    Fix missing filenames in resumable.js uploads caused by changes in mongodb 1.4.3
*    upsertStream now correctly updates gridFS attributes when provided

### 0.1.8

*    Updates for Meteor v0.8.1.1
*    Documentation improvements
*    Updated npm package versions

### 0.1.7

*    Bumped package versions to fix more mongodb 2.4.x backwards compatility issues

### 0.1.6

*    Bumped gridfs-locks version to fix a mongodb 2.4.x backwards compatility issue

### 0.1.0 - 0.1.5

*    Initial revision and documentation improvements.
