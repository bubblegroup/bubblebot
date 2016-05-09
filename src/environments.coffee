environments = exports

#generic class for objects tracked in the bubblebot database
environments.BubblebotObject = class BubblebotObject extends bbserver.CommandTree
    constructor: (@type, @id) ->
        super()

    #Gets the given property of this object
    get: (name) -> u.db().get_property @type, @id, name

    get_cmd:
        params: [{name: 'name', required: true}]
        help_text: 'gets the given property of this object'
        reply: true

    #Sets the given property of this object
    set: (name, value) ->
        u.db().set_property @type, id, name, value

    set_cmd:
        params: [[{name: 'name', required: true}, {name: 'value', required: true}]
        help_text: 'sets the given property of this object'
        reply: 'Property successfully set'

    #returns all the properties of this object
    properties: -> u.db().get_properties @type, @id

    properties_cmd:
        help_text: 'gets all the properties for this object'
        reply: true


environments.Environment = class Environment extends BubblebotObject
    constructor: (id) -> super 'environment', id






bbserver = require './bbserver'