############################################################################
#     Copyright (C) 2014 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

# Both client and server

# Default collection name is 'fs'
myData = fileCollection({
   http: [
            method: 'get'
            path: '/:md5'
            lookup: (params, query) ->
               return { md5: params.md5 }
         ,
            method: 'post'
            path: '/dropZone'
            lookup: (params, query) ->
               console.log "POST Request!"
               id = myData.insert()  # Insert a file to find with the query
               return { _id: id }
         ]
   }
)

############################################################
# Client-only code
############################################################

if Meteor.isClient

   Meteor.subscribe 'allData'

   Dropzone.options.fileDrop = false

   Meteor.startup () ->

      console.log "Dropzone version", Dropzone.version

      ################################
      # Setup dropzone.js in the UI

      # This assigns a file drop zone to the "file table"
      dz = new Dropzone 'div#fileDrop',
         url: '/gridfs/fs/dropZone'
         addRemoveLinks: true
         previewsContainer: null
         accept: (file, done) ->
            console.log "Should I accept:", file
            myData.insert { filename: file.name }, () ->
               done()
         init: () ->
            console.log "Init Dropzone!!!!!!!!!!!!!!!!!"
            this.on 'addedFile', (file) ->
               console.log "Adding: ", file
            this.on 'removedFile', (file) ->
               console.log "Removing: ", file

   #####################
   # UI template helpers

   Template.collTest.events
      # Wire up the event to remove a file by clicking the `X`
      'click .del-file': (e, t) ->
         # Just the remove method does it all
         myData.remove {_id: this._id}

   Template.collTest.dataEntries = () ->
      # Reactively populate the table
      myData.find({})

   Template.collTest.owner = () ->
      this.metadata?._auth?.owner

   Template.collTest.id = () ->
      "#{this._id}"

   Template.collTest.link = () ->
      myData.baseURL + "/" + this.md5

   Template.collTest.isImage = () ->
      types =
         'image/jpeg': true
         'image/png': true
         'image/gif': true
         'image/tiff': true
      types[this.contentType]?

   Template.collTest.loginToken = () ->
      Meteor.userId()
      Accounts._storedLoginToken()

   Template.collTest.userId = () ->
      Meteor.userId()

############################################################
# Server-only code
############################################################

if Meteor.isServer

   Meteor.startup () ->

      # Only publish files owned by this userId, and ignore temp file chunks used by resumable
      Meteor.publish 'allData', () ->
         myData.find({ 'metadata._Resumable': { $exists: false }, 'metadata._auth.owner': this.userId })

      # Don't allow users to modify the user docs
      Meteor.users.deny({update: () -> true })

      # Allow rules for security. Without these, no writes would be allowed by default
      myData.allow
         remove: (userId, file) ->
            # Only owners can delete
            if file.metadata?._auth?.owner and userId isnt file.metadata._auth.owner
               return false
            true
         update: (userId, file, fields) -> # This is for the HTTP REST interfaces PUT/POST
            # All client file metadata updates are denied, implement Methods for that...
            # Only owners can upload a file
            if file.metadata?._auth?.owner and userId isnt file.metadata._auth.owner
               return false
            true
         insert: (userId, file) ->
            # Assign the proper owner when a file is created
            file.metadata = file.metadata ? {}
            file.metadata._auth =
               owner: userId
            true

