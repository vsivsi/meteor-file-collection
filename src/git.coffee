############################################################################
#     Copyright (C) 2014-2015 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isServer
   console.log "In Git source"

   gbs = Npm.require 'git-blob-stream'

   modes = Npm.require 'js-git/lib/modes'
   unwrappedRepo = {}

   Npm.require('js-git/mixins/mem-db') unwrappedRepo
   Npm.require('js-git/mixins/create-tree') unwrappedRepo
   Npm.require('js-git/mixins/pack-ops') unwrappedRepo
   Npm.require('js-git/mixins/walkers') unwrappedRepo
   Npm.require('js-git/mixins/formats') unwrappedRepo

   repoMethods = (f for f,g of unwrappedRepo when typeof g is 'function')
   console.log repoMethods
   repo = Async.wrap unwrappedRepo, repoMethods

   # blobHash = repo.saveAs 'blob', "Hello World\n"
   # console.log "Blob hash: ", blobHash

   treeHash = repo.saveAs 'tree',
     "greeting.txt":
       mode: modes.file
       hash: "327b85ca3f29975db856a0477278671456ff908b" # blobHash
   console.log "Tree hash: ", treeHash

   # commitHash = repo.saveAs 'commit',
   #   author:
   #     name: "vsivsi"
   #     email: "vsivsi@yahoo.com"
   #   tree: treeHash
   #   message: "Test commit\n"
   # console.log "Commit hash: ", commitHash
   #
   # doc = repo.loadAs 'text', blobHash
   # console.log "Doc: ", doc
