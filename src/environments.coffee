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


#Represents a database
environments.Database = class Database extends BubblebotObject
    constructor: (id) -> super 'environment', id

    #Runs any outstanding migrations from this template on the database
    fully_apply: (template) ->
        max = template.max()
        current = @get_migration template
        if current < max
            for i in [current + 1..max]
                @apply_template current, i

    #Applies the development migration.  This does not get cached to S3.
    apply_dev: (template) ->

    #Given a template, check what the current migration number is
    get_migration: (template) ->

    #Runs the given migration on the database (first saving that migration to S3 + confirming it hasn't changed)
    apply_template: (template, migration) ->

bbserver = require './bbserver'