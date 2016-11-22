bbobjects = exports

constants = require './constants'
bbserver = require './bbserver'

#Retrieves an object with the given type and id
bbobjects.instance = (type, id) ->
    if not bbobjects[type]
        throw new Error 'missing type: ' + type
    if not id
        throw new Error 'missing id: ' + id

    return new bbobjects[type] type, id

#Returns the bubblebot environment
bbobjects.bubblebot_environment = ->
    environment = bbobjects.instance 'Environment', constants.BUBBLEBOT_ENV

    return environment


#Environment types
bbobjects.PROD = PROD =  'prod'
bbobjects.QA = QA = 'qa'
bbobjects.DEV = DEV = 'dev'

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

        startup_bbserver instance

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


    software.supervisor('bubblebot', command, config.get('install_directory')) instance
    software.node('4.4.5') instance
    software.pg_dump95() instance

    environment.tag_resource id, config.get('bubblebot_role_tag'), config.get('bubblebot_role_bbserver')

    u.log 'bubblebot server has base software installed'

    startup_bbserver instance

    return instance

_startup_ran = false
#Code that we run each time on startup to make sure bbserver is up to date.  Should
#be idempotent
startup_bbserver = (instance) ->
    if _startup_ran
        return
    _startup_ran = true

    try
        software.metrics() instance
    catch err
        #We don't want to kill server startup if this fails
        u.log err

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
    ensure_context_db = ->
        if not u.context().db
            u.context().db = new bbdb.BBDatabase(service_instance)

    if _cached_bbdb_instance?
        ensure_context_db()
        return _cached_bbdb_instance

    to_delete = []
    good = []
    instances = environment.list_rds_instances_in_region()
    for instance in instances
        if instance.id.indexOf('bubblebot-bbdbservice-') is 0
            instance.environment = -> environment

            credentials = service_instance.template().get_s3_saved_credentials(service_instance)
            instance.override_credentials credentials.MasterUsername, credentials.MasterUserPassword

            #See if the bbdb initial version is installed...
            if service_instance.codebase().get_installed_migration(instance, 'BBDBCodebase') > -1
                good.push instance
            else
                to_delete.push instance

    instances = good

    if instances.length > 1
        throw new Error 'Found more than one bbdb!  Should only be one server tagged ' + config.get('bubblebot_role_tag') + ' = ' + config.get('bubblebot_role_bbdb')
    else if instances.length is 1
        _cached_bbdb_instance = instances[0]
        ensure_context_db()
        return _cached_bbdb_instance

    #If we are creating it, make sure we don't have any old ones hanging around
    for instance in to_delete
        u.log 'DELETING BAD BUBBLEBOT DATABASE: ' + instance.id
        try
            instance.terminate(true, true, true)
        catch err
            #We'll generally get an error here because terminate will try to remove the
            #instance from the database, which will fail...
            console.log 'Please confirm extra instances were in fact deleted'

    u.log 'No bbdb instance found, so creating it'

    try

        #It doesn't exist yet, so create it
        {permanent_options, sizing_options, credentials} = service_instance.template().get_params_for_creating_instance(service_instance)

        #Create the database
        rds_instance = bbobjects.instance 'RDSInstance', service_instance.id + '-' + u.gen_password(5)
        #We need to tell it the environment manually...
        rds_instance.environment = -> environment
        rds_instance.create null, permanent_options, sizing_options, credentials, 'just_create'
        rds_instance.wait_for_available()

        #Write the initial code to it
        service_instance.codebase().migrate_to rds_instance, service_instance.codebase().get_latest_version()

        u.log 'BBDB created, caching it'

        #It should now be useable as a database...
        _cached_bbdb_instance = rds_instance
        ensure_context_db()

        u.log 'About to save initial data'

        #Save the service instance and rds_instance data
        service_instance.create environment
        rds_instance.create service_instance, null, null, null, 'just_write'

        u.log 'Initial data saved'

        return _cached_bbdb_instance
    catch err
        u.log 'Error creating BBDB!  Printing error then exiting'
        #if we had an error creating bubblebot database, we want to exit WITHOUT signalling supervisor for a restart
        u.log err.stack ? err
        process.exit(0)

#Returns all the objects of a given type
bbobjects.list_all = (type) -> (bbobjects.instance type, id for id in u.db().list_objects type)

#Like list_all but just returns the ids
bbobjects.list_all_ids = (type) -> u.db().list_objects type

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
    id = 'default-qa'
    environment = bbobjects.instance 'Environment', id
    #create it if it does not exist
    if not environment.exists()
        #use the same region and vpc as bubbleblot
        bubblebot_env = bbobjects.bubblebot_environment()
        region = bubblebot_env.get_region()
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

    #The default dev environment is always named default-dev-[region]
    id = 'default-dev-' + region
    environment = bbobjects.instance 'Environment', id
    #create it if it does not exist
    if not environment.exists()
        vpc = prompt_for_vpc(region)
        environment.create DEV, 'blank', region, vpc
    return environment

#Lists the regions in a VPC, and prompts for the user to pick one
#(or picks the first one if there is no user id)
prompt_for_vpc = (region) ->
    ec2 = new AWS.EC2(aws_config region)
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
    help: -> 'Shows all children of ' + @bbobject

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
    help: -> 'Run commands on ' + this

    constructor: (@type, @id) ->
        super()
        if HARDCODED[@type]?[@id]
            @hardcoded = HARDCODED[@type]?[@id]

        #Add the 'child' command
        @add 'child', new ChildCommand this

    #Runs the startup function on the template if it exists
    on_startup: ->
        @template?()?.on_startup?(this)

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
                    command_object = template[k + '_cmd']
                    if typeof(command_object) is 'function'
                        command_object = command_object()

                    if command_object is 'raw'
                        cmd = v.call(template, this)
                    else
                        cmd = bbserver.build_command u.extend {run: v.bind(template, this), target: template}, command_object

                    template_commands[k] = cmd

        children = (new ChildCommand this).get_commands()

        return u.extend {}, children, template_commands, @subcommands

    #Schedule a method of this object as a recurring task.  Idempotent operation; we schedule
    #at most one [object, schedule_name, method] combination.  variant exists to
    #allow multiple schedules / property combinations for the same method.
    schedule_recurring: (interval, schedule_name, method, params...) ->
        schedule_name = @type + '.' + @id + '.' + schedule_name + '.' + method
        u.context().server.schedule_recurring interval, schedule_name, @type, @id, method, params...

    #Schedule a method of this object as a one time task
    schedule_once: (timeout, method, params...) ->
        u.context().server.schedule_once timeout, @type, @id, method, params...

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
        help: 'Finds either the immediate parent, or an ancestor of a given type'
        reply: true
        groups: constants.BASIC

    #Returns the immediate children of this object, optionally filtering by child type
    children: (child_type) ->
        list = u.db().children @type, @id, child_type
        return (bbobjects.instance child_type, child_id for [child_type, child_id] in list)

    #Retrieves the environment that this is in
    environment: -> @parent 'Environment'

    #Returns true if this is a development object.  See also is_production.  Generally,
    #we want to use @is_development() rather than (not @is_production()) for things
    #involving credentials, since we want to treat QA credentials like production
    #credentials.
    is_development: -> @environment()?.is_development() ? false

    #Returns true if this object is production.  See comment on is_development
    is_production: -> @environment()?.is_production() ? false

    environment_cmd:
        help: 'Returns the environment that this is in'
        groups: constants.BASIC
        reply: true

    #Gets the given property of this object
    get: (name) ->
        if @hardcoded?[name]
            return @hardcoded[name]?() ? null
        u.db().get_property @type, @id, name

    get_cmd:
        params: [{name: 'name', required: true}]
        help: 'Gets the given property of this object (low-level for admin use only)'
        reply: true

    #Sets the given property of this object
    set: (name, value) ->
        if @hardcoded?[name]
            throw new Error 'we do not support setting property ' + name + ' on this object'
        #make sure it exists in the db
        else if @hardcoded
            if u.db() and not u.db().exists @type, @id
                u.db().create_object @type, @id

        u.db().set_property @type, @id, name, value

    set_cmd:
        params: [{name: 'name', required: true}, {name: 'value', required: true}]
        help: 'Sets the given property of this object (low-level for admin use only)'
        reply: 'Property successfully set'

    #returns all the properties of this object
    properties: ->
        res = u.db().get_properties @type, @id
        if @hardcoded
            for k, v of @hardcoded
                res[k] = v()
        return res

    #Saves the object's data to S3
    backup: (filename) ->
        if not @exists()
            u.expected_error 'cannot backup: does not exist'
        if not filename
            throw new Error 'must include a filename'
        body = JSON.stringify @properties(), null, 4
        key = "#{@type}/#{@id}/#{filename}/#{Date.now()}.json"
        bbobjects.put_s3_config key, body
        u.reply 'Saved a backup to ' + key

    backup_cmd:
        params: [
            {name: 'filename', default: 'backup', help: 'The name of this backup.  Backups are saved as type/id/filename/timestamp.json'}
        ]
        help: "Backs up this objects' properties to S3"
        groups: constants.BASIC

    properties_cmd:
        help: 'Gets all the properties for this object (low-level for admin use only)'
        reply: true

    #Creates this object in the database
    create: (parent_type, parent_id, initial_properties) ->
        initial_properties ?= {}
        user_id = u.context().user_id
        if user_id
            initial_properties.creator = user_id
            initial_properties.owner = user_id

        u.db().create_object @type, @id, parent_type, parent_id, initial_properties

        @on_startup()

    #Deletes this object from the database
    delete: ->
        #make sure children are deleted first
        children = @children()
        if children.length > 0
            throw new Error 'cannot delete ' + @type + ' ' + @id + ', has children: ' + children.join(', ')

        u.log 'Deleting from database: ' + @type + ' ' + @id
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

    #Returns the user who owns this
    owner: ->
        user_id = @get 'owner'
        if user_id
            return bbobjects.instance 'User', user_id

    #Prints out a multi line human readable description
    describe: ->
        describe_table = []
        for k, v of @describe_keys()
            if v?
                describe_table.push [k, String(v)]

        return @toString() + '\n\n' + u.make_table(describe_table)

    #A list of things used by describe.  Can be extended by children
    describe_keys: -> {
        Parent: @parent()
        Owner: @owner()
        Creator: @creator()
        Environment: @environment()
    }

    describe_cmd:
        help: 'Describes this'
        reply: (x) -> x
        groups: constants.BASIC


    #Code for talking to AWS

    cloudfront: (method, parameters) -> @aws 'CloudFront', method, parameters

    elasticache: (method, parameters) -> @aws 'ElastiCache', method, parameters

    #Calls ec2 and returns the results
    ec2: (method, parameters) -> @aws 'EC2', method, parameters

    #Calls describe instances on the given set of instances / parameters, and returns an array of
    #Instance objects
    describe_instances: (params) ->
        #http://docs.aws.amazon.com/AWSJavaScriptSDK/latest/AWS/EC2.html#describeInstances-property
        data = @ec2('describeInstances', params)
        res = []
        region = @get_region()
        for reservation in data.Reservations ? []
            for instance in reservation.Instances ? []
                id = instance.InstanceId
                instance_cache.set id, instance

                ec2instance = bbobjects.instance 'EC2Instance', id
                ec2instance.cache_region region

                res.push ec2instance

        #filter out terminated instances
        res = (instance for instance in res when instance.get_state() not in ['terminated', 'shutting-down'])

        return res

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
    get_svc: (service) -> get_aws_service service, @get_region()

    #If we are in the database, we can get the environment's region.
    #We also maintain a cache of regions by id, for dealing with objects that
    #exist in AWS but don't have a region
    get_region: ->
        environment = @environment()
        if environment
            return environment.get_region()
        region = region_cache.get(@type + '-' + @id)
        if region
            return region
        throw new Error 'could not find a region for ' + @type + ' ' + @id + '.  Please use cache_region...'

    #Saves a region against this type
    cache_region: (region) -> region_cache.set @type + '-' + @id, region


GROUP_PREFIX = 'group_member_'

#Represents a bubblebot user, ie a Slack user.  User ids are the slack ids
bbobjects.User = class User extends BubblebotObject
    create: ->
        super null, null, {}

    #gets the slack client
    slack: -> u.context().server.slack_client

    toString: -> 'User ' + @id + ' (' + @name() + ')'

    name: -> @slack().get_user_info(@id).name

    name_cmd:
        help: 'shows the name of this user'
        reply: true
        groups: constants.BASIC

    profile: -> @slack().get_user_info(@id).profile

    profile_cmd:
        help: 'shows the slack profile for this user'
        reply: true
        groups: constants.BASIC

    slack_info: -> @slack().get_user_info(@id)

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
        for sub_group in bbobjects.instance('SecurityGroup', groupname).contained_groups()
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
bbobjects.SecurityGroup = class SecurityGroup extends BubblebotObject
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

        help: "Adds this security group to a containing group.\nAny user in this group will now be counted as part of the containing group"

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

    describe_keys: -> u.extend super(), {
        about: @about()
        'contained groups': @contained_groups()
    }

    describe_cmd:
        help: 'Describes this'
        reply: (x) -> x
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

_cached_bucket = null
bbobjects.get_s3_config_bucket = ->
    if not _cached_bucket
        buckets = config.get('bubblebot_s3_bucket').split(',')
        if buckets.length is 1
            _cached_bucket = buckets[0]
        else
            data = bbobjects.bubblebot_environment().s3('listBuckets', {})
            our_buckets = (bucket.Name for bucket in data.Buckets ? [])
            for bucket in buckets
                if bucket in our_buckets
                    _cached_bucket = bucket
                    break
            if not _cached_bucket
                throw new Error 'Could not find any of ' + buckets.join(', ') + ' in ' + our_buckets.join(', ')
    return _cached_bucket


#Retrieves an S3 configuration file as a string, or null if it does not exists
bbobjects.get_s3_config = (Key) ->
    u.retry 3, 1000, ->
        try
            data = bbobjects.bubblebot_environment().s3('getObject', {Bucket: bbobjects.get_s3_config_bucket(), Key})
        catch err
            if String(err).indexOf('NoSuchKey') isnt -1 or String(err).indexOf('AccessDenied') isnt -1
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
    bbobjects.bubblebot_environment().s3 'putObject', {Bucket: bbobjects.get_s3_config_bucket(), Key, Body}



bbobjects.Environment = class Environment extends BubblebotObject
    create: (type, template, region, vpc) ->
        templates.verify 'Environment', template

        super null, null, {type, template, region, vpc}

        @template().initialize this

    describe_keys: -> u.extend super(), {
        template: @get('template')
        type: @get 'type'
        region: @get_region()
        vpc: @get_vpc()
        is_development: @is_development()
        is_production: @is_production()
    }

    #Need to overwrite the default here since we're the environment
    environment: -> this

    #Need to overwrite the default implementation since it by default checks the environment
    is_development: -> @get('type') is DEV

    #Need to overwrite the default implementation since it by default checks the environment
    is_production: -> @get('type') is PROD

    template: ->
        if @id is constants.BUBBLEBOT_ENV
            return null
        template = @get 'template'
        if not template
            return null
        return templates.get('Environment', template)

    #Destroys this environment
    destroy: ->
        children = @children()
        if children.length > 0
            u.reply 'Cannot destroy this environment because it still has children.  Please clean up the children first:\n' + (String(child) for child in children).join('\n')
            return

        @delete()
        u.reply 'Environment ' + @id + ' is destroyed'

    destroy_cmd:
        help: 'Destroys this environment'


    #Creates a server for development purposes
    create_box: (build_id, version, hours, size, name) ->
        ec2build = bbobjects.instance 'EC2Build', build_id

        version = ec2build.codebase().ensure_version version

        u.reply 'beginning build of box... '
        box = ec2build.build this, size, name, version

        #Make sure we remind the user to destroy this when finished
        interval = hours * 60 * 60 * 1000
        box.set 'expiration_time', Date.now() + (interval * 2)
        box.schedule_once interval, 'follow_up'

        u.reply 'Okay, your box is ready:\n' + box.describe()

    create_box_cmd: ->
        sublogger: true
        params: [
            {
                name: 'build_id'
                help: 'The software to install on this server'
                required: true
                type: 'list'
                options: templates.list.bind(null, 'EC2Build')
            },
            {
                name: 'version'
                help: 'The version of this software to install on the server'
                required: true
            }
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
                    help: 'Give this server a name'
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

    #Lists all the RDS instances in this environment's region
    list_rds_instances_in_region: ->
        data = @rds 'describeDBInstances', {}
        instances = (bbobjects.instance 'RDSInstance', instance.DBInstanceIdentifier for instance in data.DBInstances ? [] when instance.DBInstanceStatus not in ['deleting', 'deleted'])
        region = @get_region()
        instance.cache_region region for instance in instances
        return instances

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

    get_private_key_cmd:
        help: 'Gets the private key for logging into servers in this environment'

        groups: ->
            if @is_development()
                return constants.BASIC
            else
                return constants.ADMIN

        dangerous: -> return not @is_development()

        reply: true

    #Creates and returns a new ec2 server in this environment, and returns the id
    #
    #ImageId and InstanceType are the ami and type to create this with
    create_server_raw: (ImageId, InstanceType, IamInstanceProfile, security_group_id) ->
        KeyName = @get_keypair_name()
        security_group_id ?= @get_webserver_security_group()
        if Array.isArray security_group_id
            SecurityGroupIds = security_group_id
        else
            SecurityGroupIds = [security_group_id]
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
    create_ami_from_server: (server, name) ->
        results = @ec2 'createImage', {
            InstanceId: server.id
            Name: name
            NoReboot: false
        }

        ImageId = results.ImageId
        u.log 'Image ' + ImageId + ' created, waiting for it to become available'

        READY_STATE = 'available'
        retries = 0
        while retries < 100
            data = @ec2 'describeImages', {ImageIds: [ImageId]}
            state = data.Images?[0]?.State
            u.log 'Image state: ' + state
            if state is READY_STATE
                break

            u.pause 10000
            retries++

        if state isnt READY_STATE
            throw new Error 'timed out waiting for image ' + ImageId + ' to become available: ' + state

        return ImageId

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

        #If this is not bubblebot, add the bubblebot server
        if @id isnt constants.BUBBLEBOT_ENV
            bubblebot_ip_range = bbobjects.get_bbserver().get_public_ip_address() + '/32'
            bubblebot_private_ip_range = bbobjects.get_bbserver().get_private_ip_address() + '/32'

            #Allow bubblebot to connect on any port
            rules.push {IpRanges: [{CidrIp: bubblebot_ip_range}], IpProtocol: '-1'}
            rules.push {IpRanges: [{CidrIp: bubblebot_private_ip_range}], IpProtocol: '-1'}

        @ensure_security_group_rules group_name, rules
        return id


    #Retrieves the security group for databases in this environment, creating it if necessary
    #If external is true, allow outside world access
    get_database_security_group: (external) ->
        group_name = @id + '_database_sg' + (if external then '_external' else '')
        id = @get_security_group_id(group_name)

        rules = []
        #list of ports we allow databases to connect on
        ports = [3306, 5432, 1521, 1433, 6379]

        for port in ports
            #Let any webserver in this environment connect to the database on this port
            rules.push {UserIdGroupPairs: [{GroupId: @get_webserver_security_group()}], IpProtocol: 'tcp', FromPort: port, ToPort: port}
            #if external is true, let external servers connect to the database on this port
            if external
                rules.push {IpRanges: [{CidrIp: '0.0.0.0/0'}], IpProtocol: 'tcp', FromPort: port, ToPort: port}
            #if this is not bubblebot, let the bubblebot server connect
            if @id isnt constants.BUBBLEBOT_ENV
                bubblebot_ip_range = bbobjects.get_bbserver().get_public_ip_address() + '/32'
                bubblebot_private_ip_range = bbobjects.get_bbserver().get_private_ip_address() + '/32'

                #Allow bubblebot to connect on this port
                rules.push {IpRanges: [{CidrIp: bubblebot_ip_range}], IpProtocol: 'tcp', FromPort: port, ToPort: port}
                rules.push {IpRanges: [{CidrIp: bubblebot_private_ip_range}], IpProtocol: 'tcp', FromPort: port, ToPort: port}

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

        GroupId = @get_security_group_id(group_name)

        #First, remove any rules we need to get rid of...
        if to_remove.length > 0
            u.log 'Removing: ' + JSON.stringify {GroupId, IpPermissions: to_remove}
            @ec2 'revokeSecurityGroupIngress', {GroupId, IpPermissions: to_remove}

        #Then add the new rules...
        if to_add.length > 0
            try
                u.log 'Adding: ' + JSON.stringify {GroupId, IpPermissions: to_add}
                @ec2 'authorizeSecurityGroupIngress', {GroupId, IpPermissions: to_add}
            catch err
                #If it is a duplicate rule, force a refresh of the cache, then retry
                if String(err).indexOf('InvalidPermission.Duplicate') isnt -1
                    return refresh_and_retry()
                else
                    throw err


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
    #3 hours
    should_delete: (instance, aggressive) ->
        expires = instance.get 'expiration_time'
        if not expires
            #if instance.launch_time is null or NaN, it means it is in the process
            #of getting created, so return false
            if isNaN(instance.launch_time()) or not instance.launch_time()?
                return false

            #if it is newer than 3 hours, we are fine
            threshold = if aggressive then 0.5 else 3
            if Date.now() - instance.launch_time() < threshold * 60 * 60 * 1000
                return false
            #otherwise, delete it
            else
                return true

        #otherwise, check the expiration time
        return Date.now() > expires

    get_region: -> @get 'region'

    get_vpc: -> @get 'vpc'


    tag_resource: (id, Key, Value) ->
        @ec2 'createTags', {
            Resources: [id]
            Tags: [{Key, Value}]
        }

    allow_outside_ssh: ->
        #We allow direct SSH connections to bubblebot to allow for deployments.
        #The security key for connecting should NEVER be saved locally!
        if @id is constants.BUBBLEBOT_ENV
            true
        else
            return @is_development()

    #Creates a new cloudfront distribution.  Right now the only configurable parameter
    #is the origin (we only support oneorigin right now), but can extend this function
    #with more options.
    #
    #Returns the new cloudfront bbobject
    create_cloudfront_distribution: (origin) ->
        params = {
            DistributionConfig: {
                Enabled: true
                CallerReference: String(Date.now())
                Origins: {
                    Quantity: 1
                    Items: [
                        {
                            Id: 'primary'
                            DomainName: origin
                            CustomOriginConfig: {
                                HTTPPort: 80
                                HTTPSPort: 443
                                OriginProtocolPolicy: 'match-viewer'
                                OriginSslProtocols: {
                                    Quantity: 3
                                    Items: ['TLSv1','TLSv1.1','TLSv1.2']
                                }
                            }
                        }
                    ]
                }
                DefaultCacheBehavior: {
                    TargetOriginId: 'primary'
                    ForwardedValues: {
                        QueryString: false
                        Cookies: {
                            Forward: "none"
                        }
                    }
                    TrustedSigners: {
                        Enabled: false
                        Quantity: 0
                    }
                    ViewerProtocolPolicy: 'allow-all'
                    MinTTL: 0
                    AllowedMethods: {
                        Quantity: 2
                        Items: ['GET', 'HEAD']
                    }
                    Compress: true
                }
                Comment: 'Created by Bubblebot to point to origin ' + origin
                PriceClass: 'PriceClass_All'
            }
        }

        #First create in cloudfront
        u.log 'Creating cloudfront distribution: ' + JSON.stringify(params)
        data = @cloudfront 'createDistribution', params
        id = data.Distribution.Id

        #then save it in bubblebot
        distribution = bbobjects.instance 'CloudfrontDistribution', id
        distribution.create this, origin

        return distribution

    #Creates a new s3 bucket.  Name is used to help find a free name for the bucket,
    #and versioning if true turns on versioning
    create_s3_bucket: (name, versioning) ->
        #We keep trying until we find a bucket that does not exist yet.
        attempt = =>
            id = @id + '-' + name + '-' + u.password()

            params = {
                Bucket: id
                CreateBucketConfiguration: {
                    LocationConstraint: @get_region()
                }
            }
            u.log 'Creating s3 bucket: ' + JSON.stringify(params)

            try
                @s3.createBucket params
            catch err
                #TODO: if this is a name conflict error, call attempt again
                if false
                    return attempt()
                else
                    throw err


            if versioning
                @s3.putBucketVersioning {
                    Bucket: id
                    VersioningConfiguration: {
                        Status: 'Enabled'
                    }
                }

            s3bucket = bbobjects.instance 'S3Bucket', id
            s3bucket.create this, name
            return s3bucket

        return attempt()


    #Returns the elastic ip for this environment with the given name.  If no such
    #elastic ip exists, creates it (unless do_not_create is true)
    get_elastic_ip: (name, do_not_create) ->
        key = 'elastic_ip_' + name

        #See if we already have it
        eip_id = @get key
        if eip_id
            return bbobjects.instance 'ElasticIPAddress', eip_id

        if do_not_create
            return null

        #If not, create it
        allocation = @ec2 'allocateAddress', {Domain: 'vpc'}
        eip_instance = bbobjects.instance 'ElasticIPAddress', allocation.AllocationId

        #add it to the database
        eip_instance.create this, this.id + ' ' + name

        #store it for future retrieval
        @set key, eip_instance.id

        return eip_instance

    destroy_elastic_ip: (name) ->
        eip = @get_elastic_ip(name, true)
        if not eip?
            u.reply 'Elastic ip ' + name + ' does not exist'
            return

        msg = 'This will not actually release the elastic ip address, since that is an irreversible operation.  If you really want to release it, do that from the AWS console.  All this does is delete the elastic ip address from the bubblebot database.  You can reverse this via the import_elastic_ip command.  Continue?'
        if not u.confirm msg
            u.reply 'Okay, aborting'
            return

        eip.delete()
        @set 'elastic_ip_' + name, null

        u.reply 'EIP ' + name + ' deleted'

    destroy_elastic_ip_cmd:
        help: 'Removes this elastic ip address from the database\nYou can then transfer it to a different environment'
        params: [
            {name: 'name', required: true, help: 'The name of the elastic ip address to destroy (not the id or public address)'}
        ]

    #Imports an elastic ip already in our account and saves it to this name
    import_elastic_ip: (name) ->
        #see if we have something stored with this name already
        eip = @get_elastic_ip(name, true)
        if eip?
            u.reply 'We already have an elastic ip named ' + name + ' in this environment'
            return

        #find the list of available eips
        data = @ec2 'describeAddresses', {}
        addresses = data.Addresses ? []

        #Filter out addresses that are already in the database
        addresses = (address for address in addresses when not bbobjects.instance('ElasticIPAddress', address.AllocationId).exists())

        if addresses.length is 0
            u.reply "There are no addresses available to import.  If another environment owns the address you want, use destroy_elastic_ip to release that environment's claim on it"
            return

        #Display the choices to the user
        listing = (address.AllocationId + ' ' + address.PublicIp + (if address.InstanceId then ' - ' + address.InstanceId else '') for address in addresses)
        u.reply 'Addresses available for import:\n' + listing.join('\n')

        params = {
            type: 'list'
            options: -> (address.AllocationId for address in addresses)
        }
        to_import = bbserver.do_cast params, u.ask('Enter the id of the address to import')

        eip_instance = bbobjects.instance 'ElasticIPAddress', to_import

        #add it to the database
        eip_instance.create this, this.id + ' ' + name

        #store it for future retrieval
        @set 'elastic_ip_' + name, eip_instance.id

        u.reply 'Imported successfully'

        return null

    import_elastic_ip_cmd:
        help: 'Imports an existing elastic ip address into this environment'
        params: [
            {name: 'name', required: true, help: 'The name to give to the imported ip address'}
        ]
        groups: constants.ADMIN


    #Creates a new redis repgroup with the given name and parameters
    create_redis_repgroup: (name, {CacheNodeType, CacheParameterGroupName, EngineVersion}) ->
        num = 1
        get_id = =>
            #There's a 20 character limit, so we shave off stuff from the environment id
            @id[...20 - (name.length + 5)].replace(/[^a-zA-Z0-9\-]/g,'-') + '-' + name + '-' + num
        id_good = =>
            redisgroup = bbobjects.instance('RedisReplicationGroup', get_id())
            redisgroup.cache_region @get_region()
            return not redisgroup.exists() and not redisgroup.exists_in_aws()
        while not id_good()
            num++

        id = get_id()

        environment = @environment()

        #We need to have a subnet group for this.  Check to see if there's already a subnet
        #group in this environment's VPC
        vpc = environment.get_vpc()
        groups = @elasticache('describeCacheSubnetGroups', {}).CacheSubnetGroups
        for group in groups
            if group.VpcId is vpc
                CacheSubnetGroupName = group.CacheSubnetGroupName
                break

        #If we didnd't find one, create one
        if not CacheSubnetGroupName?
            CacheSubnetGroupName = 'bubblebot-' + vpc
            params = {
                CacheSubnetGroupName
                CacheSubnetGroupDescription: 'Created automatically by Bubblebot for VPC ' + vpc
                SubnetIds: [environment.get_subnet()]
            }
            u.log 'Creating a new cache subnet group: ' + JSON.stringify params
            res = @elasticache 'createCacheSubnetGroup', params

        SecurityGroupIds = [environment.get_database_security_group()]

        params = {
            ReplicationGroupId: id
            ReplicationGroupDescription: 'Created by Bubblebot for environment ' + this.id + ' with name ' + name
            NumCacheClusters: 1
            CacheNodeType
            Engine: 'redis'
            EngineVersion
            CacheParameterGroupName
            CacheSubnetGroupName
            SecurityGroupIds
        }
        u.log 'Creating new Redis Replication Group: ' + JSON.stringify(params)
        @elasticache 'createReplicationGroup', params

        redisgroup = bbobjects.instance('RedisReplicationGroup', id)

        @_import_redis_repgroup name, redisgroup
        return redisgroup


    #Adds the given existing redisgroup to the current environment
    _import_redis_repgroup: (name, redisgroup) ->
        redisgroup.create this, name
        @set 'redis_replication_group_' + name, redisgroup.id

        u.reply 'Imported ' + redisgroup + ' into environment ' + this
        return

    #Retrieves the given redis repgroup for this environment, or returns null if it does not exist
    get_redis_repgroup: (name) ->
        id = @get 'redis_replication_group_' + name
        if not id
            return null
        redisgroup = bbobjects.instance 'RedisReplicationGroup', id
        if not redisgroup.exists()
            return null
        return redisgroup

    #Imports an already existing redis repgroup into this environment,
    import_redis_repgroup: (name, id) ->
        redisgroup = bbobjects.instance 'RedisReplicationGroup', id
        if redisgroup.exists()
            u.reply 'We already have ' + id + ' in the database!  Parent is ' + redisgroup.parent()
            return
        if @get_redis_repgroup(name)?
            u.reply 'This environment already has a redis replication group named ' + name
            return

        redisgroup.cache_region @get_region()
        if not redisgroup.exists_in_aws()
            u.reply 'We could not find a redis replication group with id ' + id
            return

        @_import_redis_repgroup name, redisgroup
        return redisgroup

    import_redis_repgroup_cmd:
        help: "Imports a redis replication group created outside of bubblebot into bubblebot's management"
        params: [
            {name: 'name', required: true, help: 'The name we associate this group with; used to identity its function, create monitoring policies, etc'}
            {name: 'id', required: true, help: 'The id of the group to import'}
        ]
        groups: constants.BASIC


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

    #Creates the service for this environment with the given template name.  Does nothing if it
    #already exists
    create_service: (template_name) ->
        if @get_service template_name
            u.reply 'Service already exists'
            return
        @get_service template_name, true
        u.reply 'Service created'

    create_service_cmd: ->
        help: 'Creates the given service in this environment'
        params: [
            {name: 'name', type: 'list', required: true, options: templates.list.bind(templates, 'Service'), help: 'The name of the service template to create'}
        ]
        groups: constants.BASIC


    #Gets a token that we can use to make calls to bubblebot from this environment
    get_environment_token: ->
        token = @get 'bubblebot_environment_token'
        if token
            return token
        token = u.gen_password 20
        @set 'bubblebot_environment_token', token
        return token

    get_environment_token_cmd:
        help: 'Displays the token for this environment that we use to call bubblebot'
        dangerous: -> @is_production()
        reply: true

    #Gets a credential set for this environment, creating it if it does not exist
    get_credential_set: (set_name) ->
        set = bbobjects.instance 'CredentialSet', @id + '-' + set_name
        if not set.exists()
            set.create this
        return set

    #Lists all the credential sets in this environment
    list_credential_sets: -> @children('CredentialSet')

    list_credential_sets_cmd:
        help: 'Lists all the credential sets in this environment'
        groups: constants.BASIC
        reply: true

    #Destroys the given credential set
    destroy_credential_set: (set_name) ->
        @get_credential_set(set_name).destroy()

    destroy_credential_set_cmd:
        help: 'Destroys a credential set'
        params: [
            {name: 'set name', required: true, help: 'The set to destroy'}
        ]
        reply: 'Credential set destroyed'

    #Retrieves credentials that start with the given key as an object
    get_credential_object: (set_name, key) -> @get_credential_set(set_name).get_credential_object(key)

    get_credential_object_cmd:
        params: [
            {name: 'set_name', required: true, help: 'The name of the credential-set to retrieve'}
            {name: 'key', required: true, help: 'The key of the object'}
        ]
        help: 'Retrieves dot-seperated credentials starting with the given key as an object'
        dangerous: -> not @is_development()
        groups: ->
            if @is_development()
                return constants.BASIC
            else
                return constants.ADMIN
        reply: true


    #Retrieves a credential from this environment
    get_credential: (set_name, name) -> @get_credential_set(set_name).get_credential(name)

    get_credential_cmd:
        params: [
            {name: 'set_name', required: true, help: 'The name of the credential-set to retrieve'}
            {name: 'name', required: true, help: 'The name of the credential to retrieve'}
        ]
        help: 'Retrieves a credential for this environment.'
        dangerous: -> not @is_development()
        groups: ->
            if @is_development()
                return constants.BASIC
            else
                return constants.ADMIN
        reply: true

    #Sets a credential for this environment
    set_credential: (set_name, name, value, overwrite) ->
        if value is 'true'
            value = true
        if value is 'false'
            value = false
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
            if overwrite and @is_development()
                return constants.ADMIN
            else
                return constants.BASIC

    #copies the credential set of another environment
    copy_credential_set: (set_name, copy_from_env, skip_overwrites) ->
        my_set = @get_credential_set(set_name)
        their_set = bbobjects.instance('Environment', copy_from_env).get_credential_set(set_name)
        my_keys = my_set.all_credentials()
        their_keys = their_set.all_credentials()

        if not skip_overwrites
            overlap = []
            overlap = (key for key in their_keys when key in my_keys)
            if overlap.length > 0
                if not u.confirm 'This operation would overwrite the following credentials: ' + overlap.join(', ') + '.  Are you sure you want to proceed?'
                    u.reply 'Okay, aborting'
                    return

        copied = []
        for key in their_keys
            if skip_overwrites and key in my_keys
                continue
            copied.push key
            my_set.set_credential key, their_set.get_credential(key), true, true

        u.reply 'Okay, credentials copied over: ' + copied.join(', ')

    copy_credential_set_cmd: ->
        help: 'Copies a credential set from another environment to this environment'
        params: [
            {name: 'set name', required: true, help: 'The name of the credential-set to set'}
            {name: 'copy from env', required: true, type: 'list', options: bbobjects.list_all_ids.bind(null, 'Environment'), help: 'The name of the environment to copy from'}
        ]


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

    #Recursively removes stale entries from this environment
    remove_stale_entries_from_db: ->
        clean = (object) ->
            u.log 'Checking ' + object
            if typeof(object.children) is 'function'
                clean child for child in object.children()

            if typeof(object.exists_in_aws) is 'function'
                if not object.exists_in_aws()
                    u.reply 'Deleting ' + object
                    object.delete()
                else
                    u.log 'Object still exists: ' + object
        clean this
        u.reply 'Done looking for stale entries'

    remove_stale_entries_from_db_cmd:
        help: 'Recursively deletes children from the database that used to correspond to an AWS object that we can no longer find'
        sublogger: true

    #Goes through and audits instances to see if they should be deleted
    audit_instances: (aggressive, auto_delete_mode, from_scheduled) ->
        #if we are in autodelete mode, we want to do this hourly, if we are in report
        #mode we want to do it daily.  we abort if the mode doesn't match our autodelete setting
        autodelete = if config.get('audit_instances_autodelete', false) then true else false
        auto_delete_mode ?= false
        if from_scheduled
            if autodelete isnt auto_delete_mode
                u.log "Aborting: autodelete #{autodelete} does not match auto_delete_mode #{auto_delete_mode}"
                return
        else
            #If the user called it, we trust what they passed in
            autodelete = autodelete or auto_delete_mode

        all_instances = bbobjects.get_all_instances()
        u.log 'Found the following instances: ' + (String(instance) for instance in all_instances).join(', ')

        to_delete = []

        for instance in all_instances
            #if it is newer than 10 minutes, skip it
            if Date.now() - instance.launch_time() < 10 * 60 * 1000
                u.log 'Newer than 10 minutes: ' + String(instance)

            #If we have a bubblebot role, don't delete this
            else if instance.bubblebot_role()
                u.log 'Has bubblebot role: ' + String(instance)

            #if it is not saved in the database, this is a good candidate for deletion...
            else if not instance.exists()
                u.log 'Not in database: ' + String(instance)
                to_delete.push {instance, reason: 'instance not in database'}

            #otherwise, see if we know why it should exist
            else
                #make sure the parent exists
                parent = instance.parent()
                if not parent?.exists()
                    to_delete.push {instance, reason: 'parent does not exist'}
                    u.log 'Parent does not exist: ' + String(instance)

                else if parent.should_delete?(instance, aggressive)
                    to_delete.push {instance, reason: 'parent says we should delete this'}
                    u.log 'Parent says we should delete: ' + String(instance)
                else
                    u.log 'Parent says we should not delete: ' + String(instance)

        #If autodelete is set, actually do the delete, otherwise just announce.
        msg = (String(instance) + ': ' + reason for {instance, reason} in to_delete).join('\n')

        if to_delete.length > 0
            if autodelete
                msg = 'Automatically cleaning up unused instances:\n\n' + msg
                if from_scheduled
                    u.announce msg
                else
                    u.reply msg

                for {instance, reason} in to_delete
                    instance.terminate()
            else
                msg = "There are some instances that look like they should be deleted.\nTo autodelete them, set bubblebot configuration setting audit_instances_autodelete to true, or call the environment audit_instances command.  They are:\n\n" + msg
                if from_scheduled
                    u.report msg
                else
                    u.reply msg
        else if not from_scheduled
            u.reply "I don't see any instances that look like they should be cleaned up.  You can also try setting the 'aggressive' parameter to true (but be careful, that can interrupt running operations)"

    audit_instances_cmd: ->
        autodelete = config.get('audit_instances_autodelete', false)
        if autodelete
            groups = constants.BASIC
        else
            groups = constants.ADMIN
        params = [
            {name: 'aggressive', type: 'boolean', help: 'If true, deletes servers more aggressively.  Useful if we are running out of instances, but might delete recent failures, etc.'}
        ]
        if not autodelete
            params.push {name: 'auto delete mode', type: 'boolean', help: 'If true, actually deletes the servers instead of just listing them'}

        return {
            help: 'Cleans up old instances.\nSearches ALL environments, not just the one you call it one.\nIf auto_delete_mode is true, actually does the deletes, otherwise just lists them'
            params
            groups
        }



CREDENTIAL_PREFIX = 'credential_'

#Represents a collection of (possibly secure) credentials
bbobjects.CredentialSet = class CredentialSet extends BubblebotObject
    #Adds it to the database
    create: (environment) ->
        prefix = environment.id + '-'
        if @id.indexOf(prefix) isnt 0
            throw new Error 'CredentialSet ids should be of the form [environment id]_[set name]'
        super environment.type, environment.id

    #Destroys this credential set
    destroy: ->
        if not @exists()
            u.expected_error 'no credential set named ' + @id + ' exists'
        @backup 'final'
        @delete()

    set_name: ->
        prefix = @environment().id + '-'
        return @id[prefix.length...]

    set_credential: (name, value, overwrite, no_log) ->
        if not overwrite
            prev = @get CREDENTIAL_PREFIX  + name
            if prev
                u.reply 'There is already a credential for environment ' + @parent().id + ', set ' + @set_name() + ', name ' + name + '. To overwrite it, call this command again with overwrite set to true'
                return

        #Setting to empty string makes it null
        if value is ''
            value = null

        @set CREDENTIAL_PREFIX + name, value
        msg = 'Credential set for environment ' + @parent().id + ', set ' + @set_name() + ', name ' + name
        if not no_log
            u.announce msg
            u.reply msg

    #Get all the keys in this set as an array
    all_credentials: ->
        return (k[CREDENTIAL_PREFIX.length..] for k, v of @properties() when k.indexOf(CREDENTIAL_PREFIX) is 0)

    get_credential: (name) ->
        @get CREDENTIAL_PREFIX + name

    get_credential_object: (key) ->
        result = {}
        prefix = CREDENTIAL_PREFIX + key + '.'
        for k, v of @properties()
            if k.indexOf(prefix) is 0 and k.length > prefix.length
                pieces = k[prefix.length..].split('.')
                targ = result
                for piece in pieces[0...pieces.length - 1]
                    if typeof(targ[piece]) isnt 'object'
                        targ[piece] = {}
                    targ = targ[piece]
                targ[pieces[pieces.length - 1]] = v
        return result

    #Loads a new-line separated list of keys, returns [errors, results].
    #If any key not marked "optional" is missing, errors is a list of missing keys.
    #Otherwise, returns a key:value mapping in results.
    get_list: (items) ->
        errors = []
        results = {}
        for line in items.split('\n')
            if line.trim()
                key = line.trim().split(' ')[0]
                optional = line.indexOf(' optional') isnt -1
                value = @get_credential(key)
                if not value? and not optional
                    errors.push key
                else if value?
                    results[key] = value
        if errors.length > 0
            return [errors]
        else
            return [null, results]


bbobjects.ServiceInstance = class ServiceInstance extends BubblebotObject
    #Adds it to the database
    create: (environment) ->
        prefix = environment.id + '-'
        if @id.indexOf(prefix) isnt 0
            throw new Error 'ServiceInstance ids should be of the form [environment id]_[template]'

        template = @id[prefix.length..]
        templates.verify 'Service', template

        super environment.type, environment.id

    #Destroys this service (backing its metadata up first)
    destroy: ->
        #double-check we want to destroy it...
        if @is_production()
            if not u.confirm 'This is a production service... are you really sure you want to destroy it?'
                u.reply 'Okay, aborting'
                return

        @backup 'final'

        #Destroy the underlying resources
        children = @children()
        for child in children
            if typeof(child.service_destroyed) isnt 'function'
                u.expected_error 'aborting because we do not know how to destroy child ' + child

        child.service_destroyed() for child in children

        @delete()

        u.reply 'Service destroyed successfully'

    destroy_cmd:
        help: 'Destroys this service (backing up its metadata first)'

    #Returns a command tree allowing access to each test
    tests: ->
        tree = new bbserver.CommandTree()
        tree.get_commands = =>
            res = {}
            for test in @template().get_tests()
                res[test.id] = test
            return res
        tree.help = 'Show tests this service runs before deploying'
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
        return @recent_history 'deploy', n_entries

    deploy_history_cmd:
        params: [{name: 'n_entries', type: 'number', default: 10, help: 'The number of entries to return'}]
        help: 'Prints the recent deployment history for this service'
        reply: (entries) ->
            formatted = []
            for {timestamp, reference, properties: {username, deployment_message, rollback}} in entries
                entry = u.print_date(parseInt timestamp) + ' ' + username + ' ' + reference
                entry += '\n' + (if rollback then '(ROLLBACK) ' else '') + deployment_message
                formatted.push entry
            return '\nHistory:\n\n' + formatted.join('\n\n')
        groups: constants.BASIC

    #Checks if we are still using this instance
    should_delete: (instance, aggressive) -> instance.should_delete this, aggressive

    should_delete_ec2instance: (ec2instance, aggressive) ->
        #If we are active, delete any expiration time, and don't delete
        if ec2instance.get('status') is constants.ACTIVE
            ec2instance.set 'expiration_time', null
            return false

        #Otherwise, see if there is an expiration time set
        else
            #If we are in aggressive mode, clean up immediately any build_failed or test_failed boxes
            if aggressive and ec2instance.get('status') in [constants.BUILD_FAILED, constants.TEST_FAILED]
                return true

            expiration = ec2instance.get 'expiration_time'
            #if there isn't an expiration time, set it for 2 hours (or 30 minutes if aggressive)
            if not expiration
                threshold = if aggressive then 0.5 else 2
                ec2instance.set 'expiration_time', Date.now() + threshold * 60 * 60 * 1000
                return false
            #otherwise, see if we are expired
            else
                return Date.now() > expiration

    #We never want to delete the RDS instance for a given service without shutting
    #down the service itself
    should_delete_rdsinstance: (rds_instance, aggressive) -> false

    describe_keys: ->
        endpoint = @endpoint()
        if endpoint and typeof(endpoint) is 'object'
            endpoint = (endpoint.hostname ? endpoint.host) + (if endpoint.port then ':' + endpoint.port else '')
        u.extend super(), {
            version: @version()
            endpoint: @endpoint()
            maintenance: @maintenance()
            servers: @servers().join(', ')
            leader: @get 'leader'
        }

    #Returns an array of the underlying physical resources backing this service
    servers: -> @template().servers this

    #Opens a console connected to the first server for this service
    console: ->
        servers = @servers()
        if servers.length is 0
            u.reply "There are no services associated with this service, so we can't open a console"
            return
        if typeof(servers[0].console) isnt 'function'
            u.reply 'Server ' + servers[0] + ' does not have a console command, so we do not know how to connect to it'
            return
        u.reply 'Connecting to server ' + servers[0]
        servers[0].console()

    console_cmd:
        help: "Opens up a console for interacting with the underlying server.  If there are multiple servers, connects to the first one"
        params: []
        groups: ->
            if @environment().is_production()
                return constants.ADMIN
            else
                return constants.BASIC

    #Prints the log urls for this service
    logs: ->
        servers = @servers()
        urls = []
        for server in servers
            if typeof(server.logs) is 'function'
                url = server.logs()
            else if typeof server.template()?.logs is 'function'
                url = server.template().logs server
            else
                url = null
            if url?
                urls.push url
        if urls.length is 0
            return 'Did not find any log urls'
        else
            return 'Found the following log urls:\n' + urls.join('\n')

    logs_cmd:
        help: 'Queries the underlying servers for log urls'
        groups: constants.BASIC
        reply: true

    #Returns the id of the template for this service
    template_id: ->
        prefix = @parent().id + '-'
        return @id[prefix.length..]

    #Returns the template for this service or null if not found
    template: ->
        template_id = @template_id()
        if not template_id
            return null
        return templates.get('Service', template_id)

    codebase: -> @template().codebase()

    #Returns the endpoint that this service is accessible at
    endpoint: -> @template().endpoint this

    #Waits until this service is available
    wait_for_available: -> @template().wait_for_available this

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
    #
    #Deployment_message is optional... will prompt the user otherwise.  We use special prompting
    #logic so we don't use the _cmd standard prompting.
    deploy: (version, rollback, deployment_message) ->
        #See if a user is blocking deploys
        {blocker_id, explanation} = (@get('blocked') ? {blocker_id: null})
        if blocker_id and blocker_id isnt u.context().user_id
            name = bbobjects.instance('User', blocker_id).name()
            u.reply name + ' has requested that no one deploys to this right now, because: ' + explanation
            command = u.context().command.path[...-1].concat(['unblock'])
            u.reply 'To override this, say: ' + command
            return

        try
            #If this is the initial deploy, we want to be in maintenance mode until the deploy succeeds
            if not @version() and not @get('maintenance')
                temporary_maintenance = true
                @set 'maintenance', true

            @template().deploy this, version, rollback, deployment_message
        finally
            #Undo the set maintenance above
            if temporary_maintenance
                @set 'maintenance', false

    deploy_cmd:
        sublogger: true
        params: [{name: 'version', required: true, help: 'The version to deploy'}, {name: 'rollback', type: 'boolean', help: 'If true, allows deploying versions that are not ahead of the current version'}]
        help: 'Deploys the given version to this service.  Ensures that the new version is tested and ahead of the current version'
        groups: constants.BASIC

    #Returns the current version of this service
    version: -> @get 'version'

    on_startup: ->
        super()
        u.context().server?.monitor this
        @check_leader()

    #Indicates that we should try to switch to the same version as the other service
    set_leader: (service_id) ->
        @set 'leader', service_id
        u.reply this + ' is set to follow leader ' + service_id

    set_leader_cmd:
        help: "Sets another service as the leader for this service, meaning that when you deploy to that service, we try to deploy to this service"
        groups: constants.ADMIN
        params: [{name: 'service id', required: true, help: 'The version to deploy to', type: 'list', options: bbobjects.list_all_ids.bind(null, 'ServiceInstance')}]

    #If we have a leader, see if it is ahead of us; if so, deploy
    check_leader: ->
        leaders = @get 'leader'
        if not leaders
            u.log 'This instance does not have a leader'
            return

        leader_versions = []
        for leader_id in leaders.split(',')
            leader = bbobjects.instance('ServiceInstance', leader_id)
            if not leader.exists()
                u.report this + ' has leader ' + leader_id + ' but that id does not exist'
                return

            leader_version = leader.codebase().canonicalize leader.version()
            if not leader_version
                u.report this + ' has leader ' + leader_id + ' but leader does not have a version set'
                return
            leader_versions.push leader_version

        my_version = @codebase().canonicalize @version()
        leader_version = leader_versions.join('-')
        if my_version is leader_version
            return

        #make sure the leader version is ahead of the current version
        if my_version and not @codebase().ahead_of leader_version, my_version
            u.report this + ' is set up to follow ' + leaders + ' but leader version ' + leader_version + ' is not ahead of our version ' + my_version
            return

        #do a deploy
        u.reply this + ' is set to follow ' + leaders + ', so deploying ' + leader_version + ' to it'
        @template().deploy this, leader_version, false, 'Following leader: ' + leaders

    #Returns a description of how this service should be monitored
    get_monitoring_policy: ->
        if not @exists()
            return {monitor: false}
        @template().get_monitoring_policy this

    #Returns true if this service is in maintenance mode (and thus should not be monitored)
    maintenance: ->
        #if we don't have a version set, we are in maintenance mode
        if not @version()
            return true

        #if the maintenance property is set, we are in maintenance mode
        if @get 'maintenance'
            return true

        return false

    #Sets whether or not we should enter maintenance mode
    set_maintenance: (turn_on) ->
        @set 'maintenance', turn_on
        u.reply 'Maintenance mode is ' + (if turn_on then 'on' else 'off')
        u.context().server._monitor.update_policies()

    set_maintenance_cmd:
        params: [{name: 'on', type: 'boolean', required: true, help: 'If true, turns maintenance mode on, if false, turns it off'}]
        help: 'Turns maintenance mode on or off'
        groups: constants.BASIC

    #Replaces the underlying boxes for this service
    replace: ->
        @template().replace this
        #Make sure we update monitoring policies since endpoints may have changed
        u.context().server?._monitor.update_policies()

    replace_cmd:
        sublogger: true
        help: 'Replaces the underlying boxes for this service'
        groups: constants.BASIC
        reply: 'Replace complete'

    #Restarts the underlying boxes for this service
    restart: (hard) ->
        for server in @servers()
            server.restart?(hard)

    restart_cmd:
        sublogger: true
        help: 'Restarts the underlying boxes for this service'
        groups: constants.BASIC
        reply: 'Restart complete'
        dangerous: true


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

    #Removes from the database
    destroy: ->
        @delete()
        u.reply 'Build ' + @id + ' removed from the database'

    destroy_cmd:
        help: 'Removes this EC2Build from the database'

    #Get the lowest version of this build in the given region.  Useful for building
    #lowest-common-denominator AMIs
    #
    #Returns null if missing
    lowest_version: (region) ->
        environment = bbobjects.get_default_dev_environment region
        lowest = null
        for ec2instance in environment.describe_instances({})
            if ec2instance.template() is @template()
                version = ec2instance.get 'software_version'
                if version
                    if not lowest? or @codebase().ahead_of lowest, version
                        lowest = version
        return lowest

    #Retrieves the codebase object for this build
    codebase: -> @template().codebase()

    #Used internally by build and create ami to build a machine
    _build: (parent, size, name, ami, software_to_install, do_verify) ->
        environment = parent.environment()

        id = environment.create_server_raw ami, size, null, @template().get_security_group_id?(environment)
        ec2instance = bbobjects.instance 'EC2Instance', id
        try
            ec2instance.create parent, name, constants.BUILDING, @id

            #wait for ssh
            ec2instance.wait_for_ssh()
            u.log ec2instance + ' is available over ssh, installing software'

            #install software
            software_to_install ec2instance
            u.log 'done installing software on ' + ec2instance + ', verifying...'

            #verify software is installed and mark complete
            if do_verify
                @template().verify ec2instance
                u.log 'installation on ' + ec2instance + ' verified, marking build complete'
                ec2instance.set_status constants.BUILD_COMPLETE

            return ec2instance

        catch err
            #if we had an error building it, set the status to build failed
            ec2instance.set_status constants.BUILD_FAILED
            err.failed_build = ec2instance
            throw err

    #Creates a server with the given size owned by the given parent, and with the
    #given version of the software installed
    build: (parent, size, name, version) ->
        ami = @get_ami parent.environment().get_region()
        software = @template().software(version, parent)
        ec2instance = @_build parent, size, name, ami, software, true
        ec2instance.set 'software_version', version
        return ec2instance

    #Gets the current AMI for this build in the given region.  If there isn't one, creates it.
    get_ami: (region) ->
        #If we don't have software to install on an ami, then the ami is just the base ami
        if not @template().ami_software()?
            return @template().base_ami(region)

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

    on_startup: ->
        super()
        if not @template().ami_software()?
            return

        interval = @template().get_replacement_interval()
        if interval
            @schedule_recurring interval, 'refresh', 'replace_ami_all'

    #Replaces the AMI for all active regions
    replace_ami_all: ->
        if not @template().ami_software()?
            u.reply 'this build does not have an ami'
            return

        for region in bbobjects.list_regions()
            @replace_ami(region)

    #Replaces the ami for this region
    replace_ami: (region) ->
        if not @template().ami_software()?
            u.reply 'this build does not have an ami'
            return

        #make sure we exist in the database
        if not @exists()
            @create()

        u.reply 'Replacing AMI for ' + this + ' in region ' + region

        environment = bbobjects.get_default_dev_environment region

        #Build an instance to create the AMI from
        template = @template()
        ec2instance = @_build environment, template.ami_build_size(), 'AMI build for ' + this, template.base_ami(region), template.ami_software(@lowest_version(region)), false
        ec2instance.set 'expiration_time', Date.now() + 2 * 60 * 60 * 1000

        #Create the ami
        name = @id + ' ' + u.print_date(Date.now()).replace(/[^a-zA-Z0-9]/g, '-')
        new_ami = environment.create_ami_from_server ec2instance, name

        #Retrieve the existing AMI if there is one
        key = 'current_ami_' + region
        old_ami = @get key

        #Save it as the new default AMI for this region
        @set key, new_ami

        msg = 'Replaced AMI for ' + this + ' in region ' + region + ': new AMI ' + new_ami
        if u.current_user()
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
        sublogger: true
        params: [{name: 'region', required: true, help: 'The region to replace the AMI for'}]
        help: 'Replaces the current AMI for this build in the given region'
        groups: constants.BASIC

    #Notifies this ec2instance that we are about to start sending external
    #traffic to it.  This is an opportunity to run any logic that we want to do
    #right before putting the box into production
    pre_make_active: (ec2instance, service) -> @template().pre_make_active? ec2instance, service

    #Tells this ec2 instance that it is receiving external traffic.
    #Some builds might want notification given to the box.
    #We also update our status
    make_active: (ec2instance) ->
        #Set the status
        ec2instance.set_status constants.ACTIVE

        #Inform the instance, if appropriate
        @template().make_active ec2instance

    #Tells this ec2 instance to perform a graceful shutdown, and schedules a termination
    graceful_shutdown: (ec2instance) ->
        template = @template()

        #set the status to finished
        ec2instance.set_status constants.FINISHED

        #Schedule a termination
        termination_delay = template.termination_delay()
        ec2instance.schedule_once termination_delay, 'terminate'

        #Tell the server to begin its graceful shutdown
        template.graceful_shutdown ec2instance

    #Returns the default server size for this build.  Can optionally pass in an object
    #that we use to look at for more details (ie, whether or not it is production, etc.)
    default_size: (instance) -> @template().default_size instance

    #Returns a list of valid sizes for this build.  Can optionally pass in an object
    #that we use to look at for more details (ie, whether or not it is production, etc.)
    valid_sizes: (instance) -> @template().valid_sizes instance

    #Creates a copy of this build for running tests
    #
    #Version is the version of the build to create
    #
    #size is optional, defaults to calling default_size on the QA environment
    create_test_instance: (version, size) ->
        #Create a new instance with a random id
        environment = bbobjects.get_default_qa_environment()

        size ?= @default_size environment

        ec2instance = @build environment, size, 'Test Instance for ' + @id, version

        #Set the box to expire in an hour
        ec2instance.set 'expiration_time', Date.now() + 60 * 60 * 1000

        return ec2instance

    #Runs the given test passing in a test instance.  Handles cleaning up the test
    #instance afterwards
    #
    #size is optional
    run_with_test_instance: (version, size, test) ->
        #if size was omitted, shift params over
        if typeof(size) is 'function'
            test = size
            size = null

        #Allows injecting a previously failed test
        if u.context().use_this_instance
            ec2instance = u.context().use_this_instance
        else
            try
                ec2instance = @create_test_instance(version, size)
            catch err
                if err.failed_build
                    u.log err.stack ? err
                    throw new Error 'there was an error starting the test server.  error logged above.  the test server id is ' + err.failed_build.id
                else
                    throw err

        try
            result = test ec2instance
            return result
        catch err
            result = false
            throw err
        finally
            if result
                u.log 'Tests pass, so terminating test server'
                ec2instance.terminate()
            else
                ec2instance.test_failed(version)
                u.log 'Tests failed.  Test server can be inspected here: ' + ec2instance.get_public_dns() + '\nTest server id is ' + ec2instance.id




bbobjects.Test = class Test extends BubblebotObject
    #Creates in the database
    create: ->
        templates.verify 'Test', @id
        super null, null, {}

    template: -> templates.get('Test', @id)

    is_tested: (version) -> @find_entries('test_passed', version).length > 0

    #Can be null! Codebase is not required, it is optional (to expose the canonicalize function)
    codebase: -> @template().codebase()

    #Runs the tests against this version
    run: (version) ->
        codebase = @codebase()
        if codebase
            version = codebase.ensure_version version
        u.reply 'Running test ' + @id + ' on version ' + version
        try
            u.context().currently_running_test = @id
            result = @template().run version
            u.log 'Test ' + (if result then 'passed' else 'failed') + ' with return value ' + result
        catch err
            u.log 'Test failed because of error: ' + (err.stack ? err)
            result = false
        if result
            u.reply 'Test ' + @id + ' passed on version ' + version
            @mark_tested version
        else
            u.reply 'Test ' + @id + ' failed on version ' + version + ': ' + u.context().get_transcript()
        return result

    #Returns an array of the last n_entries versions that passed the tests.  Does not count tests marked
    #as skip_tests unless include_skipped is set to true
    good_versions: (n_entries, include_skipped) ->
        versions = @recent_history 'test_passed', n_entries
        return (reference for {reference, properties} in versions when include_skipped or not properties?.skip_tests)

    good_versions_cmd:
        help: 'Returns a list of versions that passed the test'
        params: [
            {name: 'n_entries', type: 'number', default: 10, help: 'Number of entries to return.  May return less if not including ones where we skipped the test'}
            {name: 'include_skipped', type: 'boolean', default: false, help: 'If set, includes versions where tests were skipped instead of being run'}
        ]
        reply: (entries) ->
            return 'Passed this test recently:\n' + entries.join('\n')
        groups: constants.BASIC

    run_cmd:
        sublogger: true
        params: [{name: 'version', required: true, help: 'The version of the codebase to run this test against'}]
        help: 'Runs this test against the given version'
        groups: constants.BASIC

    #Marks this version as tested without actually running the tests
    skip_tests: (version) ->
        codebase = @codebase()
        if codebase
            version = codebase.ensure_version version

        @add_history 'test_passed', version, {skip_tests: true}
        u.report 'User ' + u.current_user() + ' called skip tests on ' + @id + ', version ' + version

    skip_tests_cmd:
        help: 'Marks this version as tested without actually running the tests'
        params: [{name: 'version', required: true, help: 'The version of the codebase to mark as tested'}]
        reply: 'Version marked as tested'
        groups: constants.BASIC

    mark_tested: (version) ->
        u.log 'Marking test ' + @id + ' version ' + version + ' as tested'
        @add_history 'test_passed', version

    #Called to erase a record of a successful test pass
    mark_untested: (version) ->
        @delete_entries 'test_passed', version


#Based class for "boxes" like an EC2 instance or an RDS instance
class AbstractBox extends BubblebotObject
    #Checks to see if the owner still needs this instance
    follow_up: ->
        owner = @owner()
        if not owner
            u.report 'Following up on destroying a box without an owner: ' + this
            return

        still_need = bbserver.do_cast 'boolean', u.ask('Hey, do you still need the server you created called ' + this + '?  If not, we will delete it for you', owner.id)
        if still_need
            params = {
                type: 'number'
                validate: bbobjects.validate_destroy_hours
            }
            hours = bbserver.do_cast params, u.ask("Great, we will keep it for now.  How many more hours do you think you need it around for?", owner.id)
            interval = hours * 60 * 60 * 1000
            @set 'expiration_time', Date.now() + (interval * 2)
            @schedule_once interval, 'follow_up'
        else
            u.message owner.id, "Okay, we are terminating the server now..."
            @terminate()


bbobjects.EC2Instance = class EC2Instance extends AbstractBox
    #Creates in the database and tags it with the name in the AWS console
    create: (parent, name, status, build_template_id) ->
        templates.verify 'EC2Build', build_template_id
        super parent.type, parent.id, {name, status, build_template_id}

        @environment().tag_resource @id, 'Name', name + ' (' + status + ')'

    #Double-dispatch for should_delete
    should_delete: (owner, aggressive) -> owner.should_delete_ec2instance(this, aggressive)

    toString: -> "#{@id} #{@name()}"

    #Sets this instance to expire ms miliseconds in the future
    set_expiration: (ms) -> @set 'expiration_time', Date.now() + ms

    #Re-applies the EC2 build to this instance
    rebuild: (version) ->
        if not version
            version = @get 'software_version'
            if not version
                u.expected_error 'No software_version set... pass in an explicit version'
        if @is_production()
            u.expected_error 'Cannot rebuild instances in production -- this is for development purposes only'
        if not @template()
            u.expected_error 'This ec2 instance does not have a template set'
        version = @template().codebase().ensure_version version
        @template().software(version, @parent()) this
        u.reply 'Rebuild complete'

    rebuild_cmd:
        help: 'Attempts to re-install the software on this server'
        params: [
            {name: 'version', help: 'The version of this software to install.  Defaults to whatever is currently installed'}
        ]
        dangerous: -> not @is_development()
        groups: constants.BASIC
        sublogger: true

    #Runs the restart command for this box
    #If aws is true, restarts via aws as well via a stop and start (not reboot, which isn't always effective)
    restart: (aws) ->
        if aws
            u.reply 'Stopping the instance...'
            @ec2 'stopInstances', {InstanceIds: [@id]}
            u.log 'Waiting for server to be stopped'
            @wait_for_running(20, 'stopped')
            u.reply 'Starting the instance...'
            @ec2 'startInstances', {InstanceIds: [@id]}
            u.reply 'Waiting for the instance to be accessible via ssh...'
            @wait_for_ssh()

        u.reply 'Doing a software restart...'
        if not @template()
            u.reply 'Cannot do a software restart because we do not have a template set'
            return
        @template().restart this
        u.reply 'Restart complete'


    restart_cmd:
        help: 'Restarts this server'
        params: [
            {name: 'aws', type: 'boolean', help: 'If true, we restart at the AWS level, not just the software level'}
        ]
        dangerous: -> @is_production()
        groups: (aws) -> if aws and @is_production() then constants.ADMIN else constants.BASIC
        sublogger: true

    #Updates the status and adds a ' (status)' to the name in the AWS console
    set_status: (status) ->
        u.log 'setting status of ' + this + ' to ' + status
        @set 'status', status

        @environment().tag_resource @id, 'Name', @name()
        @template().on_status_change? this, status

    name: ->
        status = @get('status')
        if status
            status = ' (' + status + ')'
        else
            status = ''
        return (@get('name') ? @bubblebot_role()) + status

    describe_keys: ->
        expiration = @get('expiration_time')
        if expiration
            expires_in = u.format_time(expiration - Date.now())

        return u.extend super(), {
            name: @name()
            status: @get 'status'
            aws_status: @get_state()
            software_version: @get 'software_version'
            template: @get 'build_template_id'
            public_dns: @get_public_dns()
            address: @get_address()
            private_address: @get_private_ip_address()
            bubblebot_role: @bubblebot_role()
            tags: (k + ': ' +v for k, v of @get_tags()).join(', ')
            age: u.format_time(Date.now() - @launch_time())
            InstanceType: @get_data()?.InstanceType
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

    run_cmd:
        help: "Runs the given command on the server."
        params: [{name: 'command', required: true, help: 'The command to run'}]
        groups: constants.ADMIN
        reply: true

    #Opens up a console for interacting with the server
    console: (operation_mode) ->
        u.context().create_sub_logger (not operation_mode)
        session = bbserver.create_web_session 'SSH to ' + String(this), operation_mode

        u.reply u.context().server.get_server_url() + '/session/' + session.id

        logger = u.get_logger('log')

        #Create an interactive stream connecting us to the server...
        server_stream = ssh.shell @get_address(), @environment().get_private_key()
        server_stream.on 'data', (data) ->
            session.write data
            if operation_mode
                logger data.toString('utf8')
        server_stream.stderr.on 'data', (data) ->
            session.write data
            if operation_mode
                logger data.toString('utf8')
        server_stream.on 'close', ->
            session.write '\n\nConnection to server closed'
            if operation_mode
                logger 'Connection to server closed'

        while (input = session.get_next_input()) not in ['exit', 'cancel', session.CLOSED]
            u.log 'Input: ' + input
            try
                server_stream.write input + '\n'
            catch err
                session.write '\n' + err.stack + '\n'

        #Close our connection with the server
        server_stream.end()

        message = 'Interactive session finished.  Last input was: ' + input
        u.log message
        session.close message


    console_cmd:
        help: "Opens up a console for interacting with the server directly"
        params: [{name: 'operation_mode', type: 'boolean', help: 'If specified, disables timeouts and everything'}]
        groups: ->
            if @environment().is_production()
                return constants.ADMIN
            else
                return constants.BASIC

    upload_file: (path, remote_dir) ->
        ssh.upload_file @get_address(), @environment().get_private_key(), path, remote_dir

    write_file: (data, remote_path) ->
        ssh.write_file @get_address(), @environment().get_private_key(), remote_path, data

    #Makes sure we have fresh metadata for this instance
    refresh: -> @describe_instances({InstanceIds: [@id]})

    #Gets the amazon metadata for this instance, refreshing if it is null or if force_refresh is true
    #if no_refresh is true, returns null if we don't have data yet
    get_data: (force_refresh, no_refresh) ->
        if force_refresh or not instance_cache.get(@id)
            if no_refresh
                return null
            @refresh()
        return instance_cache.get(@id)

    #Fetches the current state of this instance
    get_configuration: -> @get_data(true)

    get_configuration_cmd:
        help: 'Fetches the configuration information about this server from AWS'
        reply: true

        groups: constants.BASIC

    exists_in_aws: ->
        try
            @refresh()
            return true
        catch err
            if String(err).indexOf('InvalidInstanceID.NotFound') isnt -1
                return false
            throw err

    #Waits til the server is in the running state
    wait_for_running: (retries = 20, target_state = 'running') ->
        u.log 'waiting for server to be ' + target_state + ' (' + retries + ')'
        if @get_state(true) is target_state
            return
        else if retries is 0
            throw new Error 'timed out while waiting for ' + @id + ' to be ' + target_state + ': ' + @get_state()
        else
            u.pause 10000
            @wait_for_running(retries - 1, target_state)

    #When the server was launched
    launch_time: -> (new Date(@get_data().LaunchTime)).valueOf()

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
        if String(err).indexOf('ECONNREFUSED') isnt -1
            return true
        if String(err).indexOf('All configured authentication methods failed') isnt -1
            return true
        return false


    #Returns the state of the instance.  Set force_refresh to true to check for changes.
    get_state: (force_refresh) -> @get_data(force_refresh).State.Name

    #Inform this instance it was used for running a test that failed
    test_failed: (version) ->
        @set_status constants.TEST_FAILED
        #we save the version and test so that we can re-run:
        test = u.context().currently_running_test
        if test?
            @set 'test_failure', {version, test}

        #Hook for informing the template
        @template().test_failed? this, version


    #Reruns the given version and test against this instance
    rerun: ->
        failure_info = @get 'test_failure'
        if not failure_info
            u.expected_error 'Could not retrieve a test failure for this instance'
        u.log 'Failure info: ' + JSON.stringify failure_info
        {version, test} = failure_info
        u.reply 'Running test ' + test + ' against this instance (version ' + version + ')'
        u.context().use_this_instance = this
        bbobjects.instance('Test', test).run(version)

    rerun_cmd:
        help: 'Re-run a failed test against this box'
        sublogger: true
        groups: constants.BASIC

    #Called by a parent service that's being destroyed
    service_destroyed: -> @terminate()

    terminate: ->
        u.log 'Terminating server ' + @id

        #first update the status if we have this in the database
        if @exists()
            @set_status constants.TERMINATING

        #then do the termination...
        data = @ec2 'terminateInstances', {InstanceIds: [@id]}
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
            if @environment().is_production() or @owner()?.id isnt u.current_user().id
                return constants.ADMIN
            else
                return constants.BASIC


    #Writes the given private key to the default location on the box
    install_private_key: (path) ->
        software.private_key(path) this

    #Returns the address bubblebot can use for ssh / http requests to this instance
    get_address: -> @get_public_ip_address()

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

    bubblebot_role: -> @get_tags()[config.get('bubblebot_role_tag')]




#Storage for credentials that we don't store in the bubblebot database
rds_credentials = {}

#Represents an RDS instance.
bbobjects.RDSInstance = class RDSInstance extends AbstractBox
    constructor: (type, id) ->
        #there are other rules too but we can add them as they become problems
        if id.indexOf('_') isnt -1
            throw new Error 'rdsinstance ids cannot contain underscores: ' + id
        super type, id

    #Creates a new rds instance.  We take:
    #
    #The parent
    #permanent_options -- things we don't allow changing after creation {Engine, EngineVersion}
    #                     If cloned_from is present, uses the restoreDBInstanceToPointInTime operation
    #                     to clone the given DB Instance
    #
    #sizing_options -- things that control the DB size / cost, can be changed after creation
    #                  {AllocatedStorage, DBInstanceClass, BackupRetentionPeriod, MultiAZ, StorageType, Iops, outside_world_accessible}
    #                   outside_world_accessible means we set 0.0.0.0 as having access to it.  We always set the RDS parameter
    #                   PubliclyAccessible to true because otherwise bubblebot can't access it.
    #
    #credentials -- optional.  If not included, we generate credentials automatically and store them
    #in the bubblebot database.  If included, caller is responsible for storing the credentials.
    #
    #bootstrap -- this is for bootstrapping bbdb.  if 'just_create', creates without writing to
    #the database; if 'just_write', writes to the database without creating
    create: (parent, permanent_options, sizing_options, credentials, bootstrap) ->
        {Engine, EngineVersion, RestoreTime, cloned_from} = permanent_options ? {}
        {AllocatedStorage, DBInstanceClass, BackupRetentionPeriod, MultiAZ, StorageType, Iops, outside_world_accessible} = sizing_options ? {}

        if bootstrap is 'just_create' and not credentials?
            throw new Error 'Need to include credentials when using just_create'
        if bootstrap? and bootstrap not in ['just_create', 'just_write']
            throw new Error 'unrecognized bootstrap: ' + bootstrap

        #Add to the database
        if bootstrap isnt 'just_create'
            super parent.type, parent.id

        if bootstrap is 'just_write'
            return

        #If we are cloning the database, we cannot change the username, so we need to
        #go with the original username
        get_actual_username = (preferred) ->
            if not cloned_from
                return preferred
            return bbobjects.instance('RDSInstance', cloned_from).get('MasterUsername') ? preferred

        if credentials
            {MasterUsername, MasterUserPassword} = credentials
            MasterUsername = get_actual_username MasterUsername
            @override_credentials MasterUsername, MasterUserPassword
        else
            MasterUsername = get_actual_username 'bubblebot'
            MasterUserPassword = u.gen_password()
            @set 'MasterUsername', MasterUsername
            @set 'MasterUserPassword', MasterUserPassword

        #Save our outside_world_accessible setting
        @set 'outside_world_accessible', outside_world_accessible

        VpcSecurityGroupIds = [@environment().get_database_security_group(outside_world_accessible)]
        DBSubnetGroupName = @environment().get_rds_subnet_group()

        StorageEncrypted = (DBInstanceClass not in ['db.t2.micro', 'db.t2.small', 'db.t2.medium'])
        if not StorageEncrypted
            u.log 'Creating unencrypted database (DBInstanceClass too small: ' + DBInstanceClass + ')'

        #If this is a clone via restore from point in time, update the parameters to
        #reflect that
        if cloned_from?
            params = {
                SourceDBInstanceIdentifier: cloned_from
                TargetDBInstanceIdentifier: @id

                DBInstanceClass
                MultiAZ
                StorageType
                Iops
                PubliclyAccessible: true #This always needs to be true to allow bubblebot access

                DBSubnetGroupName
            }

            #Add either RestoreTime or UseLatestRestorableTime
            if RestoreTime
                params.RestoreTime = RestoreTime
            else
                params.UseLatestRestorableTime = true

            u.log 'Restoring RDS instance from point in time: ' + JSON.stringify params
            @rds 'restoreDBInstanceToPointInTime', params
            u.log 'Restore complete'

            @get_configuration true

            #Need to set the new credentials and update the security group
            params = {
                DBInstanceIdentifier: @id
                VpcSecurityGroupIds
                MasterUserPassword
            }

            #We have to wait for it to be available before we can modify it.  We set a
            #very long timeout because copying the data can take a while
            @wait_for_available(1000, ['available'])
            u.log 'Updating the credentials; setting MasterUserPassword, and changing VpcSecurityGroupIds to ' + JSON.stringify(VpcSecurityGroupIds)
            @rds 'modifyDBInstance', params

            u.log 'Modification command sent, waiting for it to complete'
            @wait_for_modifications_complete()

            u.log 'Modification complete: ' + JSON.stringify(@get_configuration true)

            u.log 'Sending test command'
            u.log JSON.stringify (new databases.Postgres this).query('SELECT 1').rows
            u.log 'test command successful'

        else
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
                PubliclyAccessible: true #This always needs to be true to allow bubblebot access

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
            @rds 'createDBInstance', params

        u.log 'RDS instance succesfully created with id ' + @id
        return null

    #Double-dispatch for should_delete
    should_delete: (owner, aggressive) -> owner.should_delete_rdsinstance(this, aggressive)

    #When this RDS instance was created
    launch_time: -> (new Date(@get_configuration().InstanceCreateTime)).valueOf()

    #If this is a special bubblebot instance, return a flag that indicates that
    bubblebot_role: ->
        if @id.indexOf('bubblebot-bbdbservice-') is 0
            return 'BBDB'
        else
            return null

    describe_keys: -> u.extend super(), {
        launch_time: u.print_date @launch_time()
        bubblebot_role: @bubblebot_role()
    }

    #Restarts the instance.  "hard" is ignored for now -- it's a parameter
    #that comes from calling restart at the service level(we could map it to force failover,
    #I guess)
    restart: (hard) ->
        u.log 'Calling rebootDBInstance on ' + this
        @rds 'rebootDBInstance', {DBInstanceIdentifier: @id}
        u.log 'Reboot finished on ' + this
        @get_configuration true

    restart_cmd:
        sublogger: true
        help: 'Restarts the database'
        reply: 'Restart complete'
        dangerous: -> @is_production()
        groups: (aws) -> if aws and @is_production() then constants.ADMIN else constants.BASIC
        sublogger: true


    #returns true if any of the sizing options changes could cause downtime
    are_changes_unsafe: (sizing_options) ->
        {AllocatedStorage, DBInstanceClass, BackupRetentionPeriod, MultiAZ, StorageType, Iops} = sizing_options
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
        {AllocatedStorage, DBInstanceClass, BackupRetentionPeriod, MultiAZ, StorageType, Iops, outside_world_accessible} = sizing_options

        if @are_changes_unsafe(sizing_options) and not unsafe_okay
            throw new Error 'making unsafe changes without unsafe_okay'

        #If we are change the storage type we have to reboot afterwards
        reboot_required = StorageType?

        #If we are changing outside-world accessible, we need to update the list of security groups
        if outside_world_accessible?
            @set 'outside_world_accessible', outside_world_accessible
            VpcSecurityGroupIds = [@environment().get_database_security_group(outside_world_accessible)]

        params = {
            ApplyImmediately: true
            AllocatedStorage
            DBInstanceClass
            BackupRetentionPeriod
            MultiAZ
            StorageType
            Iops
        }

        @wait_for_available(100, ['available'])

        u.log 'Resizing RDB ' + @id + ' with params: ' + JSON.stringify params

        @rds 'modifyDBInstance', params

        if reboot_required
            u.log 'Reboot required. Waiting for instance to be available, then doing reboot'
            @get_configuration true
            @wait_for_available(100, ['available'])
            @rds 'rebootDBInstance', {DBInstanceIdentifier: @id}
            u.log 'Reboot initiated'

        u.log 'Waiting for modifications to complete'
        @wait_for_modifications_complete()
        u.log 'Resizing RDB succesful'

        return null

    #Waits til the instance is in the available state
    wait_for_available: (retries = 100, available_statuses) ->
        available_statuses ?= ['available', 'backing-up', 'modifying']

        #first do a quick check using cached data...
        if @get_configuration().DBInstanceStatus in available_statuses
            return

        #Then log and refresh the data
        u.log 'waiting for rds instance to be to be available (' + retries + ')'
        if @get_configuration(true).DBInstanceStatus in available_statuses
            return
        else if retries is 0
            throw new Error 'timed out while waiting for ' + @id + ' to be available: ' + @get_configuration(true).DBInstanceStatus
        else
            u.pause 10000
            @wait_for_available(retries - 1, available_statuses)

    #Make sure we are no longer modifying anything
    wait_for_modifications_complete: ->
        retries = 20
        ready = false
        while not ready
            u.pause 10000
            config = @get_configuration(true)
            ready = true

            if config.DBInstanceStatus isnt 'available'
                u.log 'Waiting for DBInstanceStatus to be available: ' + config.DBInstanceStatus
                ready = false

            for k, v of config.PendingModifiedValues ? {}
                u.log 'Waiting for Pending Modification: ' + k
                ready = false

            for membership in config.OptionGroupMemberships ? []
                if membership.Status isnt 'in-sync'
                    u.log 'Waiting for OptionGroupMembership ' + membership.OptionGroupName + ' to be in-sync: ' + membership.Status
                    ready = false

            for parameter_group in config.DBParameterGroups ? []
                if parameter_group.ParameterApplyStatus isnt 'in-sync'
                    u.log 'Waiting for DBParameterGroup ' + parameter_group.DBParameterGroupName + ' to be in-sync: ' + parameter_group.ParameterApplyStatus
                    ready = false

            for security_group in config.VpcSecurityGroups ? []
                if security_group.Status isnt 'active'
                    u.log 'Waiting for VpcSecurityGroup ' + security_group.VpcSecurityGroupId + ' to be in active: ' + security_group.Status
                    ready = false

            if not ready
                if retries is 0
                    throw new Error 'timed out waiting for modifications to complete'
                else
                    u.log 'Retries remaining: ' + retries
                    retries--

        u.log 'Done waiting for modifications to complete'


    #Fetches the current state of this instance from RDS
    get_configuration: (force_refresh) ->
        if not force_refresh and rds_cache.get @id
            return rds_cache.get @id

        data = @rds 'describeDBInstances', {DBInstanceIdentifier: @id}
        res = data.DBInstances?[0]
        rds_cache.set @id, res
        return res

    get_configuration_cmd:
        help: 'Fetches the configuration information about this database from RDS'
        reply: true

        groups: constants.BASIC

    #Returns true if this instance exists in AWS
    exists_in_aws: ->
        try
            @get_configuration(true)
            return true
        catch err
            if String(err).indexOf('DBInstanceNotFound') is -1 and String(err).indexOf('InvalidParameterValue: Invalid database identifier') is -1
                throw err
            return false

    #Store credentials for accessing this database... override checking the database for them
    override_credentials: (username, password) ->
        rds_credentials[@id] = {username, password}

    #Returns the endpoint we can access this instance at.
    #
    #Can optionally override credentials or database
    endpoint: (credentials) ->
        @wait_for_available()

        if credentials?
            username = credentials.MasterUsername
            password = credentials.MasterUserPassword
            @override_credentials username, password

        endpoint = {}
        data = @get_configuration()?.Endpoint
        if not data
            return null

        #See if we have stored credentials
        {username, password} = rds_credentials[@id] ? {}

        endpoint.host = data.Address
        endpoint.port = data.Port
        endpoint.user = username ? @get 'MasterUsername'
        endpoint.password = password ? @get 'MasterUserPassword'

        #allow overriding database (but not for bubblebot since that breaks things)
        if @id.indexOf('bubblebot-bbdbservice-') isnt 0
            database = @get('database')
        endpoint.database = database ? 'postgres'

        return endpoint

    #Called by a parent service that's being destroyed
    service_destroyed: -> @terminate(true)

    #Destroys this RDS instance.  As an extra safety layer, we only terminate production
    #instances if terminate prod is true
    terminate: (terminate_prod, assume_production, SkipFinalSnapshot) ->
        if @get_configuration(true).DBInstanceStatus is 'deleting'
            u.log 'skipping termination, already deleting'
            return

        is_production = assume_production or @is_production()

        if is_production and not terminate_prod
            throw new Error 'cannot terminate a production RDS instance without passing terminate_prod'

        SkipFinalSnapshot ?= not is_production

        u.log 'Deleting rds instance ' + @id
        #If it is a production instance, we want to save a final snapshot.  Otherwise,
        #jus delete it.
        params = {
            DBInstanceIdentifier: @id
            FinalDBSnapshotIdentifier: if not SkipFinalSnapshot then @id + '-final-snapshot-' + String(Date.now()) else null
            SkipFinalSnapshot: SkipFinalSnapshot
        }
        @rds 'deleteDBInstance', params
        u.log 'Deleted rds instance ' + @id

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
            if @environment().is_production() or @owner()?.id isnt u.current_user().id
                return constants.ADMIN
            else
                return constants.BASIC


    #Opens up a console for interacting with the database
    console: ->
        u.context().create_sub_logger true
        session = bbserver.create_web_session 'Connecting to ' + String(this)

        u.reply u.context().server.get_server_url() + '/session/' + session.id

        [client, done] = (new databases.Postgres this).get_client()
        session.write 'Connected to database\n\n'

        #Handle notices
        client.on 'notice', (msg) ->
            session.write 'notice: ' + msg + '\n'
        client.on 'error', (err) ->
            session.write 'error: ' + String(err) + '\n'

        try
            while (input = session.get_next_input()) not in ['exit', 'cancel', session.CLOSED]
                u.log 'Input: ' + input
                try
                    session.write '> ' + input + '\n'
                    block = u.Block 'querying'
                    client.query input, block.make_cb()
                    res = block.wait(30 * 60 * 1000)
                    if res.rows?.length > 0
                        for row in res.rows
                            session.write JSON.stringify(row) + '\n'
                    else
                        session.write JSON.stringify(res) + '\n'

                catch err
                    session.write '\n' + err.stack

        finally
            done()

        message = 'Interactive session finished.  Last input was: ' + input
        u.log message
        session.close message


    console_cmd:
        help: "Opens up a console for interacting with the database directly"
        groups: ->
            if @environment().is_production()
                return constants.ADMIN
            else
                return constants.BASIC

    #Creates a new RDS instance that's a copy of us.
    #
    #Environment id defaults to the default dev environment in the same region
    #as the current database
    clone: (id, instance_class, hours, environment_id) ->
        if environment_id
            environment = bbobjects.instance 'Environment', environment_id
        else
            environment = bbobjects.get_default_dev_environment(@environment().get_region())

        my_config = @get_configuration(true)
        MultiAZ = my_config.MultiAZ
        DBInstanceClass = if instance_class is 'go' then my_config.DBInstanceClass else instance_class
        StorageType = my_config.StorageType
        Iops = my_config.Iops
        permanent_options = {cloned_from: @id}
        outside_world_accessible = @get 'outside_world_accessible'
        sizing_options = {DBInstanceClass, MultiAZ, StorageType, outside_world_accessible, Iops}

        u.reply 'Beginning clone...'

        box = bbobjects.instance 'RDSInstance', id
        box.create environment, permanent_options, sizing_options

        #Make sure we remind the user to destroy this when finished
        interval = hours * 60 * 60 * 1000
        box.set 'expiration_time', Date.now() + (interval * 2)
        box.schedule_once interval, 'follow_up'

        u.reply 'Okay, your box is ready:\n' + box.describe()

    clone_cmd:
        help: 'Creates a copy of this database for development purposes'
        sublogger: true
        groups: constants.BASIC
        params: [
            {
                name: 'id'
                required: true
                validate: (id) ->
                    while id.match(/[^a-z0-9\-]/)?
                        id = u.ask 'id should only be lower-case letters, numbers, and hyphens... please enter a new id:'
                    return id
                help: 'The id of the new instance... should be lower-case letters, numbers, and hyphens'
            }
            {
                name: 'instance class'
                required: true
                type: 'list'
                options: -> ['go', 'db.t2.micro', 'db.t2.small', 'db.t2.medium', 'db.t2.large', 'db.r3.large', 'db.r3.xlarge', 'db.r3.2xlarge', 'db.r3.4xlarge', 'db.r3.8xlarge', 'db.m4.large', 'db.m4.xlarge', 'db.m4.2xlarge', 'db.m4.4xlarge', 'db.m4.10xlarge']
                help: 'The instance class of the clone.  Type "go" to use the same instance class as the current database'
            }
            {name: 'hours', required: true, type: 'number', help: 'The number of hours you need this clone for'}
            {name: 'environment id', type: 'list', options: bbobjects.list_all_ids.bind(null, 'Environment'), help: 'The environment to create the clone in.  Defaults to the default dev environment in the same region as us'}
        ]




#Represents an elastic ip address.  The id should be the amazon allocation id.
#
#Supports the switcher API used by SingleBoxService
bbobjects.ElasticIPAddress = class ElasticIPAddress extends BubblebotObject
    create: (parent, name) ->
        super parent.type, parent.id, {name}

    toString: -> "EIP #{@id} #{@get 'name'}"

    #fetches the amazon metadata for this address and caches it
    refresh: ->
        data = @ec2 'describeAddresses', {'AllocationIds': [@id]}
        eip_cache.set @id, data.Addresses?[0]

    describe_keys: -> u.extend super(), {
        instance: @get_instance()
        endpoint: @endpoint()
    }

    exists_in_aws: ->
        try
            @get_data(true)
            return true
        catch err
            if String(err).indexOf('InvalidAllocationID.NotFound') is -1
                throw err
            return false

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
        @ec2 'associateAddress', {
            AllocationId: @id
            AllowReassociation: true
            InstanceId: new_instance.id
        }
        #Our instance's address will have just changed, so force a refresh of the address
        #cache
        new_instance.get_data(true)


#Represents a Cloudfront distribution.  The id should be the aws id for the distribution
bbobjects.CloudfrontDistribution = class CloudfrontDistribution extends BubblebotObject
    create: (parent, name) ->
        super parent.type, parent.id, {name}

    toString: -> "Cloudfront #{@id} #{@get 'name'}"

    #fetches the amazon metadata for this distribution and caches it
    refresh: ->
        data = @cloudfront 'getDistribution', {Id: @id}
        cloudfront_cache.set @id, data.Distribution

    describe_keys: -> u.extend super(), {
        name: @get 'name'
        status: @get_data().Status
        endpoint: @endpoint()
        more: 'Call the get_configuration command to see the raw AWS configuration'
    }

    get_configuration: -> @get_data(true)

    get_configuration_cmd:
        help: 'Fetches the configuration information about this distribution'
        reply: true
        groups: constants.BASIC

    #Gets the domain name this distribution is accessible at
    endpoint: -> @get_data().DomainName

    exists_in_aws: ->
        try
            @get_data(true)
            return true
        catch err
            if true #TODO: replace this with a check to make sure this error isn't whatever the error it throws for missing stuff
                throw err
            return false

    #Retrieves the amazon metadata for this address.  If force_refresh is true,
    #forces us not to use our cache
    get_data: (force_refresh) ->
        if force_refresh or not cloudfront_cache.get(@id)
            @refresh()
        return cloudfront_cache.get(@id)

    #Disables the given cloudfront distribution and removes it from bubblebot
    destroy: ->
        {ETag, DistributionConfig} = @cloudfront 'getDistributionConfig', {Id: @id}

        DistributionConfig.Enabled = false
        DistributionConfig.Comment = 'Disabling'

        params = {
            IfMatch: ETag
            DistributionConfig
            Id: @id
        }

        u.log 'Disabling cloudfront distribution: ' + JSON.stringify(params)
        @cloudfront 'updateDistribution', params

        @delete()

    destroy_cmd:
        help: 'Disables this cloudfront distribution'
        reply: 'Distribution disabled.  To delete it permanently, use the AWS console'
        groups: -> if @is_production() then constants.ADMIN else constants.BASIC
        dangerous: -> @is_production()



#Represents an ElastiCache redis replication group.  The id should be the AWS id
#for the group
bbobjects.RedisReplicationGroup = class RedisReplicationGroup extends BubblebotObject
    create: (parent, name) ->
        super parent.type, parent.id, {name}

    on_startup: ->
        super()
        u.context().server?.monitor this

    toString: -> "Redis Rep Group #{@id}"

    #fetches the amazon metadata for this distribution and caches it
    refresh: ->
        data = @elasticache 'describeReplicationGroups', {ReplicationGroupId: @id}
        elasticache_cache.set @id, data.ReplicationGroups[0]

    describe_keys: -> u.extend super(), {
        name: @get('name')
        member_clusters: @get_data().MemberClusters
        status: @status()
        endpoint: @endpoint()
        more: 'Call the get_configuration command to see the raw AWS configuration'
    }

    status: -> @get_data().Status

    get_configuration: -> @get_data(true)

    get_configuration_cmd:
        help: 'Fetches the configuration information about this distribution'
        reply: true
        groups: constants.BASIC

    wait_for_available: (retries = 100, available_statuses) ->
        available_statuses ?= ['available', 'backing-up', 'modifying']

        #first do a quick check using cached data...
        if @status() in available_statuses
            return

        #Then log and refresh the data
        u.log 'waiting for redis cluster to be to be available (' + retries + '): ' + @status()
        @get_configuration()
        if @status() in available_statuses
            return
        else if retries is 0
            throw new Error 'timed out while waiting for ' + @id + ' to be available: ' + @status()
        else
            u.pause 10000
            @wait_for_available(retries - 1, available_statuses)

    #Gets the domain name this distribution is accessible at
    endpoint: ->
        @wait_for_available()
        endpoint = @get_data().NodeGroups[0].PrimaryEndpoint
        return endpoint.Address + ':' + endpoint.Port

    exists_in_aws: ->
        try
            @get_data(true)
            return true
        catch err
            if String(err).indexOf('ReplicationGroupNotFoundFault') is -1
                throw err
            return false

    #Retrieves the amazon metadata for this address.  If force_refresh is true,
    #forces us not to use our cache
    get_data: (force_refresh) ->
        if force_refresh or not elasticache_cache.get(@id)
            @refresh()
        return elasticache_cache.get(@id)

    #Deletes the given Redis replication group
    destroy: ->
        if @is_production()
            if not u.confirm 'This is a production cluster... are you sure you want to delete this?'
                return

        u.log 'Deleting Redis Replication Group ' + @id
        @elasticache 'deleteReplicationGroup', {ReplicationGroupId: @id}

        @delete()

        u.reply 'Replication group ' + @id + ' deleted'

    destroy_cmd:
        help: 'Disables this replication group'
        groups: -> if @is_production() then constants.ADMIN else constants.BASIC
        dangerous: -> @is_production()

    #Returns a description of how this redis cluster should be monitored
    #
    #The environment's template should define get_redis_monitoring_policy(name) to
    #set it
    get_monitoring_policy: ->
        if not @exists()
            return {monitor: false}
        mp = @environment().template().get_redis_monitoring_policy? this, @get('name')
        if not mp?
            return {monitor: false}
        mp.frequency ?= 5000
        mp.endpoint = {
            protocol: 'redis'
            host: @endpoint()
        }
        return mp

    #Returns true if this service is in maintenance mode (and thus should not be monitored)
    maintenance: ->
        #if the maintenance property is set, we are in maintenance mode
        if @get 'maintenance'
            return true

        #If we are not available, we are in maintenance mode
        if @status() isnt 'available'
            #Force a recheck, since this likely means we are creating or destroying it
            @get_configuration()
        if @status() isnt 'available'
            #Force a recheck, since this likely means we are creating or destroying it
            return true

        return false

    #Sets whether or not we should enter maintenance mode
    set_maintenance: (turn_on) ->
        @set 'maintenance', turn_on
        u.reply 'Maintenance mode is ' + (if turn_on then 'on' else 'off')
        u.context().server._monitor.update_policies()

    set_maintenance_cmd:
        params: [{name: 'on', type: 'boolean', required: true, help: 'If true, turns maintenance mode on, if false, turns it off'}]
        help: 'Turns maintenance mode on or off'
        groups: constants.BASIC




#Represents an S3 Bucket.  Id is the bucket id
bbobjects.S3Bucket = class S3Bucket extends BubblebotObject
    create: (parent, name) ->
        super parent.type, parent.id, {name}

    toString: -> "S3 #{@id}"

    #fetches the amazon metadata for this bucket and caches it
    refresh: ->
        data = @s3 'getBucketLocation', {Bucket: @id}
        s3_cache.set @id, data

    #Retrieves the amazon metadata for this bucket.  If force_refresh is true,
    #forces us not to use our cache
    get_data: (force_refresh) ->
        if force_refresh or not s3_cache.get(@id)
            @refresh()
        return s3_cache.get(@id)

    describe_keys: -> u.extend super(), {
        name: @get('name')
        location: @get_data().LocationConstraint
    }

    get_configuration: -> @get_data(true)

    get_configuration_cmd:
        help: 'Fetches the configuration information about this bucket'
        reply: true
        groups: constants.BASIC

    exists_in_aws: ->
        try
            @get_data(true)
            return true
        catch err
            if true #TODO: replace with actual error
                throw err
            return false

    #Deletes the given Bucket
    destroy: ->
        u.log 'Deleting s3 bucket ' + @id
        @s3 'deleteBucket', {Bucket: @id}
        @delete()

        u.reply 'Bucket ' + @id + ' deleted'

    destroy_cmd:
        help: 'Deletes this Bucket.  AWS will error if there is anything in it'
        groups: -> if @is_production() then constants.ADMIN else constants.BASIC
        dangerous: -> @is_production()







#Given a region, gets the API configuration
aws_config = (region) ->
    accessKeyId = config.get 'accessKeyId'
    secretAccessKey = config.get 'secretAccessKey'
    res = {
        region
        maxRetries: 10
    }
    if accessKeyId or secretAccessKey
        res.accessKeyId = accessKeyId
        res.secretAccessKey = secretAccessKey
    else
        res.credentials = new AWS.EC2MetadataCredentials {
            httpOptions: { timeout: 20000 }
        }
    return res


#Loads the AWS service given the region.  We cache it since there can be issues
#with loading it fresh each time...
#
#https://github.com/aws/aws-sdk-js/issues/692
get_aws_service = (name, region) ->
    key = name + ' ' + region
    if not aws_service_cache.get(key)
        svc = u.retry 20, 2000, =>
            config = aws_config region
            return new AWS[name] config
        aws_service_cache.set key, svc
    return aws_service_cache.get(key)


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
cloudfront_cache = new Cache(60 * 1000)
elasticache_cache = new Cache(60 * 1000)
key_cache = new Cache(60 * 60 * 1000)
sg_cache = new Cache(60 * 60 * 1000)
vpc_to_subnets = new Cache(60 * 60 * 1000)
log_stream_cache = new Cache(24 * 60 * 60 * 1000)
rds_subnet_groups = new Cache(60 * 60 * 1000)
rds_cache = new Cache(60 * 1000)
region_cache = new Cache(24 * 60 * 60 * 1000)
aws_service_cache = new Cache(2 * 60 * 60 * 1000)
s3_cache = new Cache(60 * 1000)


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
databases = require './databases'