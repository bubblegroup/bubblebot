bbobjects = exports

constants = require './constants'
bbserver = require './bbserver'

#Retrieves an object with the given type and id
bbobjects.instance = (type, id) ->
    if not bbobjects[type]
        throw new Error 'missing type: ' + type
    return new bbobjects[type] type, id

#Returns the bubblebot environment
bbobjects.bubblebot_environment = ->
    environment = bbobjects.instance 'Environment', 'bubblebot'
    return environment


#Constant we use to tag resources for things that don't use the database
BUILDING = 'building'
BUILD_FAILED = 'build failed'
BUILD_COMPLETE = 'build complete'
ACTIVE = 'active'
FINISHED = 'finished'
TERMINATING = 'terminating'

#Environment types
PROD = 'prod'
QA = 'qa'
DEV = 'dev'

BUILTIN_GROUP_DESCRIPTION = {}
BUILTIN_GROUP_DESCRIPTION[constants.ADMIN] = 'Administrators with full control over bubblebot'
BUILTIN_GROUP_DESCRIPTION[constants.TRUSTED]  = 'Trusted users who are allowed to grant themselves administrative access in an emergency (using the "sudo" command)'
BUILTIN_GROUP_DESCRIPTION[constants.BASIC] = 'Users who can give commands to bubblebot'
BUILTIN_GROUP_DESCRIPTION[constants.IGNORE] = 'Users who are ignored by bubblebot'
bbobjects.BUILTIN_GROUP_DESCRIPTION = BUILTIN_GROUP_DESCRIPTION

#Returns the bubblebot server (creating it if it does not exist)
#
#We do not manage the bubblebot server in the database, since we need to be able to find it
#even when we are running the command line script.
bbobjects.get_bbserver = ->
    environment = bbobjects.bubblebot_environment()
    instances = environment.get_instances_by_tag(config.get('bubblebot_role_tag'), config.get('bubblebot_role_bbserver'))

    if instances.length > 1
        throw new Error 'Found more than one bubblebot server!  Should only be one server tagged ' + config.get('bubblebot_role_tag') + ' = ' + config.get('bubblebot_role_bbserver')
    else if instances.length is 1
        instance = instances[0]

        #manually set environment in case database is not built yet
        instance.environment = -> environment

        return instance

    #We didn't find it, so create it...
    image_id = config.get('bubblebot_image_id')
    instance_type = config.get('bubblebot_instance_type')
    instance_profile = config.get('bubblebot_instance_profile')

    id = environment.create_server_raw image_id, instance_type, instance_profile

    environment.tag_resource id, 'Name', 'Bubble Bot'


    instance = bbobjects.instance 'EC2Instance', id

    u.log 'bubblebot server created, waiting for it to ready...'

    #manually set environment because we can't check database
    instance.environment = -> environment

    instance.wait_for_ssh()

    u.log 'bubblebot server ready, installing software...'

    #Install node and supervisor
    command = 'node ' + config.get('install_directory') + '/' + config.get('run_file')

    to_install = software.supervisor('bubblebot', command, config.get('install_directory'))
    to_install.add(software.node('4.4.5')).add(software.metrics())
    to_install.add(software.pg_dump95())
    to_install.install(instance)

    environment.tag_resource id, config.get('bubblebot_role_tag'), config.get('bubblebot_role_bbserver')

    u.log 'bubblebot server has base software installed'

    return instance


_cached_bbdb_instance = null
#Returns or creates and returns the rds instance for bbdb
#
#Ensures that u.context().db is set.
bbobjects.get_bbdb_instance = ->
    environment = bbobjects.bubblebot_environment()
    service_instance = environment.get_service('BBDBService', null, true)
    #we can't use the database, so manually record that the environment is the parent:
    service_instance.parent = -> environment

    #Makes sure u.context().db is set
    ensure_context_db = -> u.context().db ?= new bbdb.BBDatabase(service_instance)

    if _cached_bbdb_instance?
        ensure_context_db()
        return _cached_bbdb_instance

    instances = environment.list_rds_instances_by_tag(config.get('bubblebot_role_tag'), config.get('bubblebot_role_bbdb'))

    if instances.length > 1
        throw new Error 'Found more than one bbdb!  Should only be one server tagged ' + config.get('bubblebot_role_tag') + ' = ' + config.get('bubblebot_role_bbdb')
    else if instances.length is 1
        ensure_context_db()
        return instances[0]

    #It doesn't exist yet, so create it
    {permanent_options, sizing_options, credentials} = service_instance.template().get_params_for_creating_instance(service_instance)

    #Create the database
    rds_instance = bbobjects.instance 'RDSInstance', service_instance.id + '-instance1'
    #We need to tell it the environment manually...
    rds_instance.environment = -> environment
    rds_instance.create null, permanent_options, sizing_options, credentials, 'just_create'


    #Write the initial code to it
    service_instance.codebase().migrate_to rds_instance, service_instance._codebase.get_latest_version()

    #It should now be useable as a database...
    _cached_bbdb_instance = rds_instance
    ensure_context_db()

    #Save the service instance and rds_instance data
    service_instance.create environment
    rds_instance.create service_instance, null, null, null, 'just_write'

    #Tag it build complete
    environment.tag_resource rds_instance.id, config.get('bubblebot_role_tag'), config.get('bubblebot_role_bbdb')

    return rds_instance

#Returns all the objects of a given type
bbobjects.list_all = (type) -> (bbobjects.instance type, id for id in u.db().list_objects type)

#Returns all the users.  We get the list of ids from slack rather than from the database
bbobjects.list_users = -> (bbobjects.instance 'User', slack_user.id for slack_user in u.context().server.slack_client.get_all_users() ? [])


#Returns all the environments in our database
bbobjects.list_environments = -> bbobjects.list_all 'Environment'

#Returns all the regions that we have at least one environment in
bbobjects.list_regions = ->
    regions = {}
    for environment in bbobjects.list_environments()
        regions[environment.get_region()] = true
    return (region for region, _ of regions)

#Returns a list of every instance that we see in the environment.
#
#Currently returns RDSInstances and EC2Instances
bbobjects.get_all_instances = ->
    res = []
    environments = (bbobjects.get_default_dev_environment region for region in bbobjects.list_regions())
    for environment in environments
        res.push environment.describe_instances()...
        res.push environment.list_rds_instances_in_region()...
    return res

#Gets the default QA environment, which is the environment we use to run tests on individual
#components
bbobjects.get_default_qa_environment = ->
    id = 'default_qa'
    environment = bbobjects.instance 'Environment', id
    #create it if it does not exist
    if not environment.exists()
        #use the same region and vpc as bubbleblot
        bubblebot_env = bbobjects.bubblebot_environment()
        region = bubblebot_env.region()
        vpc = bubblebot_env.get_vpc()
        environment.create QA, 'blank', region, vpc
    return environment


#Gets the default development environment for the given region, creating it if it does not exist.
#
#If region is blank, returns the overall default dev environment (which is put in the same
#region as bubblebot)
bbobjects.get_default_dev_environment = (region) ->
    #if region isn't set, use the bubblebot region
    region ?= bbobjects.bubblebot_environment().region()

    #The default dev environment is always named default_dev_[region]
    id = 'default_dev_' + region
    environment = bbobjects.instance 'Environment', id
    #create it if it does not exist
    if not environment.exists()
        vpc = prompt_for_vpc(region)
        environment.create DEV, 'blank', region, vpc
    return environment

#Lists the regions in a VPC, and prompts for the user to pick one
#(or picks the first one if there is no user id)
prompt_for_vpc = (region) ->
    ec2 = new AWS.ec2(aws_config region)
    block = u.Block 'listing vpcs'
    ec2.describeVpcs {}, block.make_cb()
    results = block.wait()

    if (results.Vpcs ? []).length is 0
        throw new Error 'there are no VPCs available for region ' + region + ': please create one'

    #in interactive mode, prompt the user to pick:
    if u.context().user_id
        vpc_id = null
        while vpc_id not in (vpc.VpcId for vpc in results.Vpcs)
            u.reply 'Please pick a VPC for region ' + region
            u.reply 'Options are:\n' + ('  ' + vpc.VpcId + ': ' + vpc.State + ' ' + vpc.CidrBlock for vpc in results.Vpcs ? []).join('\n')
            vpc_id = u.ask 'Pick an id (or type "cancel" to abort)'

    #otherwise, pick the first one
    else
        vpc_id = results.Vpcs[0].VpcId

    return vpc_id


#There are a couple special objects that we do not manage in the database
HARDCODED =
    Environment:
        bubblebot:
            type: -> PROD
            region: -> config.get 'bubblebot_region'
            vpc: -> config.get 'bubblebot_vpc'


#Implementation of the Child command tree which lists all the children of a bubble object
class ChildCommand extends bbserver.CommandTree
    constructor: (@bbobject) ->

    get_commands: ->
        subs = {}
        for child in @bbobject.children()
            if subs[child.id]
                subs[child.id + '-' + child.type.toLowerCase()] = child
            else
                subs[child.id] = child
        return subs


#generic class for objects tracked in the bubblebot database
bbobjects.BubblebotObject = class BubblebotObject extends bbserver.CommandTree
    constructor: (@type, @id) ->
        super()
        if HARDCODED[@type]?[@id]
            @hardcoded = HARDCODED[@type]?[@id]

        #Add the 'child' command
        @add 'child', new ChildCommand this

    #We want to check to see if there is a template defined for this object...
    #if so, we add those commands to the existing list of subcommands.
    #
    #We assume the first parameter to the command function is this object, and we bind it
    #in (with the template itself as the 'this' parameter)
    #
    #We also add all the children as sub-commands (we can also access them through 'child')
    get_commands: ->
        template_commands = {}
        if typeof(@template) is 'function'
            template = @template()
            for k, v of template
                if typeof(v) is 'function' and template[k + '_cmd']?
                   cmd = bbserver.build_command u.extend {run: v.bind(template, this), target: template}, @[k + '_cmd']
                   template_commands[k] = cmd

        children = (new ChildCommand this).get_commands()

        return u.extend {}, children, template_commands, @subcommands

    #Schedule a method of this object as a recurring task.  Idempotent operation; we schedule
    #at most one [method, object, variant] combination.  variant is an optional and exists to
    #allow multiple schedules / property combinations for the same method.
    schedule_recurring: (method, properties, interval, variant) ->
        schedule_name = 'call_object_method.' + @type + '.' + @id + '.' + method + '.' + (variant ? '')
        u.context().server.schedule_recurring schedule_name, interval, 'call_object_method', {object_type: @type, object_id: @id, method, properties}

    #Schedule a method of this object as a one time task
    schedule_once: (method, properties, timeout) ->
        u.context().server.schedule_once timeout, 'call_object_method', {object_type: @type, object_id: @id, method, properties}


    #If we want to call a command added via a template from our own code, this returns
    #the function (pre-bound)
    get_template_command: (name) ->
        template = @template()
        fn = template?[name]
        if typeof(fn) isnt 'function'
            throw new Error 'no template command named ' + name
        return fn.bind(template, this)

    toString: -> @type + ' ' + @id

    pretty_print: -> @toString()

    #Retrieves the parent.  If type is null, retrieves the immediate parent; if not,
    #searches up the parent chain til it finds one
    parent: (parent_type) ->
        [parent_type, parent_id] = u.db().find_parent @type, @id, parent_type
        if not parent_id?
            return null
        return bbobjects.instance parent_type, parent_id

    parent_cmd:
        params: [{name: 'type', help: 'If specified, searches up the parent tree til it finds this type'}]
        help: 'finds either the immediate parent, or an ancestor of a given type'
        reply: true
        groups: constants.BASIC

    #Returns the immediate children of this object, optionally filtering by child type
    children: (child_type) ->
        list = u.db().children @type, @id, child_type
        return (bbobjects.instance child_type, child_id for [child_type, child_id] in list)

    children_cmd:
        params: [{name: 'child_type', help: 'If specified, filters to the given type'}]
        help: 'lists all the children of this object.  to access a specific child, use the "child" command'
        reply: true
        groups: constants.BASIC

    #Retrieves the environment that this is in
    environment: -> @parent 'Environment'

    #Returns true if this is a development object.  See also is_production.  Generally,
    #we want to use @is_development() rather than (not @is_production()) for things
    #involving credentials, since we want to treat QA credentials like production
    #credentials.
    is_development: -> @environment().is_development()

    is_development_cmd:
        help: 'Displays whether this is a development environment'
        reply: true
        groups: constants.BASIC

    #Returns true if this object is production.  See comment on is_development
    is_production: -> @environment().is_production()

    is_production_cmd:
        help: 'Displays whether this is a production environment'
        reply: true
        groups: constants.BASIC

    environment_cmd:
        help: 'returns the environment that this is in'
        groups: constants.BASIC

    #Gets the given property of this object
    get: (name) ->
        if @hardcoded
            return @hardcoded[name]?() ? null
        u.db().get_property @type, @id, name

    get_cmd:
        params: [{name: 'name', required: true}]
        help: 'gets the given property of this object'
        reply: true

    #Sets the given property of this object
    set: (name, value) ->
        if @hardcoded
            throw new Error 'we do not support setting properties on this object'
        u.db().set_property @type, @id, name, value

    set_cmd:
        params: [{name: 'name', required: true}, {name: 'value', required: true}]
        help: 'sets the given property of this object'
        reply: 'Property successfully set'

    #returns all the properties of this object
    properties: ->
        if @hardcoded
            res = {}
            for k, v of @hardcoded
                res[k] = v()
            return res
        u.db().get_properties @type, @id

    properties_cmd:
        help: 'gets all the properties for this object'
        reply: true

    #Creates this object in the database
    create: (parent_type, parent_id, initial_properties) ->
        if @hardcoded
            throw new Error 'we do not support creating this object'

        user_id = u.context().user_id
        if user_id
            initial_properties.creator = user_id
            initial_properties.owner = user_id

        u.db().create_object @type, @id, parent_type, parent_id, initial_properties

        #perform any startup logic
        @startup()

    #Deletes this object from the database
    delete: ->
        u.db().delete_object @type, @id

    #Returns true if this object exists in the database
    exists: ->
        if @hardcoded
            return true
        return u.db().exists @type, @id

    #Gets the history type for this item
    history_type: (event_type) -> @type + '-' + event_type

    #Adds an item to the history of this object
    add_history: (event_type, reference, properties) ->
        u.db().add_history @history_type(event_type), @id, reference, properties

    #delete an item from the history of this object
    delete_entries: (event_type, reference) ->
        u.db().delete_entries @history_type(event_type), @id, reference

    #finds items in the history of this object
    find_entries: (event_type, reference) ->
        u.db().find_entries @history_type(event_type), @id, reference

    #Lists the last n_entries in the history of this object
    recent_history: (event_type, n_entries) ->
        u.db().recent_history @history_type(event_type), @id, n_entries

    #Returns the user who created this
    creator: ->
        user_id = @get 'creator'
        if user_id
            return bbobjects.instance 'User', user_id

    creator_cmd:
        help: 'Gets the user who created this'
        reply: true
        groups: constants.BASIC

    #Returns the user who owns this
    owner: ->
        user_id = @get 'owner'
        if user_id
            return bbobjects.instance 'User', user_id

    owner_cmd:
        help: 'Gets the user who owns this'
        reply: true
        groups: constants.BASIC

    #Prints out a multi line human readable description
    describe: ->
        res = @toString()
        res += '\n\n'
        for k, v of @describe_keys()
            if v?
                res += '\n' + k + ': ' + String(v)

        return res

    #A list of things used by describe.  Can be extended by children
    describe_keys: -> {
        Parent: @parent()
        Owner: @owner()
        Environment: @environment()
    }


    describe_cmd:
        help: 'Describes this'
        reply: true
        groups: constants.BASIC


GROUP_PREFIX = 'group_member_'

#Represents a bubblebot user, ie a Slack user.  User ids are the slack ids
bbobjects.User = class User extends BubblebotObject
    create: ->
        super null, null, {}

    #gets the slack client
    slack: -> u.context().server.slack_client

    toString: -> 'User ' + @id + ' (' + @name() + ')'

    name: -> @slack().get_user_info().name

    name_cmd:
        help: 'shows the name of this user'
        reply: true
        groups: constants.BASIC

    profile: -> @slack().get_user_info().profile

    profile_cmd:
        help: 'shows the slack profile for this user'
        reply: true
        groups: constants.BASIC

    slack_info: -> @slack().get_user_info()

    slack_info_cmd:
        help: 'shows all the slack data for this user'
        reply: true
        groups: constants.BASIC

    #Adds this user to a security group
    add_to_group: (groupname) ->
        if not @exists()
            @create()

        #See if they currently have access to talk to bubblebot
        can_talk_to_us = @is_in_group constants.BASIC

        @set GROUP_PREFIX + groupname, true

        #If they didn't have permission to talk to us, but now do, welcome them!
        if not can_talk_to_us and @is_in_group constants.BASIC
            u.message @id, "Hi!  I'm Bubblebot.  Feel free to ask me to do useful stuff.  To start learning about what I can do, type 'help'"

    add_to_group_cmd:
        params: [{name: 'groupname', required: true, help: 'The group to add this user to'}]
        help: 'Adds this user to a given security group'
        reply: 'Added successfully'
        groups: constants.TRUSTED
        dangerous: (groupname) -> groupname in [constants.TRUSTED, constants.ADMIN]

    #Removes this user from the given group
    remove_from_group: (groupname) ->
        if not @exists()
            @create()
        @set GROUP_PREFIX + groupname, false

    remove_from_group_cmd:
        params: [{name: 'groupname', required: true, help: 'The group to remove this user from'}]
        help: 'Removes this user from a given security group'
        reply: 'Removed successfully'
        groups: constants.TRUSTED
        dangerous: (groupname) -> groupname in [constants.TRUSTED, constants.ADMIN]

    #Checks if this user is in a given group
    is_in_group: (groupname, checked) ->
        #We maintain a list of groups we've already checked to avoid circular group
        #membership rules leading to an infinite loop
        checked ?= {}

        if not @exists()
            @create()

        #see if the user is directly in this group
        if @get GROUP_PREFIX + groupname
            return true

        checked[groupname] = true

        #Check the groups this group contains to see if we are indirectly a member
        for sub_group in @contained_groups()
            if not checked[sub_group.id]
                if @is_in_group sub_group.id
                    return true

        #If this is the admin group we are checking, see if the user has sudo privileges
        if groupname is constants.ADMIN
            sudo_time = @get 'sudo'
            if sudo_time and sudo_time > Date.now() - 30 * 60 * 1000
                return true

        return false

    is_in_group_cmd:
        params: [{name: 'groupname', required: true, help: 'The group to check'}]
        help: 'Checks to see if this user is in a given security group'
        reply: true
        groups: constants.TRUSTED

    #Returns all the groups this user is directly a member of
    list_groups: ->
        if not @exists()
            @create()
        return (prop_name[GROUP_PREFIX.length..] for prop_name, value of @properties() when value and prop_name.indexOf(GROUP_PREFIX) is 0)

    list_groups_cmd:
        help: 'Lists all the groups this user is directly a member of'
        reply: true
        groups: constants.TRUSTED

CONTAINED_PREFIX = 'group_contains_'

#Represents a security group
bbobjects.SecurityGroup = class SecurityGroup
    create: (about) ->
        super null, null, {about}

    #Adds this security group to a containing group.  Any user in this group
    #will now be counted as part of the containing group
    add_to_group: (groupname) ->
        containing = bbobjects.instance 'SecurityGroup', groupname
        if not containing.exists()
            containing.create()

        containing.set CONTAINED_PREFIX + @id, true

    add_to_group_cmd:
        params: [{name: 'groupname', required: true, help: 'The group to add this group to'}]

        help: "Adds this security group to a containing group.  Any user in this group
        will now be counted as part of the containing group"

        reply: 'Added succesfully'
        groups: constants.TRUSTED
        dangerous: (groupname) -> groupname in [constants.TRUSTED, constants.ADMIN]

    #Removes this security group from a containing group
    remove_from_group: (groupname) ->
        containing = bbobjects.instance 'SecurityGroup', groupname
        if not containing.exists()
            containing.create()

        containing.set CONTAINED_PREFIX + @id, false

    remove_from_group_cmd:
        params: [{name: 'groupname', required: true, help: 'The group to remove this group from'}]

        help: "Removes this security group from a containing group."

        reply: 'Removed succesfully'

        groups: constants.TRUSTED

        dangerous: (groupname) -> groupname in [constants.TRUSTED, constants.ADMIN]

    #Returns an array of all the groups contained by this group
    contained_groups: ->
        res = (prop_name[CONTAINED_PREFIX.length..] for prop_name, value of @properties() when value and prop_name.indexOf(CONTAINED_PREFIX) is 0)

        #Add in some builtin containment rules

        #The basic group contains all trusted users
        if @id is constants.BASIC
            res.push constants.TRUSTED

        #The trusted group contains all admin users
        if @id is constants.TRUSTED
            res.push constants.ADMIN

        return (bbobjects.instance 'SecurityGroup', id for id in res)

    contained_groups_cmd:
        help: 'Lists the groups directly contained by this group (does not list sub-sub-groups)'
        reply: true
        groups: constants.TRUSTED

    #Sets the message that describes what this group is about
    set_about: (msg) ->
        if BUILTIN_GROUP_DESCRIPTION[@id]
            u.reply 'This is a special group defined in the bubblebot code... you are not allowed to change the description'
            return
        @set 'about', msg

    set_about_cmd:
        params: [{name: 'msg', required: true, help: 'The description for this security group'}]
        help: 'Sets the "about" description for this security group'
        reply: 'Description set'
        groups: constants.TRUSTED

    #Returns the message that describes what this group is about
    about: ->
        if BUILTIN_GROUP_DESCRIPTION[@id]
            return BUILTIN_GROUP_DESCRIPTION[@id]
        return @get('about') ? 'No description for this group yet.  Set one with "set_about"'

    about_cmd:
        help: 'Gets a description of this security group'
        reply: true
        groups: constants.TRUSTED


#If the user enters a really high value for hours, double-checks to see if it is okay
bbobjects.validate_destroy_hours = (hours) ->
    week = 7 * 24
    if hours > week
        if not bbserver.do_cast 'boolean', u.ask "You entered #{hours} hours, which is over a week (#{week} hours)... are you sure you want to keep it that long?"
            hours = bbserver.do_cast 'number', u.ask 'Okay, how many hours should we go for?'

        if hours > week
            u.report 'Fyi, ' + u.current_user().name() + ' created a test server for ' + hours + ' hours...'

    return hours

#Retrieves an S3 configuration file as a string, or null if it does not exists
bbobjects.get_s3_config = (Key) ->
    try
        data = bbobjects.bubblebot_environment().s3('getObject', {Bucket: config.get('bubblebot_s3_bucket'), Key})
    catch err
        if err.code in ['NoSuchKey', 'AccessDenied']
            return null
        else
            throw err
    if data.DeleteMarker
        return null
    if not data.Body
        throw new Error 'no body: ' + JSON.stringify data
    return String(data.Body)

#Puts an S3 configuration file
bbobjects.put_s3_config = (Key, Body) ->
    bbobjects.bubblebot_environment().s3 'putObject', {Bucket: config.get('bubblebot_s3_bucket'), Key, Body}



bbobjects.Environment = class Environment extends BubblebotObject
    create: (type, template, region, vpc) ->
        templates.verify 'Environment', template

        super null, null, {type, template, region, vpc}

        @template().initialize this

    describe_keys: -> u.extend super(), {
        template: @template()
        type: @get 'type'
        region: @get_region()
        vpc: @get_vpc()
    }

    #Need to overwrite the default implementation since it by default checks the environment
    is_development: -> @get('type') is DEV

    #Need to overwrite the default implementation since it by default checks the environment
    is_production: -> @get('type') is PROD

    template: ->
        template = @get 'template'
        if not template
            return null
        return templates.get('Environment', template)


    #Creates a server for development purposes
    create_box: (build_id, hours, size, name) ->
        ec2build = bbobjects.instance 'EC2Build', build_id

        u.reply 'beginning build of box... '
        box = ec2build.build this, size, name

        #Make sure we remind the user to destroy this when finished
        interval = hours * 60 * 60 * 1000
        box.set 'expiration_time', Date.now() + (interval * 2)
        u.context().schedule_once interval, 'follow_up_on_instance', {id: box.id}

        u.reply 'Okay, your box is ready:\n' + box.describe()

    create_box_cmd: ->
        params: [
            {
                name: 'build_id'
                help: 'The software to install on this server'
                required: true
                type: 'list'
                options: templates.list.bind(null, 'EC2Build')
            },
            {
                name: 'hours'
                help: 'How many hours before asking if we can delete this server'
                type: 'number'
                required: true
                validate: bbobjects.validate_destroy_hours
            }
        ]
        questions: (build_id, hours) ->
            ec2build = bbobjects.instance 'EC2Build', build_id
            default_size = ec2build.default_size this
            return {
                name: 'size'
                help: 'What size should this server be? (Type "go" to use default of ' + default_size + ')'
                type: 'list'
                options: => ec2build.valid_sizes(this)
                default: default_size
                next: => {
                    name: 'name'
                    help: 'What to call this server'
                }
            }

        help: 'Creates a new server in this environment for testing or other purposes'

        groups: constants.BASIC

    #Given a key, value pair, returns a list of instanceids that match that pair
    get_instances_by_tag: (key, value) ->
        #http://docs.aws.amazon.com/AWSJavaScriptSDK/latest/AWS/EC2.html#describeInstances-property
        return @describe_instances {
            Filters: [{Name: 'tag:' + key, Values: [value]}]
        }

    #Given a key, value pair, returns a list of RDB databases that match that pair
    get_dbs_by_tag: (key, value) -> throw new Error 'not implemented'

    #Calls describe instances on the given set of instances / parameters, and returns an array of
    #Instance objects
    describe_instances: (params) ->
        #http://docs.aws.amazon.com/AWSJavaScriptSDK/latest/AWS/EC2.html#describeInstances-property
        data = @ec2('describeInstances', params)
        res = []
        for reservation in data.Reservations ? []
            for instance in reservation.Instances ? []
                id = instance.InstanceId
                instance_cache.set id, instance
                res.push bbobjects.instance 'EC2Instance', id

        #filter out terminated instances
        res = (instance for instance in res when instance.get_state() not in ['terminated', 'shutting-down'])

        return res

    list_rds_instances_by_tag: (key, value) ->
        data = @rds 'describeDBInstances', {}
        rds_instances = (bbobjects.instance 'RDSInstance', instance.DBInstanceIdentifier for instance in data.DBInstances ? [])
        #There's no way to list by tag right now, so we find them all then filter
        return (instance for instance in rds_instances when instance.get_tags()[key] is value)

    #Lists all the RDS instances in this environment's region
    list_rds_instances_in_region: ->
        data = @rds 'describeDBInstances', {}
        return (bbobjects.instance 'RDSInstance', instance.DBInstanceIdentifier for instance in data.DBInstances ? [])

    #Returns the keypair name for this environment, or creates it if it does not exist
    get_keypair_name: ->
        name = config.get('keypair_prefix') + @id

        #check to see if it already exists
        try
            pairs = @ec2('describeKeyPairs', {KeyNames: [name]})
        catch err
            if String(err).indexOf('does not exist') is -1
                throw err

            #If not, create it
            {private_key, public_key} = u.generate_key_pair()

            #Save the private key to s3
            bbobjects.put_s3_config name, private_key

            #Strip the header and footer lines
            public_key = public_key.split('-----BEGIN PUBLIC KEY-----\n')[1].split('\n-----END PUBLIC KEY-----')[0]

            #And save the public key to ec2 to use in server creation
            @ec2('importKeyPair', {KeyName: name, PublicKeyMaterial: public_key})

        return name

    #Gets the private key that corresponds with @get_keypair_name()
    get_private_key: ->
        keyname = @get_keypair_name()
        from_cache = key_cache.get(keyname)
        if from_cache
            return from_cache

        try
            data = bbobjects.get_s3_config keyname
            key_cache.set keyname, data
            return data

        catch err
            #We lost our key, so delete it
            if String(err).indexOf('NoSuchKey') isnt -1
                u.log 'Could not find private key for ' + keyname + ': deleting it!'
                @ec2 'deleteKeyPair', {KeyName: keyname}
                throw new Error 'Could not retrieve private key for ' + keyname + '; deleted public key'
            throw err

    #Creates and returns a new ec2 server in this environment, and returns the id
    #
    #ImageId and InstanceType are the ami and type to create this with
    create_server_raw: (ImageId, InstanceType, IamInstanceProfile) ->
        KeyName = @get_keypair_name()
        SecurityGroupIds = [@get_webserver_security_group()]
        SubnetId = @get_subnet()
        MaxCount = 1
        MinCount = 1
        InstanceInitiatedShutdownBehavior = 'stop'

        params = {
            ImageId
            MaxCount
            MinCount
            SubnetId
            IamInstanceProfile
            KeyName
            SecurityGroupIds
            InstanceType
            InstanceInitiatedShutdownBehavior
        }

        u.log 'Creating new ec2 instance: ' + JSON.stringify params

        results = @ec2 'runInstances', params
        id = results.Instances[0].InstanceId
        u.log 'EC2 succesfully created with id ' + id
        return id


    #Given a server id, returns an AMI id
    create_ami_from_server: (server_id, name) ->
        results = @ec2 'createImage', {
            InstanceId: server_id
            Name: name
            NoReboot: false
        }

        return results.ImageId

    #De-registers an AMI
    deregister_ami: (ami) ->
        @ec2 'deregisterImage', {
            ImageId: ami
        }

    #Retrieves a cloudwatch log stream
    get_log_stream: (group_name, stream_name) ->
        #We only want one instance per stream, since we remember state (the last log key,
        #whether we are writing to it, etc.)
        key = group_name + '-' + stream_name
        if not log_stream_cache.get key
            log_stream_cache.set key, new cloudwatchlogs.LogStream this, group_name, stream_name
        return log_stream_cache.get key

    #Retrieves the security group for webservers in this environment, creating it if necessary
    get_webserver_security_group: ->
        group_name = @id + '_webserver_sg'
        id = @get_security_group_id(group_name)

        rules = [
            #Allow outside world access on 80 and 443
            {IpRanges: [{CidrIp: '0.0.0.0/0'}], IpProtocol: 'tcp', FromPort: 80, ToPort: 80}
            {IpRanges: [{CidrIp: '0.0.0.0/0'}], IpProtocol: 'tcp', FromPort: 443, ToPort: 443}
            #Allow other boxes in this security group to connect on any port
            {UserIdGroupPairs: [{GroupId: id}], IpProtocol: '-1'}
        ]
        #If this a server people are allowed to SSH into directly, open port 22.
        if @allow_outside_ssh()
            rules.push {IpRanges: [{CidrIp: '0.0.0.0/0'}], IpProtocol: 'tcp', FromPort: 22, ToPort: 22}

        #If this is not bubblebot, add the bubblebot security group
        if @id isnt 'bubblebot'
            bubblebot_sg = bbobjects.bubblebot_environment().get_webserver_security_group()
            #Allow bubblebot to connect on any port
            rules.push {UserIdGroupPairs: [{GroupId: bubblebot_sg}]}

        @ensure_security_group_rules group_name, rules
        return id


    #Retrieves the security group for databases in this environment, creating it if necessary
    #If external is true, allow outside world access
    get_database_security_group: (external) ->
        group_name = @id + '_database_sg' + (if external then '_external' else '')
        id = @get_security_group_id(group_name)

        rules = []
        #list of ports we allow databases to connect on
        ports = [3306, 5432, 1521, 1433]

        for port in ports
            #Let any webserver in this environment connect to the database on this port
            rules.push {UserIdGroupPairs: [{GroupId: @get_webserver_security_group()}], IpProtocol: 'tcp', FromPort: port, ToPort: port}
            #if external is true, let external servers connect to the database on this port
            if external
                rules.push {IpRanges: [{CidrIp: '0.0.0.0/0'}], IpProtocol: 'tcp', FromPort: port, ToPort: port}
            #if this is not bubblebot, let the bubblebot server connect
            if @id isnt 'bubblebot'
                bubblebot_sg = bbobjects.bubblebot_environment().get_webserver_security_group()
                #Allow bubblebot to connect on this port
                rules.push {UserIdGroupPairs: [{GroupId: bubblebot_sg}], IpProtocol: 'tcp', FromPort: port, ToPort: port}

        @ensure_security_group_rules group_name, rules
        return id

    #Given a security group name, fetches its meta-data (using the cache, unless force-refresh is on)
    #Creates the group if there is not one with this name.
    get_security_group_data: (group_name, force_refresh, retries = 2) ->
        #try the cache
        if not force_refresh
            data = sg_cache.get(group_name)

        if data?
            return data

        data = @ec2('describeSecurityGroups', {Filters: [{Name: 'group-name', Values: [group_name]}]}).SecurityGroups[0]
        if data?
            sg_cache.set(group_name, data)
            return data

        if not data?
            #prevent an infinite loop if something goes wrong
            if retries is 0
                throw new Error 'unable to create security group ' + group_name

            @ec2('createSecurityGroup', {Description: 'Created by bubblebot', GroupName: group_name, VpcId: @get_vpc()})
            return @get_security_group_data(group_name, force_refresh, retries - 1)

    #Given a name (stored in a tag on the security group), finds the id of the group
    get_security_group_id: (group_name) -> @get_security_group_data(group_name).GroupId


    #Given a set of rules, idempotently applies them to group.  Rules should be
    #complete: will delete any rules it sees that are not in this list
    ensure_security_group_rules: (group_name, rules, retries = 2) ->
        data = @get_security_group_data(group_name)
        to_remove = []
        to_add = []

        #Current rules
        TARGETS = ['IpRanges', 'UserIdGroupPairs', 'PrefixListIds']
        existing = []
        for rule in data.IpPermissions ? []
            for target in TARGETS
                for item in rule[target] ? []
                    r = u.json_deep_copy(rule)
                    for t in TARGETS
                        delete r[t]
                    r[target] = [item]
                    existing.push r

        #convert the rule into a consistent string format for easy comparison
        #we do this by removing empty arrays, nulls, and certain auto-generated fields,
        #then converting to JSON with a consistent key order and comparing
        clean = (obj) ->
            if obj? and typeof(obj) is 'object'
                ret = {}
                for k, v of obj
                    if v? and (not Array.isArray(v) or v.length > 0) and k not in ['UserId']
                        ret[k] = clean v
                return ret
            else
                return obj

        to_string = (r) -> stable_stringify(clean(r))

        #Returns true if the rules are equivalent
        compare = (r1, r2) -> to_string(r1) is to_string(r2)

        #make sure all the new rules exist
        for new_rule in rules
            found = false
            for existing_rule in existing
                if compare new_rule, existing_rule
                    found = true
                    break
            if not found
                to_add.push new_rule

        #make sure all the existing rules are in the new rules
        for existing_rule in existing
            found = false
            for new_rule in rules
                if compare new_rule, existing_rule
                    found = true
                    break
            if not found
                to_remove.push existing_rule

        #we are done
        if to_remove.length is 0 and to_add.length is 0
            return

        #prevent an infinite recursion if something goes wrong
        if retries is 0
            message = 'unable to ensure rules.  group data:\n' + JSON.stringify(data, null, 4)
            message += '\n\nto remove:'
            for rule in to_remove
                message += '\n' + to_string(rule)
            message += '\n\nto add:'
            for rule in to_add
                message += '\n' + to_string(rule)
            throw new Error message

        #refresh our data for what we have right now, and then retry this function
        refresh_and_retry = =>
            @get_security_group_data(group_name, true)
            return @ensure_security_group_rules(group_name, rules, retries - 1)

        #apply the changes...
        GroupId = @get_security_group_id(group_name)
        if to_add.length > 0
            try
                @ec2 'authorizeSecurityGroupIngress', {GroupId, IpPermissions: to_add}
            catch err
                #If it is a duplicate rule, force a refresh of the cache, then retry
                if String(err).indexOf('InvalidPermission.Duplicate') isnt -1
                    return refresh_and_retry()
                else
                    throw err


        if to_remove.length > 0
            @ec2 'revokeSecurityGroupIngress', {GroupId, IpPermissions: to_remove}

        #then refresh our cache and confirm they got applied
        return refresh_and_retry()


    #Returns the default subnet for adding new server to this VPC.  Right now
    #we are just using a dumb algorithm where we find the first one with free ip addresses
    #which wil tend to group things in the same availability zone
    get_subnet: ->
        data = @get_all_subnets()

        for subnet in data.Subnets ? []
            if subnet.State is 'available' and subnet.AvailableIpAddressCount > 0
                return subnet.SubnetId

        throw new Error 'Could not find a subnet!  Data: ' + JSON.stringify(data)


    #Returns the raw data for all subnets in the VPC for this environments
    get_all_subnets: (force_refresh) ->
        vpc_id = @get_vpc()

        if not force_refresh
            data = vpc_to_subnets.get(vpc_id)
            if data?
                return data

        data = @ec2 'describeSubnets', {Filters: [{Name: 'vpc-id', Values: [vpc_id]}]}
        vpc_to_subnets.set(vpc_id, data)
        return data

    #Policy for deleting instances directly owned by this environment.
    #
    #The rule is they need to have an expiration set on them if they persist for longer than
    #6 hours
    should_delete: (instance) ->
        #if it is newer than 6 hours, we are fine
        if Date.now() - instance.launch_time() < 6 * 60 * 60 * 1000
            return false

        #otherwise, check the expiration time
        expires = instance.get 'expiration_time'
        if not expires
            return true
        return Date.now() > expires

    get_region: -> @get 'region'

    get_vpc: -> @get 'vpc'


    tag_resource: (id, Key, Value) ->
        @ec2 'createTags', {
            Resources: [id]
            Tags: [{Key, Value}]
        }

    #Calls ec2 and returns the results
    ec2: (method, parameters) -> @aws 'EC2', method, parameters

    #Calls rds and returns the results
    rds: (method, parameters) -> @aws 'RDS', method, parameters

    #Calls s3 and returns the results
    s3: (method, parameters) -> @aws 'S3', method, parameters

    CloudWatchLogs: (method, parameters) -> @aws 'CloudWatchLogs', method, parameters

    #Calls the AWS api
    aws: (service, method, parameters) ->
        svc = @get_svc service
        block = u.Block method
        svc[method] parameters, block.make_cb()
        return block.wait()

    #Gets the underlying AWS service object
    get_svc: (service) -> new AWS[service](aws_config @get_region())

    allow_outside_ssh: ->
        #We allow direct SSH connections to bubblebot to allow for deployments.
        #The security key for connecting should NEVER be saved locally!
        if @id is 'bubblebot'
            true
        else
            throw new Error 'not implemented!'

    #Returns the elastic ip for this environment with the given name.  If no such
    #elastic ip exists, creates it
    get_elastic_ip: (name) ->
        key = 'elastic_ip_' + name

        #See if we already have it
        eip_id = @get key
        if eip_id
            return bbobjects.instance 'ElasticIPAddress', eip_id

        #If not, create it
        allocation = @ec2 'allocateAddress', {Domain: 'vpc'}
        eip_instance = bbobjects.instance 'ElasticIPAddress', allocation.AllocationId

        #add it to the database
        eip_instance.create this, this.id + ' ' + name

        #store it for future retrieval
        @set key, eip_instance.id

        return eip_instance

    #Returns the service for this environment with the given template name.  If create_on_missing
    #is true, creates it if it does not already exist
    #
    #If dont_check_exists is true, doesn't check if it exists or not, just returns it.  This is
    #mainly for bootstrapping BBDB
    get_service: (template_name, create_on_missing, dont_check_exists) ->
        templates.verify 'Service', template_name
        instance = bbobjects.instance 'ServiceInstance', @id + '-' + template_name
        if dont_check_exists
            return instance
        if not instance.exists()
            if create_on_missing
                instance.create this
            else
                return null
        return instance

    #Gets a credential set for this environment, creating it if it does not exist
    get_credential_set: (set_name) ->
        set = bbobjects.instance 'CredentialSet', @id + '-' + set_name
        if not set.exists()
            set.create this
        return set

    #Retrieves a credential from this environment
    get_credential: (set_name, name) -> @get_credential_set(set_name).get_credential(name)

    get_credential_cmd:
        params: [
            {name: 'set_name', required: true, help: 'The name of the credential-set to retrieve'}
            {name: 'name', required: true, help: 'The name of the credential to retrieve'}
        ]
        help: 'Retrieves a credential for this environment.'
        dangerous: -> not @environment().type().is_development()
        groups: ->
            if @environment().type().is_development()
                return constants.BASIC
            else
                return constants.ADMIN

    #Sets a credential for this environment
    set_credential: (set_name, name, value, overwrite) ->
        @get_credential_set(set_name).set_credential(name, value, overwrite)

    set_credential_cmd:
        params: [
            {name: 'set_name', required: true, help: 'The name of the credential-set to set'}
            {name: 'name', required: true, help: 'The name of the credential to set'}
            {name: 'value', required: true, help: 'The value to set the credential to'}
            {name: 'overwrite', type: 'boolean', help: 'If set, overrides an existing credential with that name'}
        ]
        help: 'Sets a credential for this environment'

        groups: (set_name, name, value, overwrite) ->
            if not value?
                throw new Error 'assertion error: ' + JSON.stringify({set_name, name, value, overwrite})
            if overwrite and @environment().type().is_development()
                return constants.ADMIN
            else
                return constants.BASIC


    #Gets the RDS subnet group for this environment, creating it if necessary
    get_rds_subnet_group: ->
        subnet_groupname = 'for_' + @id

        #see if we know its created in our cache
        if rds_subnet_groups.get(subnet_groupname)
            return subnet_groupname

        #check if it is created
        try
            results = @rds 'describeDBSubnetGroups', {DBSubnetGroupName: subnet_groupname}
            if results.DBSubnetGroups?.length > 0
                rds_subnet_groups.set(subnet_groupname, true)
                return subnet_groupname

        catch err
            if String(err).indexOf('DBSubnetGroupNotFoundFault') is -1
                throw err


        #not created, so create it

        #find all our subnets in this VPC
        results = @ec2 'describeSubnets', {
            Filters: [{Name: 'vpc-id', Values: [@get_vpc()]}]
        }
        SubnetIds = (subnet.SubnetId for subnet in results.Subnets ? [])

        @rds 'createDBSubnetGroup', {
            DBSubnetGroupDescription: 'Default Bubblebot-created subnet group for environment ' + @id
            DBSubnetGroupName: subnet_groupname
            SubnetIds
        }

        return subnet_groupname





#Represents a collection of (possibly secure) credentials
bbobjects.CredentialSet = class CredentialSet extends BubblebotObject
    #Adds it to the database
    create: (environment) ->
        prefix = environment.id + '-'
        if @id.indexOf(prefix) isnt 0
            throw new Error 'CredentialSet ids should be of the form [environment id]_[set name]'
        super parent.type, parent.id

    set_name: ->
        prefix = @environment().id + '-'
        return @id[prefix.length...]

    set_credential: (name, value, overwrite) ->
        if not overwrite
            prev = @get 'credential_' + name
            if prev
                u.reply 'There is already a credential for environment ' + @parent().id + ', set ' + @set_name() + ', name ' + name + '. To overwrite it, call this command again with overwrite set to true'
                return
        @set 'credential_' + name, value
        msg = 'Credential set for environment ' + @parent().id + ', set ' + @set_name() + ', name ' + name
        u.announce msg
        u.reply msg

    get_credential: (name) ->
        @get 'credential_' + name


bbobjects.ServiceInstance = class ServiceInstance extends BubblebotObject
    #Adds it to the database
    create: (environment) ->
        prefix = environment.id + '-'
        if @id.indexOf(prefix) isnt 0
            throw new Error 'ServiceInstance ids should be of the form [environment id]_[template]'

        template = @id[prefix.length..]
        templates.verify 'Service', template

        super environment.type, environment.id

    #Returns a command tree allowing access to each test
    tests: ->
        tree = new bbserver.CommandTree()
        tree.get_commands = ->
            res = {}
            for test in @template().get_tests()
                res[test.id] = test
            return res
        return tree

    tests_cmd: 'raw'

    #Returns a human-readable display of this version
    about_version: (version) ->
        res = @template().codebase().pretty_print version
        for test in @template().get_tests()
            if test.is_tested version
                res += 'Test ' + test.id + ': passed'
        return res

    about_version:
        params: [{name: 'version', required: 'true', help: 'The version to display'}]
        help: 'Returns information about this version.'
        reply: true

    #Returns the deployment history for this service
    deploy_history: (n_entries) ->
        u.db().recent_history 'deploy', n_entries

    deploy_history_cmd:
        params: [{name: 'n_entries', type: 'number', default: 10, help: 'The number of entries to return'}]
        help: 'Prints the recent deployment history for this service'
        reply: (entries) ->
            formatted = []
            for {timestamp, reference, properties: {username, deployment_message, rollback}} in entries
                entry = new Date(timestamp) + ' ' + username + ' ' + reference
                entry += '\n' + (if rollback then '(ROLLBACK) ' else '') + deployment_message
                formatted.push entry
            return formatted.join('\n\n')
        groups: constants.BASIC

    #Checks if we are still using this instance
    should_delete: (instance) -> instance.should_delete this

    should_delete_ec2instance: (ec2instance) ->
        #If we are active, delete any expiration time, and don't delete
        if ec2instance.get('status') is ACTIVE
            ec2instance.set 'expiration_time', null
            return false

        #Otherwise, see if there is an expiration time set
        else
            expiration = ec2instance.get 'expiration_time'
            #if there isn't an expiration time, set it for 2 hours
            if not expiration
                ec2instance.set 'expiration_time', Date.now() + 2 * 60 * 60 * 1000
                return false
            #otherwise, see if we are expired
            else
                return Date.now() > expiration

    #We never want to delete the RDS instance for a given service without shutting
    #down the service itself
    should_delete_rdsinstance: (rds_instance) -> false

    describe_keys: -> u.extend super(), {
        template: @template()
        version: @version()
        endpoint: @endpoint()
    }

    #Returns the template for this service or null if not found
    template: ->
        prefix = @parent().id + '-'
        template = @id[prefix.length..]
        if not template
            return null
        return templates.get('Service', template)

    codebase: -> @template().codebase()

    #Returns the endpoint that this service is accessible at
    endpoint: -> @template().endpoint this

    #Request that other users don't deploy to this service
    block: (explanation) ->
        blocker_id = u.context().user_id
        @set 'blocked', {blocker_id, explanation}
        u.reply 'Okay, deploying is now blocked'
        u.announce 'Deploying is now blocked on ' + this + ' (' + explanation + ')'

    block_cmd:
        params: [{name: 'explanation', required: true}]
        help: 'Ask other users not to deploy to this service til further notice.  Can be cancelled with "unblock"'
        groups: constants.BASIC

    #Remove a request created with block
    unblock: ->
        {blocker_id, explanation} = (@get('blocked') ? {blocker_id: null})
        if not blocker_id
            u.reply 'Deploying was not blocked...'
            return

        if blocker_id isnt u.context().user_id
            okay = u.ask 'Deploying is blocked by ' + bbobjects.instance('User', blocker_id).name() + '... are you sure you want to override it?'
            if not okay
                return
            u.message blocker_id, 'Fyi, ' + bbobjects.instance('User', u.context().user_id).name() + ' removed your block on ' + this

        @set 'blocked', null
        u.reply 'Okay, deploying is unblocked'
        u.announce 'Deploying is now unblocked on ' + this

    unblock_cmd:
        help: 'Removes a block on deploying created with the "block" command'
        groups: constants.BASIC


    #Deploys this version to this service
    deploy: (version, rollback) ->
        #See if a user is blocking deploys
        {blocker_id, explanation} = (@get('blocked') ? {blocker_id: null})
        if blocker_id and blocker_id isnt u.context().user_id
            name = bbobjects.instance('User', blocker_id).name()
            u.reply name + ' has requested that no one deploys to this right now, because: ' + explanation
            command = u.context().command.path[...-1].concat(['unblock'])
            u.reply 'To override this, say: ' + command
            return

        @template().deploy this, version, rollback

    deploy_cmd:
        params: [{name: 'version', required: true, help: 'The version to deploy'}, {name: 'rollback', type: 'boolean', help: 'If true, allows deploying versions that are not ahead of the current version'}]
        help: 'Deploys the given version to this service.  Ensures that the new version is tested and ahead of the current version'
        groups: constants.BASIC

    #Returns the current version of this service
    version: -> @get 'version'

    version_cmd:
        help: 'Returns the current version of this service'
        reply: (version) -> @template().codebase().pretty_print version
        groups: constants.BASIC

    #On startup, we make sure we are monitoring this
    startup: -> u.context().server.monitor this

    #Returns a description of how this service should be monitored
    get_monitoring_policy: -> @template().get_monitoring_policy this

    #Returns true if this service is in maintenance mode (and thus should not be monitored)
    maintenance: ->
        #if we don't have a version set, we are in maintenance mode
        if not @version()
            return true

        #if the maintenance property is set, we are in maintenance mode
        if @get 'maintenance'
            return true

        return false

    maintenance_cmd:
        help: 'Returns whether we are in maintenance mode'
        reply: true
        groups: constants.BASIC

    #Sets whether or not we should enter maintenance mode
    set_maintenance: (turn_on) ->
        @set 'maintenance', turn_on
        u.reply 'Maintenance mode is ' + (if turn_on then 'on' else 'off')

    set_maintenance_cmd:
        params: {name: 'on', type: 'boolean', required: true, help: 'If true, turns maintenance mode on, if false, turns it off'}
        help: 'Turns maintenance mode on or off'
        groups: constants.BASIC

    #Replaces the underlying boxes for this service
    replace: -> @template().replace this

    replace_cmd:
        help: 'Replaces the underlying boxes for this service'
        groups: constants.BASIC


#Represents the AMI and software needed to build an ec2 instance
#
#The id should match the ec2_build_template for this build
bbobjects.EC2Build = class EC2Build extends BubblebotObject
    #Creates in the database.  We need to do this to store AMIs for each region
    create: ->
        templates.verify 'EC2Build', @id
        super null, null, {}

    #Retrieves the ec2 build template
    template: -> templates.get('EC2Build', @id)

    describe_keys: -> u.extend super(), {
        template: @id
        codebase: @codebase()
    }

    #Retrieves the codebase object for this build
    codebase: -> @template().codebase()

    #Used internally by build and create ami to build a machine
    _build: (parent, size, name, ami, software, do_verify) ->
        environment = parent.environment()

        id = environment.create_server_raw ami, size
        ec2instance = bbobjects.instance 'EC2Instance', id
        try
            ec2instance.create parent, name, BUILDING, @id

            #wait for ssh
            ec2instance.wait_for_ssh()
            u.log ec2instance + ' is available over ssh, installing software'

            #install software
            software.install ec2instance
            u.log 'done installing software on ' + ec2instance + ', verifying...'

            #verify software is installed and mark complete
            if do_verify
                @template().verify ec2instance
                u.log 'installation on ' + ec2instance + ' verified, marking build complete'
                ec2instance.set_status BUILD_COMPLETE

            return ec2instance

        catch err
            #if we had an error building it, set the status to build failed
            ec2instance.set_status BUILD_FAILED
            throw err

    #Creates a server with the given size owned by the given parent
    build: (parent, size, name) ->
        ami = @get_ami parent.environment().get_region()
        software = @template().software()
        @_build parent, size, name, ami, software

    #Gets the current AMI for this build in the given region.  If there isn't one, creates it.
    get_ami: (region) ->
        key = 'current_ami_' + region
        ami = @get key
        if not ami
            @replace_ami region
        return @get key

    get_ami_cmd:
        params: [{name: 'region', required: true, help: 'The region to retrieve the AMI for'}]
        help: 'Retrieves the current AMI for this build in the given region.  If one does not exist, creates it.'
        reply: true
        groups: constants.BASIC

    #Make sure we are scheduling replacing
    startup: ->
        interval = @template().get_replacement_interval()
        if interval
            @schedule_recurring 'replace_ami_all', {}, interval

    #Replaces the AMI for all active regions
    replace_ami_all: ->
        for region in bbobjects.list_regions()
            @replace_ami(region)

    #Replaces the ami for this region
    replace_ami: (region) ->
        u.reply 'Replacing AMI for ' + this + ' in region ' + region

        environment = bbobjects.get_default_dev_environment region

        #Build an instance to create the AMI from
        template = @template()
        ec2instance = @_build environment, template.ami_build_size(), 'AMI build for ' + this, template.base_ami(region), template.ami_software(), false

        #Create the ami
        new_ami = environment.create_ami_from_server ec2instance, @id

        #Retrieve the existing AMI if there is one
        key = 'current_ami_' + region
        old_ami = @get key

        #Save it as the new default AMI for this region
        @set key, new_ami

        msg = 'Replaced AMI for ' + this + ' in region ' + region + ': new AMI ' + new_ami
        u.reply msg
        u.announce msg

        #destroy the server we used to create the ami
        ec2instance.terminate()

        #destroy the old ami if there was one
        if old_ami
            try
                environment.deregister_ami old_ami
            catch err
                u.report 'Failure trying to deregister old AMI: ' + old_ami
                u.report 'Failure was: ' + err.stack ? err

        return

    replace_ami_cmd:
        params: [{name: 'region', required: true, help: 'The region to replace the AMI for'}]
        help: 'Replaces the current AMI for this build in the given region'
        groups: constants.BASIC

    #Tells this ec2 instance that it is receiving external traffic.
    #Some builds might want notification given to the box.
    #We also update our status
    make_active: (ec2instance) ->
        #Set the status
        ec2instance.set_status ACTIVE

        #Inform the instance, if appropriate
        @template().make_active ec2instance

    #Tells this ec2 instance to perform a graceful shutdown, and schedules a termination
    graceful_shutdown: (ec2instance) ->
        template = @template()

        #set the status to finished
        ec2instance.set_status FINISHED

        #Schedule a termination
        termination_delay = template.termination_delay()
        u.context().schedule_once termination_delay, 'terminate_instance', {id: ec2instance.id}

        #Tell the server to begin its graceful shutdown
        template.graceful_shutdown ec2instance

    #Returns the default server size for this build.  Can optionally pass in an object
    #that we use to look at for more details (ie, whether or not it is production, etc.)
    default_size: (instance) -> @template().default_size instance

    #Returns a list of valid sizes for this build.  Can optionally pass in an object
    #that we use to look at for more details (ie, whether or not it is production, etc.)
    valid_sizes: (instance) -> @template().valid_sizes instance


bbobjects.Test = class Test extends BubblebotObject
    #Creates in the database
    create: ->
        templates.verify 'Test', @id
        super null, null, {}

    template: -> templates.get('Test', @id)

    is_tested: (version) -> @find_entries('test_passed', version).length > 0

    #Runs the tests against this version
    run: (version) ->
        u.reply 'Running test ' + @id + ' on version ' + version
        result = @template().run version
        if result
            u.reply 'Test ' + @id + ' passed on version ' + version
            @mark_tested version
        else
            u.reply 'Test ' + @id + ' failed on version ' + version

    #Returns an array of the last n_entries versions that passed the tests.  Does not count tests marked
    #as skip_tests unless include_skipped is set to true
    good_versions: (n_entries, include_skipped) ->
        versions = u.db().recent_history 'test_passed', n_entries
        return (reference for {reference, properties} in versions when include_skipped or not properties?.skip_tests)

    good_versions_cmd:
        params: [
            {name: 'n_entries', type: 'number', default: 10, help: 'Number of entries to return.  May return less if not including ones where we skipped the test'}
            {name: 'include_skipped', type: 'boolean', default: false, help: 'If set, includes versions where tests were skipped instead of being run'}
        ]
        reply: true
        groups: constants.BASIC

    run_cmd:
        params: [{name: 'version', required: true, help: 'The version of the codebase to run this test against'}]
        help: 'Runs this test against the given version'
        groups: constants.BASIC

    #Marks this version as tested without actually running the tests
    skip_tests: (version) ->
        @add_history 'test_passed', version, {skip_tests: true}
        u.report 'User ' + u.current_user() + ' called skip tests on ' + @id + ', version ' + version

    skip_tests_cmd:
        help: 'Marks this version as tested without actually running the tests'
        params: [{name: 'version', required: true, help: 'The version of the codebase to mark as tested'}]
        reply: 'Version marked as tested'
        groups: constants.BASIC

    mark_tested: (version) ->
        @add_history 'test_passed', version

    #Called to erase a record of a successful test pass
    mark_untested: (version) ->
        @delete_entries 'test_passed', version


bbobjects.EC2Instance = class EC2Instance extends BubblebotObject
    #Creates in the database and tags it with the name in the AWS console
    create: (parent, name, status, build_template_id) ->
        templates.verify 'EC2Build', build_template_id
        super parent.type, parent.id, {name, status, build_template_id}

        @environment().tag_resource @id, 'Name', name + ' (' + status + ')'

    #Double-dispatch for should_delete
    should_delete: (owner) -> owner.should_delete_ec2instance(this)

    #Updates the status and adds a ' (status)' to the name in the AWS console
    set_status: (status) ->
        u.log 'setting status of ' + this + ' to ' + status
        @set 'status', status

        new_name = @get('name') + ' (' + status + ')'
        @environment().tag_resource @id, 'Name', new_name

    describe_keys: ->
        expiration = @get('expiration_time')
        if expiration
            expires_in = u.format_time(expiration - Date.now())

        return u.extend super(), {
            name: @get 'name'
            status: @get 'status'
            aws_status: @get_state()
            template: @template()
            public_dns: @get_public_dns()
            address: @get_address()
            bubblebot_role: @bubblebot_role()
            tags: (k + ': ' +v for k, v of @get_tags()).join(', ')
            age: u.format_time(Date.now() - @launch_time())
            expires_in
        }

    #The template for this ec2instance (ie, what software to install)
    template: ->
        template = @get 'build_template_id'
        if not template
            return null
        return templates.get('EC2Build', template)

    run: (command, options) ->
        return ssh.run @get_address(), @environment().get_private_key(), command, options

    upload_file: (path, remote_dir) ->
        ssh.upload_file @get_address(), @environment().get_private_key(), path, remote_dir

    write_file: (data, remote_path) ->
        ssh.write_file @get_address(), @environment().get_private_key(), remote_path, data

    #Makes sure we have fresh metadata for this instance
    refresh: -> @environment().describe_instances({InstanceIds: [@id]})

    #Gets the amazon metadata for this instance, refreshing if it is null or if force_refresh is true
    get_data: (force_refresh) ->
        if force_refresh or not instance_cache.get(@id)
            @refresh()
        return instance_cache.get(@id)

    #Waits til the server is in the running state
    wait_for_running: (retries = 20) ->
        u.log 'waiting for server to be running (' + retries + ')'
        if @get_state(true) is 'running'
            return
        else if retries is 0
            throw new Error 'timed out while waiting for ' + @id + ' to be running: ' + @get_state()
        else
            u.pause 10000
            @wait_for_running(retries - 1)

    #When the server was launched
    launch_time: -> new Date(@get_data().LaunchTime)

    #waits for the server to accept ssh connections
    wait_for_ssh: () ->
        @wait_for_running()
        do_wait = (retries = 20) =>
            u.log 'server running, waiting for it accept ssh connections (' + retries + ')'
            try
                @run 'hostname'
            catch err
                if retries is 0 or not @_ssh_expected(err)
                    throw err
                else
                    u.pause 10000
                    return do_wait(retries - 1)

        do_wait()

    #True if this is one of the expected errors while we wait for a server to become reachable via ssh
    _ssh_expected: (err) ->
        if String(err).indexOf('Timed out while waiting for handshake') isnt -1
            return true
        if  String(err).indexOf('ECONNREFUSED') isnt -1
            return true
        return false


    #Returns the state of the instance.  Set force_refresh to true to check for changes.
    get_state: (force_refresh) -> @get_data(force_refresh).State.Name

    terminate: ->
        u.log 'Terminating server ' + @id

        #first update the status if we have this in the database
        if @exists()
            @set_status TERMINATING

        #then do the termination...
        data = @environment().ec2 'terminateInstances', {InstanceIds: [@id]}
        if not data.TerminatingInstances?[0]?.InstanceId is @id
            throw new Error 'failed to terminate! ' + JSON.stringify(data)

        #then delete the data if it exists
        if @exists()
            @delete()

    #Terminates this server
    clean: (confirm) ->
        if confirm
            @terminate()
            u.reply 'Server succesfully terminated'
        else
            u.reply 'Okay, aborting'

    clean_cmd: ->
        help: 'Terminates this server'
        questions: ->
            {name: 'confirm',  type: 'boolean', help: 'Are you sure you want to terminate this server?'}
        dangerous: -> @environment().is_production()
        groups: ->
            if @environment().is_production() or @owner().id isnt @current_user().id
                return constants.ADMIN
            else
                return constants.BASIC


    #Writes the given private key to the default location on the box
    install_private_key: (path) ->
        key_data = fs.readFileSync path, 'utf8'
        u.log 'installing private key'
        @run 'cat > ~/.ssh/id_rsa << EOF\n' + key_data + '\nEOF', {no_log: true}
        @run 'chmod 600 /home/ec2-user/.ssh/id_rsa'

        #turn off strict host checking so that we don't get interrupted by prompts
        @run 'echo "StrictHostKeyChecking no" > ~/.ssh/config'
        @run 'chmod 600 /home/ec2-user/.ssh/config'

    #Returns the address bubblebot can use for ssh / http requests to this instance
    get_address: ->
        if config.get('command_line', false)
            @get_public_ip_address()
        else
            @get_private_ip_address()

    get_public_dns: -> @get_data().PublicDnsName

    get_instance_type: -> @get_data().InstanceType

    get_launch_time: -> @get_data().LaunchTime

    get_private_ip_address: -> @get_data().PrivateIpAddress

    get_public_ip_address: -> @get_data().PublicIpAddress

    get_tags: ->
        tags = {}
        for tag in @get_data().Tags ? []
            tags[tag.Key] = tag.Value
        return tags

    bubblebot_role: -> @get_tags[config.get('bubblebot_role_tag')]


#Represents an RDS instance.
bbobjects.RDSInstance = class RDSInstance extends BubblebotObject
    constructor: (type, id) ->
        #there are other rules too but we can add them as they become problems
        if id.indexOf('_') isnt -1
            throw new Error 'rdsinstance ids cannot contain underscores: ' + id
        super type, id

    #Creates a new rds instance.  We take:
    #
    #The parent
    #permanent_options -- things we don't allow changing after creation {Engine, EngineVersion}
    #
    #sizing_options -- things that control the DB size / cost, can be changed after creation
    #                  {AllocatedStorage, DBInstanceClass, BackupRetentionPeriod, MultiAZ, StorageType, Iops, PubliclyAccessible}
    #
    #credentials -- optional.  If not included, we generate credentials automatically and store them
    #in the bubblebot database.  If included, caller is responsible for storing the credentials.
    #
    #bootstrap -- this is for bootstrapping bbdb.  if 'just_create', creates without writing to
    #the database; if 'just_write', writes to the database without creating
    create: (parent, permanent_options, sizing_options, credentials, bootstrap) ->
        {Engine, EngineVersion} = permanent_options
        {AllocatedStorage, DBInstanceClass, BackupRetentionPeriod, MultiAZ, StorageType, Iops, PubliclyAccessible} = sizing_options

        if bootstrap is 'just_create' and not credentials?
            throw new Error 'Need to include credentials when using just_create'
        if bootstrap? and bootstrap not in ['just_create', 'just_write']
            throw new Error 'unrecognized bootstrap: ' + bootstrap

        #Add to the database
        if bootstrap isnt 'just_create'
            super parent.type, parent.id

        if bootstrap is 'just_write'
            return

        if credentials
            {MasterUsername, MasterUserPassword} = credentials
        else
            MasterUsername = 'bubblebot'
            MasterUserPassword = u.gen_password()
            @set 'MasterUsername', MasterUsername
            @set 'MasterUserPassword', MasterUserPassword

        VpcSecurityGroupIds = [@environment().get_database_security_group(PubliclyAccessible)]
        DBSubnetGroupName = @environment().get_rds_subnet_group()

        StorageEncrypted = (DBInstanceClass not in ['db.t2.micro', 'db.t2.small', 'db.t2.medium'])
        if not StorageEncrypted
            u.log 'Creating unencrypted database (DBInstanceClass too small: ' + DBInstanceClass + ')'


        params = {
            DBInstanceIdentifier: @id

            #Permanent Options

            Engine
            EngineVersion
            #DBParameterGroupName  -- not supporting editing this at the moment, go with default

            #Sizing Options

            AllocatedStorage #5 to 6144 (in GB)
            DBInstanceClass #db.m1.small, etc
            BackupRetentionPeriod #0 - 35
            MultiAZ #true if we want to make it multi-AZ
            StorageType #standard | gp2 | io1
            Iops #must be a multiple of 1000, and from 3x to 10x of storage amount.  Only if storagetype is io1
            PubliclyAccessible #boolean, if true it means it can be accessed from the outside world

            #Credentials

            MasterUsername
            MasterUserPassword

            #Auto-generated

            VpcSecurityGroupIds
            DBSubnetGroupName

            StorageEncrypted  #t2.large supports this, smaller ones do not
        }

        #Remove credentials from the parameters...
        safe_params = u.extend {}, params
        delete safe_params.MasterUsername
        delete safe_params.MasterUserPassword
        u.log 'Creating new RDS instance: ' + JSON.stringify safe_params

        results = @environment().rds 'createDBInstance', params

        u.log 'RDS instance succesfully created with id ' + @id
        return null

    #Double-dispatch for should_delete
    should_delete: (owner) -> owner.should_delete_rdsinstance(this)

    #returns true if any of the sizing options changes could cause downtime
    are_changes_unsafe: (sizing_options) ->
        {AllocatedStorage, DBInstanceClass, BackupRetentionPeriod, MultiAZ, StorageType, Iops, PubliclyAccessible} = sizing_options
        unsafe = false
        if DBInstanceClass?
            unsafe = true
        if BackupRetentionPeriod is 0
            unsafe = true
        if StorageType?
            unsafe = true

        return unsafe

    #Resizes an RDS instance
    #
    #unsafe_okay: if true, allows making changes that would cause downtime
    resize: (sizing_options, unsafe_okay) ->
        {AllocatedStorage, DBInstanceClass, BackupRetentionPeriod, MultiAZ, StorageType, Iops, PubliclyAccessible} = sizing_options

        if @are_changes_unsafe(sizing_options) and not unsafe_okay
            throw new Error 'making unsafe changes without unsafe_okay'

        #If we are change the storage type we have to reboot afterwards
        reboot_required = StorageType?

        #If we are changing publically accessible, we need to update the list of security groups
        if PubliclyAccessible?
            VpcSecurityGroupIds = [@environment().get_database_security_group(PubliclyAccessible)]

        params = {
            ApplyImmediately: true
            AllocatedStorage
            DBInstanceClass
            BackupRetentionPeriod
            MultiAZ
            StorageType
            Iops
            PubliclyAccessible
        }

        u.log 'Resizing RDB ' + @id + ' with params: ' + JSON.stringify params

        @environment().rds 'modifyDBInstance', params

        u.log 'Resizing RDB succesful'

        if reboot_required
            @environment().rds 'rebootDBInstance', {DBInstanceIdentifier: @id}

        #Force a refresh of our cache
        @get_configuration true

        return null

    #Fetches the current state of this instance from RDS
    get_configuration: (force_refresh) ->
        if not force_refresh and rds_cache.get @id
            return rds_cache.get @id

        data = @environment().rds 'DescribeDBInstances', {DBInstanceIdentifier: @id}
        res = data.DBInstances?[0]
        rds_cache.set @id, res
        return res

    get_configuration_cmd:
        help: 'Fetches the configuration information about this database from RDS'
        reply: true

    #Returns the endpoint we can access this instance at.  Optionally provide
    #a username and password... if missing, we use whatever we stored in the database
    endpoint: (username, password) ->
        endpoint = {}
        data = @get_configuration()?.Endpoint
        if not data
            return null
        endpoint.address = data.Address
        endpoint.port = data.port
        endpoint.username = username ? @get 'MasterUsername'
        endpoint.password = password ? @get 'MasterUserPassword'
        endpoint.database = 'postgres'

        return endpoint

    #Destroys this RDS instance.  As an extra safety layer, we only terminate production
    #instances if terminate prod is true
    terminate: (terminate_prod, assume_production) ->
        is_production = assume_production or @is_production()

        if is_production and not terminate_prod
            throw new Error 'cannot terminate a production RDS instance without passing terminate_prod'

        u.log 'Deleting rds instance ' + @id
        #If it is a production instance, we want to save a final snapshot.  Otherwise,
        #jus delete it.
        params = {
            DBInstanceIdentifier: @id
            FinalDBSnapshotIdentifier: if is_production then @id + '_final_snapshot_' + String(Date.now()) else null
            SkipFinalSnapshot: not is_production
        }
        @environment().rds 'deleteDBInstance', params
        u.log 'Deleted rds instance ' + @id

    get_tags: ->
        tags = {}
        for tag in @get_configuration().Tags ? []
            tags[tag.Key] = tag.Value
        return tags




#Represents an elastic ip address.  The id should be the amazon allocation id.
#
#Supports the switcher API used by SingleBoxService
bbobjects.ElasticIPAddress = class ElasticIPAddress extends BubblebotObject
    create: (parent, name) ->
        super parent.type, parent.id, {name}
        @environment().tag_resource @id, 'Name', name

    #fetches the amazon metadata for this address and caches it
    refresh: ->
        data = @environment().ec2 'describeAddresses', {'AllocationIds': [@id]}
        eip_cache.set @id, data.Addresses?[0]

    describe_keys: -> u.extend super(), {
        instance: @get_instance()
        endpoint: @endpoint()
    }

    #Retrieves the amazon metadata for this address.  If force_refresh is true,
    #forces us not to use our cache
    get_data: (force_refresh) ->
        if force_refresh or not eip_cache.get(@id)
            @refresh()
        return eip_cache.get(@id)

    #Retrieves the instance currently pointed at by this address, or null if missing
    get_instance: ->
        id = @get_data()?.InstanceId
        if id
            return bbobjects.instance 'EC2Instance', id
        else
            return null

    #retrieves the ip address
    endpoint: -> @get_data()?.PublicIp ? null

    #Switches this elastic ip to point at a new instance
    switch: (new_instance) ->
        u.log 'Switching eip ' + @id + ' to point to instance ' + new_instance.id
        @environment().ec2 'associateAddress', {
            AllocationId: @id
            AllowReassociation: true
            InstanceId: new_instance.id
        }




#Given a region, gets the API configuration
aws_config = (region) ->
    accessKeyId = config.get 'accessKeyId'
    secretAccessKey = config.get 'secretAccessKey'
    res = {region}
    if accessKeyId
        res.accessKeyId = accessKeyId
    if secretAccessKey
        res.secretAccessKey = secretAccessKey
    return res



#We keep a cache of AWS data in memory to avoid constantly pinging the API
class Cache
    constructor: (@interval) ->

        @data = {}
        @last_access = {}

        setInterval @clean.bind(this), @interval

    get: (id) ->
        @last_access[id] = Date.now()
        return @data[id]

    set: (id, data) ->
        @last_access[id] = Date.now()
        @data[id] = data

    clean: ->
        new_data = {}
        new_last_access = {}
        for k, v of @data
            last = @last_access[k]
            if last > Date.now() - @interval
                new_data[k] = v
                new_last_access[k] = last
        @data = new_data
        @last_access = new_last_access

instance_cache = new Cache(60 * 1000)
eip_cache = new Cache(60 * 1000)
key_cache = new Cache(60 * 60 * 1000)
sg_cache = new Cache(60 * 60 * 1000)
vpc_to_subnets = new Cache(60 * 60 * 1000)
log_stream_cache = new Cache(24 * 60 * 60 * 1000)
rds_subnet_groups = new Cache(60 * 60 * 1000)
rds_cache = new Cache(60 * 1000)



config = require './config'
software = require './software'
AWS = require 'aws-sdk'
ssh = require './ssh'
request = require 'request'
u = require './utilities'
stable_stringify = require 'json-stable-stringify'
fs = require 'fs'
cloudwatchlogs = require './cloudwatchlogs'
bbserver = require './bbserver'
templates = require './templates'
bbdb = require './bbdb'