bbdb = exports

#Represents a connection to the database that powers bubble bot
bbdb.BBDatabase = class BBDatabase
    #given the type and optionally the parent id, returns a list of
    #ids of all objects that have this type
    list_objects: (type, parent) ->

    #Given an object, returns the property with the given name
    get_property: (type, id, name) ->

    #Given an object, returns all the properties for that object.
    get_properties: (type, id) ->

    #Given an object, sets the property with the given name
    set_property: (type, id, name, value) ->

