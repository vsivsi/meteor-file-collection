############################################################################
###     Copyright (C) 2014 by Vaughn Iverson
###     fileCollection is free software released under the MIT/X11 license.
###     See included LICENSE file for details.
############################################################################

if Meteor.isClient

   share.setup_resumable = () ->
      r = new Resumable
         target: "#{@baseURL}/_resumable"
         generateUniqueIdentifier: (file) -> "#{new Meteor.Collection.ObjectID()}"
         fileParameterName: 'file'
         chunkSize: @chunkSize
         testChunks: true
         simultaneousUploads: 3
         maxFiles: undefined
         maxFilesErrorCallback: undefined
         prioritizeFirstAndLastChunk: false
         query: undefined
         headers: {}

      unless r.support
         console.error "resumable.js not supported by this Browser, uploads will be disabled"
         @resumable = null
      else
         # Autoupdate the token depending on who is logged in
         Deps.autorun () =>
            Meteor.userId()
            r.opts.headers['X-Auth-Token'] = Accounts._storedLoginToken() ? ''
         @resumable = r