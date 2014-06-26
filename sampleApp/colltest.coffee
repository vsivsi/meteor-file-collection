############################################################################
#     Copyright (C) 2014 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

# Both client and server

# Default collection name is 'fs'
myData = FileCollection({
   resumable: true,     # Enable the resumable.js compatible chunked file upload interface
   http: [ { method: 'get', path: '/:md5', lookup: (params, query) -> return { md5: params.md5 }}]}
   # Define a GET API that uses the md5 sum id files
)

############################################################
# Client-only code
############################################################

if Meteor.isClient

   Meteor.subscribe 'allData'

   Meteor.startup () ->

      # Set up an autorun to keep the X-Auth-Token cookie up-to-date
      Deps.autorun () ->
         Meteor.userId()
         token = Accounts._storedLoginToken()
         $.cookie 'X-Auth-Token', token

      ################################
      # Setup resumable.js in the UI

      # This assigns a file drop zone to the "file table"
      myData.resumable.assignDrop $(".fileDrop")

      # When a file is added
      myData.resumable.on 'fileAdded', (file) ->
         # Keep track of its progress reactivaly in a session variable
         Session.set file.uniqueIdentifier, 0
         # Create a new file in the file collection to upload to
         myData.insert({
               _id: file.uniqueIdentifier    # This is the ID resumable will use
               filename: file.fileName
               contentType: file.file.type
            },
            (err, _id) ->
               if err
                  console.warn "File creation failed!", err
                  return
               # Once the file exists on the server, start uploading
               myData.resumable.upload()
         )

      # Update the upload progress session variable
      myData.resumable.on 'fileProgress', (file) ->
         Session.set file.uniqueIdentifier, Math.floor(100*file.progress())

      # Finish the upload progress in the session variable
      myData.resumable.on 'fileSuccess', (file) ->
         Session.set file.uniqueIdentifier, undefined

      # More robust error handling needed!
      myData.resumable.on 'fileError', (file) ->
         console.warn "Error uploading", file.uniqueIdentifier
         Session.set file.uniqueIdentifier, undefined

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

   Template.collTest.uploadStatus = () ->
      percent = Session.get "#{this._id}"
      unless percent?
         "Processing..."
      else
         "Uploading..."

   Template.collTest.formattedLength = () ->
      numeral(this.length).format('0.0b')

   Template.collTest.uploadProgress = () ->
      percent = Session.get "#{this._id}"

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
         insert: (userId, file) ->
            # Assign the proper owner when a file is created
            file.metadata = file.metadata ? {}
            file.metadata._auth =
               owner: userId
            true
         remove: (userId, file) ->
            # Only owners can delete
            if file.metadata?._auth?.owner and userId isnt file.metadata._auth.owner
               return false
            true
         read: (userId, file) ->
            # Only owners can GET file data
            if file.metadata?._auth?.owner and userId isnt file.metadata._auth.owner
               return false
            true
         write: (userId, file, fields) -> # This is for the HTTP REST interfaces PUT/POST
            # All client file metadata updates are denied, implement Methods for that...
            # Only owners can upload a file
            if file.metadata?._auth?.owner and userId isnt file.metadata._auth.owner
               return false
            true
