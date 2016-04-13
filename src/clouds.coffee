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
        software.supervisor(command).add(software.node('4.4.4')).install(instance)

        return instance



class Environment
    constructor: (@name) ->
        if @name is 'bubblebot'
            throw new Error 'bubblebot is a reserved name, you cannot name an environment that'

    get_name: -> @name

    #Given a key, value pair, returns a list of instanceids that match that pair
    get_instances_by_tag: (key, value) ->
        #http://docs.aws.amazon.com/AWSJavaScriptSDK/latest/AWS/EC2.html#describeInstances-property
        return @describe_instances {
            Filters: [{tag: key + '=' + value}]
        }

    #Calls describe instances on the given set of instances / parameters, and returns an array of
    #Instance objects
    describe_instances: (params) ->
        #http://docs.aws.amazon.com/AWSJavaScriptSDK/latest/AWS/EC2.html#describeInstances-property
        data = @ec2('describeInstances', params)
        res = []
        for reservation in data.Reservations ? []
            for instance in reservation.Instances ? []
                res.push new Instance null, instance
        return res

    #Returns the keypair name for this environment, or creates it if it does not exist
    get_keypair_name: ->
        name = config.get('keypair_prefix') + @get_name()

        #check to see if it already exists
        pairs = @ec2('describeKeyPairs', {KeyNames: [name]})
        if not pairs.KeyPairs?.length > 0
            #If not, create it
            {KeyMaterial} = @ec2('createKeyPair', {KeyName: name})

            #And save it to s3
            @s3.putObject {Bucket: config.get('bubblebot_s3_bucket'), Key: name, Body: KeyMaterial}

        return name


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

        return new Instance id


    get_subnet: ->

    tag_resource: ->





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



class Instance
    #Id should be the id of the instance, or data should be the full output of
    #describeInstances
    constructor: (@id, @data) ->
        @id ?= @data.InstanceId

    toString: -> 'Instance ' + @id

    run: (command, {can_fail}) ->

    upload_file: (path, remote_dir) ->

    write_file: (data, remote_path) ->

    post_authenticated: (url, body) ->



#Given a region, gets the API configuration
aws_config = (region) ->
    accessKeyId = config.get 'accessKeyId'
    secretAccessKey = config.get 'secretAccessKey'
    return {region, accessKeyId, secretAccessKey}




config = require './config'
software = require './software'
AWS = require 'aws-sdk'