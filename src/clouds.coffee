clouds = exports

#Statuses
INITIALIZED = 'initialized'

clouds.AWSCloud = class AWSCloud
    get_bbserver: ->
        instances = @get_bb_environment().get_instances_by_tag(config.get('bubblebot_role_tag'), config.get('bubblebot_role_bbserver'))

        #Clean up any bubblebot server instances not tagged as initialized -- they represent
        #abortive attempts at creating the server
        good = []
        for instance in instances
            if instance.get_tags()[config.get('status_tag')] isnt INITIALIZED
                u.log 'found an uninitialized bubbblebot server.  Terminating it...'
                instance.terminate()
            else
                good.push instance

        if good.length > 1
            throw new Error 'Found more than one bubblebot server!  Should only be one server tagged ' + config.get('bubblebot_role_tag') + ' = ' + config.get('bubblebot_role_bbserver')
        return good[0]

    #Returns the special bubblebot environment
    get_bb_environment: -> new BBEnvironment(this)

    create_bbserver: ->
        image_id = config.get('bubblebot_image_id')
        instance_type = config.get('bubblebot_instance_type')
        environment = @get_bb_environment()

        instance = environment.create_server image_id, instance_type, config.get('bubblebot_role_bbserver'), 'Bubble Bot', config.get('bubblebot_instance_profile')
        u.log 'bubblebot server created, waiting for it to ready...'
        instance.wait_for_ssh()

        u.log 'bubblebot server ready, installing software...'

        #Install node and supervisor
        command = 'node ' + config.get('install_directory') + '/' + config.get('run_file')
        software.supervisor('bubblebot', command, config.get('install_directory')).add(software.node('4.4.3')).install(instance)

        environment.tag_resource(instance.id, config.get('status_tag'), INITIALIZED)

        u.log 'bubblebot server has base software installed'

        return instance

    #Returns the database instance we use to run bubblebot, creating it if it does not exist
    get_bbdb: ->



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
key_cache = new Cache(60 * 60 * 1000)
sg_cache = new Cache(60 * 60 * 1000)
vpc_to_subnets = new Cache(60 * 60 * 1000)
log_stream_cache = new Cache(24 * 60 * 60 * 1000)


class Environment
    constructor: (@cloud, @name) ->
        if @name is 'bubblebot'
            throw new Error 'bubblebot is a reserved name, you cannot name an environment that'

    #Given a key, value pair, returns a list of instanceids that match that pair
    get_instances_by_tag: (key, value) ->
        #http://docs.aws.amazon.com/AWSJavaScriptSDK/latest/AWS/EC2.html#describeInstances-property
        return @describe_instances {
            Filters: [{Name: 'tag:' + key, Values: [value]}]
        }

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
                res.push new Instance this, id

        #filter out terminated instances
        res = (instance for instance in res when instance.get_state() not in ['terminated', 'shutting-down'])

        return res

    #Returns the keypair name for this environment, or creates it if it does not exist
    get_keypair_name: ->
        name = config.get('keypair_prefix') + @name

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

    #creates and returns a new ec2 server in this environment
    create_server: (ImageId, InstanceType, role, name, instance_profile) ->
        KeyName = @get_keypair_name()
        SecurityGroupIds = [@get_webserver_security_group()]
        SubnetId = @get_subnet()
        MaxCount = 1
        MinCount = 1
        InstanceInitiatedShutdownBehavior = 'stop'

        results = @ec2 'runInstances', {
            ImageId
            MaxCount
            MinCount
            SubnetId
            KeyName
            SecurityGroupIds
            InstanceType
            InstanceInitiatedShutdownBehavior
        }

        id = results.Instances[0].InstanceId

        @tag_resource id, 'Name', name
        @tag_resource id, config.get('bubblebot_role_tag'), role

        return new Instance this, id

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
        group_name = @name + '_webserver_sg'
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
        if not (this instanceof BBEnvironment)
            bubblebot_sg = @cloud.get_bb_environment().get_webserver_security_group()
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


    get_region: -> throw new Error 'not yet implemented'

    get_vpc: -> throw new Error 'not yet implemented'


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


#Special hard-coded environment that we use to run the bubble bot
class BBEnvironment extends Environment
    constructor: (@cloud) ->
        @name = 'bubblebot'

    get_region: -> config.get('bubblebot_region')

    get_vpc: -> config.get('bubblebot_vpc')

    #We allow direct SSH connections to bubblebot to allow for deployments.
    #The security key for connecting should NOT ever be saved locally!
    allow_outside_ssh: -> true


class RDSInstance
    constructor: (@environment, @id) ->

    #Returns the endpoint we can access this instance at
    get_endpoint: -> throw new Error 'not implemented'


class Instance
    constructor: (@environment, @id) ->

    toString: -> 'Instance ' + @id

    run: (command, options) ->
        return ssh.run @get_address(), @environment.get_private_key(), command, options

    upload_file: (path, remote_dir) ->
        ssh.upload_file @get_address(), @environment.get_private_key(), path, remote_dir

    write_file: (data, remote_path) ->
        ssh.write_file @get_address(), @environment.get_private_key(), remote_path, data

    #Makes sure we have fresh metadata for this instance
    refresh: -> @environment.describe_instances({InstanceIds: [@id]})

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
        data = @environment.ec2 'terminateInstances', {InstanceIds: [@id]}
        if not data.TerminatingInstances?[0]?.InstanceId is @id
            throw new Error 'failed to terminate! ' + JSON.stringify(data)

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



#Given a region, gets the API configuration
aws_config = (region) ->
    accessKeyId = config.get 'accessKeyId'
    secretAccessKey = config.get 'secretAccessKey'
    return {region, accessKeyId, secretAccessKey}




config = require './config'
software = require './software'
AWS = require 'aws-sdk'
ssh = require './ssh'
request = require 'request'
u = require './utilities'
stable_stringify = require 'json-stable-stringify'
fs = require 'fs'
cloudwatchlogs = require './cloudwatchlogs'