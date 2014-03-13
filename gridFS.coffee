if Meteor.isServer

   mongodb = Npm.require 'mongodb'

   class gridFS extends Meteor.Collection

      _check_allow_deny: (type, userId, file) ->
         console.log "In Client '#{type}' allow: #{file.filename} {@db}"
         allowResult = false
         allowResult = allowResult or allowFunc(userId, file) for allowFunc in @allows[type]
         denyResult = true
         denyResult = denyResult and denyFunc(userId, file) for denyFunc in @denys[type]
         return allowResult and denyResult

      constructor: (@base) ->
         console.log "Making a gridFS collection!"

         @db = Meteor._wrapAsync(mongodb.MongoClient.connect)(process.env.MONGO_URL,{})

         @allows = { insert: [], update: [], remove: [] }
         @denys = { insert: [], update: [], remove: [] }

         super @base + '.files'

         gridFS.__super__.allow.bind(@)

            remove: (userId, file) =>
               if @_check_allow_deny 'remove', userId, file
                  Meteor._wrapAsync(mongodb.GridStore.unlink)(@db, file.filename, { root: @base })
                  return true

               return false

            update: (userId, file, fields) =>
               if @_check_allow_deny 'update', userId, file
                  if fields.length is 1 and fields[0] is 'metadata'
                     # Only metadata may be updated
                     return true

               return false

            insert: (userId, file) =>
               if @_check_allow_deny 'insert', userId, file
                  return true

               return true

      remove: (selector, callback) ->
         console.log "In Server REMOVE"
         @find(selector).forEach (file) ->
            Meteor._wrapAsync(mongodb.GridStore.unlink)(@db, file.filename, { root: @base })
         callback null

      allow: (allowOptions) ->
         @allows[type].push(func) for type, func of allowOptions when type of @allows
         # for type, func of allowOptions  when type of @allows
         #    console.log "Allowing #{type} #{func}"
         #    @allows[type].push(func)
         # console.log "Setting an allow function", @allows

      deny: (denyOptions) ->
         @denys[type].push(func) for type, func of denyOptions when type of @denys
         # for type, func of denyOptions  when type of @denys
         #    console.log "Denying #{type} #{func}"
         #    @denys[type].push(func)
         # console.log "Setting a deny function", @denys

if Meteor.isClient

   class gridFS extends Meteor.Collection

      constructor: (@base) ->
         console.log "Making a gridFS collection!"
         super @base + '.files'


# if typeof define is "function" and define.amd?
#    define gridFS
# else if typeof module is "object" and module.exports?
#    module.exports = gridFS
#    console.log "In module exports"
# else
#    this.gridFS = gridFS
#    console.log "In this exports"