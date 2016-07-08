############################################################################
#     Copyright (C) 2014-2016 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isClient

   # This is a polyfill for bind(), added to make phantomjs 1.9.7 work
   unless Function.prototype.bind
      Function.prototype.bind = (oThis) ->
         if typeof this isnt "function"
            # closest thing possible to the ECMAScript 5 internal IsCallable function
            throw new TypeError("Function.prototype.bind - what is trying to be bound is not callable")

         aArgs = Array.prototype.slice.call arguments, 1
         fToBind = this
         fNOP = () ->
         fBound = () ->
            func = if (this instanceof fNOP and oThis) then this else oThis
            return fToBind.apply(func, aArgs.concat(Array.prototype.slice.call(arguments)))

         fNOP.prototype = this.prototype

         fBound.prototype = new fNOP()
         return fBound

   share.setup_resumable = () ->
      url = "#{@baseURL}#{share.resumableBase}"
      url = Meteor.absoluteUrl(url.replace /^\//, '') if Meteor.isCordova
      r = new Resumable
         target: url
         generateUniqueIdentifier: (file) -> "#{new Mongo.ObjectID()}"
         fileParameterName: 'file'
         chunkSize: @chunkSize
         testChunks: true
         testMethod: 'HEAD'
         permanentErrors: [204, 404, 415, 500, 501]
         simultaneousUploads: 3
         maxFiles: undefined
         maxFilesErrorCallback: undefined
         prioritizeFirstAndLastChunk: false
         query: undefined
         headers: {}
         maxChunkRetries: 5
         withCredentials: true

      unless r.support
         console.warn "resumable.js not supported by this Browser, uploads will be disabled"
         @resumable = null
      else
         @resumable = r
