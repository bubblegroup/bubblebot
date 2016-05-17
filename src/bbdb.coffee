bbdb = exports

#Represents a connection to the database that powers bubble bot
bbdb.BBDatabase = class BBDatabase extends bbobjects.Database
    constructor: ->
        bbdb = throw new Error 'not implemented'

        @endpoint = bbdb.get_endpoint()

    #given the type and optionally the parent id, returns a list of
    #ids of all objects that have this type
    list_objects: (type, parent) ->

    #Given an object, returns the property with the given name
    get_property: (type, id, name) ->

    #Given an object, returns all the properties for that object.
    get_properties: (type, id) ->

    #Given an object, sets the property with the given name
    set_property: (type, id, name, value) ->

    #Creates a new object, optionally with the given parent and initial properties
    create_object: (type, id, parent_type, parent_id, initial_properties) ->

    #Returns true if an object with this type and id exists
    exists: (type, id) ->

    #Returns the immediate parent, or if parent_type is set, searches upwards til it
    #finds an ancestor of that type.
    #
    #Returns [parent_type, parent_id], or [null, null] if not found
    find_parent: (type, id, parent_type) ->

    #Lists all immediate children.  If child_type is set, filters by child type
    #
    #Returns [[child_type, child_id], [child_type, child_id]...]
    children: (type, id, child_type) ->

    #Creates an entry in the history table
    add_history: (history_type, history_id, reference, properties) ->

    #Returns the last n_entries from the given history
    recent_history: (history_type, history_id, n_entries) ->

    #Finds entries for the given parameters
    find_entries: (history_type, history_id, reference) ->

    #Deletes entries for the given parameters
    delete_entries: (history_type, history_id, reference) ->


bbobjects = require './bbobjects'