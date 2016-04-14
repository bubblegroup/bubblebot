clouds = exports

clouds.AWSCloud = class AWSCloud
    get_bbserver: ->
        instances = @get_bb_environment().get_instances_by_tag(config.get('bubblebot_role_tag'), config.get('bubblebot_role_bbserver'))
        if instances.length > 0
            throw new Error 'Found more than one bubblebot server!  Should only be one server tagged ' + config.get('bubblebot_role_tag') + ' = ' + config.get('bubblebot_role_bbserver')
        return instances[0]

    #Returns the special bubblebot environment
    get_bb_environment: -> new BBEnvironment()

    create_bbserver: ->
        image_id = config.get('bubblebot_image_id')
        instance_type = config.get('bubblebot_instance_type')
        environment = @get_bb_environment()

        instance = environment.create_server image_id, instance_type, config.get('bubblebot_role_bbserver'), 'Bubble Bot'

        #Install node and supervisor
        command = 'node ' + config.get('install_directory') + config.get('run_file')
        software.supervisor('bubblebot', command, config.get('install_directory')).add(software.node('4.4.4')).install(instance)

        return instance


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


class Environment
    constructor: (@name) ->
        if @name is 'bubblebot'
            throw new Error 'bubblebot is a reserved name, you cannot name an environment that'

    get_name: -> @name

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

        return res

    #Returns the keypair name for this environment, or creates it if it does not exist
    get_keypair_name: ->
        name = config.get('keypair_prefix') + @get_name()

        #check to see if it already exists
        try
            pairs = @ec2('describeKeyPairs', {KeyNames: [name]})
        catch err
            if String(err).indexOf('does not exist') is -1
                throw err

            #If not, create it
            {KeyMaterial} = @ec2('createKeyPair', {KeyName: name})

            #And save it to s3
            @s3 'putObject', {Bucket: config.get('bubblebot_s3_bucket'), Key: name, Body: KeyMaterial}

        return name

    #Gets the private key that corresponds with @get_keypair_name()
    get_private_key: ->
        keyname = @get_keypair_name()
        if not key_cache.get(keyname)
            data = @s3('getObject', {Bucket: config.get('bubblebot_s3_bucket'), Key: keyname}).Body
            if typeof(data) isnt 'string'
                throw new Error 'non string data: ' + +typeof(data) + ' ' + data
            key_cache.set keyname, data
        return key_cache.get(keyname)

    #creates and returns a new ec2 server in this environment
    create_server: (ImageId, InstanceType, role, name) ->
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

    get_webserver_security_group: -> throw new Error 'not yet implemented!'

    get_subnet: -> throw new Error 'not yet implemented'


    tag_resource: (id, Key, Value) ->
        @ec2 'createTags', {
            Resources: [id]
            Tags: [{Key, Value}]
        }



    #Calls ec2 and returns the results
    ec2: (method, parameters) -> @aws 'EC2', method, parameters

    #Calls s3 and returns the results
    s3: (method, parameters) -> @aws 'S3', method, parameters

    #Calls the AWS api
    aws: (service, method, parameters) ->
        svc = new AWS[service](aws_config @get_region())
        block = u.Block method
        svc[method] parameters, block.make_cb()
        return block.wait()


#Special hard-coded environment that we use to run the bubble bot
class BBEnvironment extends Environment
    constructor: ->

    get_name: -> 'bubblebot'

    get_region: -> config.get('bubblebot_region')

    get_vpc: -> config.get('bubblebot_vpc')



class Instance
    #Id should be the id of the instance, or data should be the full output of
    #describeInstances
    constructor: (@environment, @id) ->

    toString: -> 'Instance ' + @id

    run: (command, {can_fail, timeout}) ->
        return ssh.run @get_address(), @environment.get_private_key(), command, {can_fail, timeout}

    upload_file: (path, remote_dir) ->
        ssh.upload_file @get_address(), @environment.get_private_key(), path, remote_dir

    write_file: (data, remote_path) ->
        ssh.write_file @get_address(), @environment.get_private_key(), remote_path, data

    #Makes sure we have fresh metadata for this instance
    refresh: -> @environment.describe_instances({InstanceIds: [@id]})

    #Gets the amazon metadata for this instance, refreshing if it is null
    get_data: ->
        if not instance_cache.get(@id)
            @refresh()
        return instance_cache.get(@id)

    #Returns the state of the instance
    get_state: -> @get_data().State.Name

    #Returns the address bubblebot can use for ssh / http requests to this instance
    get_address: -> @get_private_ip_address()

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