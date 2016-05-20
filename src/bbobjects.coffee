environments = exports

#Retrieves an object with the given type and id
bbobjects.instance = (type, id) ->
    if not bbobjects[type]
        throw new Error 'missing type: ' + type
    if not (bbobjects[type] instanceof BubblebotObject)
        throw new Error type + ' is not a BubblebotObject'
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



#Returns the bubblebot server (creating it if it does not exist)
#
#We do not manage the bubblebot server in the database, since we need to be able to find it
#even when we are running the command line script.
bbobjects.get_bbserver = ->
    environment = bbobjects.bubblebot_environment
    instances = environment.get_instances_by_tag(config.get('bubblebot_role_tag'), config.get('bubblebot_role_bbserver'))

    #Clean up any bubblebot server instances not tagged as initialized -- they represent
    #abortive attempts at creating the server
    good = []
    for instance in instances
        if instance.get_tags()[config.get('status_tag')] isnt BUILD_COMPLETE
            u.log 'found an uninitialized bubbblebot server.  Terminating it...'
            instance.terminate()
        else
            good.push instance

    if good.length > 1
        throw new Error 'Found more than one bubblebot server!  Should only be one server tagged ' + config.get('bubblebot_role_tag') + ' = ' + config.get('bubblebot_role_bbserver')
    else if good.length is 1
        return good[0]

    #We didn't find it, so create it...
    image_id = config.get('bubblebot_image_id')
    instance_type = config.get('bubblebot_instance_type')

    id = environment.create_server_raw image_id, instance_type

    @tag_resource id, 'Name', 'Bubble Bot'
    @tag_resource id, config.get('bubblebot_role_tag'), config.get('bubblebot_role_bbserver')

    instance = bbobjects.instance 'EC2Instance', id

    u.log 'bubblebot server created, waiting for it to ready...'
    instance.wait_for_ssh()

    u.log 'bubblebot server ready, installing software...'

    #Install node and supervisor
    command = 'node ' + config.get('install_directory') + '/' + config.get('run_file')
    software.supervisor('bubblebot', command, config.get('install_directory')).add(software.node('4.4.3')).install(instance)

    environment.tag_resource(instance.id, config.get('status_tag'), BUILD_COMPLETE)

    u.log 'bubblebot server has base software installed'

    return instance

#Returns all the environments in our database
bbobjects.list_environments = -> (bbobjects.instance 'Environment', id for id in u.db().list_objects 'Environment')

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
            u.reply 'Options are:\n' + ('  ' + vpc.VpcId + ': ' + vpc.State + ' ' + vpc.CidrBlock for vpc in results.Vpcs ? []).join('\n'
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

    get_subcommands: ->
        subs = {}
        for child in @bbobject.children()
            if subs[child.id]
                subs[child.id + '_' + child.type.toLowerCase()] = child
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
    get_subcommands: ->
        template_commands = {}
        if typeof(@template) is 'function'
            template = @template()
            for k, v of template
                if typeof(v) is 'function' and template[k + '_cmd']?
                   cmd = bbserver.build_command u.extend {run: v.bind(template, this), target: template}, @[k + '_cmd']
                   template_commands[k] = cmd

        children = (new ChildCommand this).get_subcommands()

        return u.extend {}, children, template_commands, @subcommands


    #Gets called when we start the server up.  Recursively calls on children.
    #Children should call super() to continue recursion, and perform any startup logic
    #such as setting up monitoring
    #
    #We also call this in @create, by default, so should be idempotent to be safe
    startup: ->
        child.startup() for child in @children()


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
        help_text: 'finds either the immediate parent, or an ancestor of a given type'
        reply: true

    #Returns the immediate children of this object, optionally filtering by child type
    children: (child_type) ->
        list = u.db().children @type, @id, child_type
        return (bbobjects.instance child_type, child_id for [child_type, child_id] in list)

    children_cmd:
        params [{name: 'child_type', help: 'If specified, filters to the given type'}]
        help_text: 'lists all the children of this object.  to access a specific child, use the "child" command'
        reply: true

    #Retrieves the environment that this is in
    environment: -> @parent 'Environment'

    environment_cmd:
        help_text: 'returns the environment that this is in'

    #Gets the given property of this object
    get: (name) ->
        if @hardcoded
            return @hardcoded[name]?() ? null
        u.db().get_property @type, @id, name

    get_cmd:
        params: [{name: 'name', required: true}]
        help_text: 'gets the given property of this object'
        reply: true

    #Sets the given property of this object
    set: (name, value) ->
        if @hardcoded
            throw new Error 'we do not support setting properties on this object'
        u.db().set_property @type, id, name, value

    set_cmd:
        params: [[{name: 'name', required: true}, {name: 'value', required: true}]
        help_text: 'sets the given property of this object'
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
        help_text: 'gets all the properties for this object'
        reply: true

    #Creates this object in the database
    create: (parent_type, parent_id, initial_properties ?= {}) ->
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
        u.db().delete_object @type, id

    #Returns true if this object exists in the database
    exists: ->
        if @hardcoded
            return true
        return u.db().exists @type, @id

    #Gets the history type for this item
    history_type: (event_type) -> @type + '_' + event_type

    #Adds an item to the history of this object
    add_history: (event_type, reference, properties) ->
        u.db().add_history @history_type(), @id, reference, properties

    #Returns the user who created this
    creator: ->
        user_id = @get 'creator'
        if user_id
            return bbobjects.instance 'User', user_id

    creator_cmd:
        help_text: 'Gets the user who created this'
        reply: true

    #Returns the user who owns this
    owner: ->
        user_id = @get 'owner'
        if user_id
            return bbobjects.instance 'User', user_id

    owner_cmd:
        help_text: 'Gets the user who owns this'
        reply: true

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
        help_text: 'Describes this'
        reply: true


#Represents a bubblebot user, ie a Slack user.  User ids are the slack ids
bbobjects.User = class User extends BubblebotObject
    #gets the slack client
    slack: -> u.context().server.slack_client

    toString: -> 'User ' + @id + ' (' + @name() + ')'

    name: -> @slack().get_user_info().name

    name_cmd:
        help_text: 'shows the name of this user'
        reply: true

    profile: -> @slack().get_user_info().profile

    profile_cmd:
        help_text: 'shows the slack profile for this user'
        reply: true

    slack_info: -> @slack().get_user_info()

    slack_info_cmd:
        help_text: 'shows all the slack data for this user'
        reply: true

#If the user enters a really high value for hours, double-checks to see if it is okay
bbobjects.validate_destroy_hours = (hours) ->
    week = 7 * 24
    if hours > week
        if not bbserver.do_cast 'boolean', u.ask "You entered #{hours} hours, which is over a week (#{week} hours)... are you sure you want to keep it that long?"
            hours = bbserver.do_cast 'number', u.ask 'Okay, how many hours should we go for?'

        if hours > week
            u.report 'Fyi, ' + u.current_user().name() + ' created a test server for ' + hours + ' hours...'

    return hours


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


    template: ->
        template = @get 'template'
        if not template
            return null
        return templates[template] ? null


    #Creates a server for development purposes
    create_box: (build_id, hours, size, name) ->
        ec2build = bbobjects.instance 'EC2Build', build_id

        u.reply 'beginning build of box... '
        box = ec2build.build this, size, name

        #Make sure we remind the user to destroy this when finished
        interval = hours * 60 * 60 * 1000
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

        help_text: 'Creates a new server in this environment for testing or other purposes'



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
            @s3 'putObject', {Bucket: config.get('bubblebot_s3_bucket'), Key: name, Body: private_key}

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
            data = String(@s3('getObject', {Bucket: config.get('bubblebot_s3_bucket'), Key: keyname}).Body)
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
    create_server_raw: (ImageId, InstanceType) ->
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

    #Retrieves the security group for webservers in this group, creating it if necessary
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


    get_region: -> @get 'region'

    get_vpc: -> @get 'vpc'


    tag_resource: (id, Key, Value) ->
        @ec2 'createTags', {
            Resources: [id]
            Tags: [{Key, Value}]
        }

    #Calls ec2 and returns the results
    ec2: (method, parameters) -> @aws 'EC2', method, parameters

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



bbobjects.ServiceInstance = class ServiceInstance extends BubblebotObject
    #Adds it to the database
    create: (environment) ->
        prefix = environment.id + '_'
        if @id.indexOf(prefix) isnt 0
            throw new Error 'ServiceInstance ids should be of the form [environment id]_[template]'

        template = @id[prefix.length..]
        templates.verify 'Service', template

        super environment.type, environment.id


    describe_keys: -> u.extend super(), {
        template: @template()
        version: @version()
        endpoint: @endpoint()
    }

    #Returns the template for this service or null if not found
    template: ->
        prefix = @parent().id + '_'
        template = @id[prefix.length..]
        if not template
            return null
        return templates[template] ? null

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
        help_text: 'Ask other users not to deploy to this service til further notice.  Can be cancelled with "unblock"'

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
        help_text: 'Removes a block on deploying created with the "block" command'


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
        help_text: 'Deploys the given version to this service.  Ensures that the new version is tested and ahead of the current version'

    #Returns the current version of this service
    version: -> @get 'version'

    version_cmd:
        help_text: 'Returns the current version of this service'
        reply: true

    #On startup, we make sure we are monitoring this
    startup: ->
        super()
        u.context().server.monitor this

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
        help_text: 'Returns whether we are in maintenance mode'
        reply: true

    #Sets whether or not we should enter maintenance mode
    set_maintenance: (on) ->
        @set 'maintenance', on
        u.reply 'Maintenance mode is ' + (if on then 'on' else 'off')

    set_maintenance_cmd:
        params: {name: 'on', type: 'boolean', required: true, help: 'If true, turns maintenance mode on, if false, turns it off'}
        help_text: 'Turns maintenance mode on or off'

    #Replaces the underlying boxes for this service
    replace: -> @template().replace this

    replace_cmd:
        help_text: 'Replaces the underlying boxes for this service'


#Represents the AMI and software needed to build an ec2 instance
#
#The id should match the ec2_build_template for this build
bbobjects.EC2Build = class EC2Build extends BubblebotObject
    #Creates in the database.  We need to do this to store AMIs for each region
    create: ->
        templates.verify 'EC2Build', @id
        super null, null, {}

    #Retrieves the ec2 build template
    template: -> templates[@id] ? throw new Error 'could not find ec2 build template with id ' + @id

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
        ami = @get_ami environment.get_region()
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
        help_text: 'Retrieves the current AMI for this build in the given region.  If one does not exist, creates it.'
        reply: true


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
        help_text: 'Replaces the current AMI for this build in the given region'

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


bbobjects.EC2Instance = class EC2Instance extends BubblebotObject
    #Creates in the database and tags it with the name in the AWS console
    create: (parent, name, status, build_template_id) ->
        templates.verify 'EC2Build', build_template_id
        super parent.type, parent.id, {name, status, build_template_id}

        @environment().tag_resource @id, 'Name', name + ' (' + status + ')'

    #Updates the status and adds a ' (status)' to the name in the AWS console
    set_status: (status) ->
        u.log 'setting status of ' + this + ' to ' + status
        @set 'status', status

        new_name = @get('name') + ' (' + status + ')'
        @environment().tag_resource @id, 'Name', new_name

    describe_keys: -> u.extend super(), {
        name: @get 'name'
        status: @get 'status'
        aws_status: @get_state()
        template: @template()
        public_dns: @get_public_dns()
        address: @get_address()
    }

    #The template for this ec2instance (ie, what software to install)
    template: ->
        template = @get 'build_template_id'
        if not template
            return null
        return templates[template] ? null

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
        help_text: 'Terminates this server'
        questions: ->
            {name: 'confirm',  type: 'boolean', help: 'Are you sure you want to terminate this server?'}


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
        if config.get('command_line')
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



bbobjects.RDSInstance = class RDSInstance extends BubblebotObject
    constructor: (@environment, @id) ->

    #Returns the endpoint we can access this instance at
    endpoint: -> throw new Error 'not implemented'



#Represents a database
bbobjects.Database = class Database extends BubblebotObject

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
        @environment().ec2 'associateAddress', {
            AllocationId: @id
            AllowReassociation: true
            InstanceId: new_instance.id
        }




#Given a region, gets the API configuration
aws_config = (region) ->
    accessKeyId = config.get 'accessKeyId'
    secretAccessKey = config.get 'secretAccessKey'
    return {region, accessKeyId, secretAccessKey}



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