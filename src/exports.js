import {Meteor} from 'meteor/meteor';


let FileCollection;

if (Meteor.isServer) {
    import('./gridFS_server').then(lib => FileCollection = lib.FileCollection);
} else {
    import('./gridFS_client').then(lib => FileCollection = lib.FileCollection);
}

export {FileCollection};

