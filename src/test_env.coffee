fs = require 'fs'
AWS = require 'aws-sdk'
strip_comments = require 'strip-json-comments'

u = require './utilities'
software = require './software'
bbobjects = require './bbobjects'

test_credentials = JSON.parse(fs.readFileSync('test_credentials.json'))
config = JSON.parse strip_comments fs.readFileSync('configuration.json').toString()
config_ = {
    run_file: 'run.js'
    install_directory: '/home/ec2-user/bubblebot'
    deploy_key_path: 'deploy_key_rsa'
    bubblebot_instance_profile: 'bubblebot_server'
    bubblebot_tag_key: 'bubblebot'
    bubblebot_tag_value: 'bubblebot_server'
    keypair_prefix: 'bubblebot_keypair_'
    status_tag: 'bubblebot_status'
    bubblebot_role_tag: 'bubblebot_role'
    bubblebot_role_bbserver: 'bbserver'
    bubblebot_role_bbdb: 'bbdb'
    install_directory: '/home/ec2-user/bubblebot'
    run_file: 'run.js'
    bubblebot_domain: ''
    bubblebot_use_https: false
    remote_repo: 'bubblebot'
    }

for key, val of config_
    config[key] = val
















REGION = config['bubblebot_region']

# Copied and pasted from bbobjects; this essentially creates an EC2 Instance
aws_config = (REGION) ->
    accessKeyId = test_credentials['accessKeyId']
    secretAccessKey = test_credentials['secretAccessKey']
    res = {
        # TODO : is this okay? was originally this
        # config['bubblebot_region']
        REGION
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

get_aws_service = (name, region) ->
    key = name + ' ' + region
    # NOTE : there was a cache lookup here before
    svc = u.retry 20, 2000, =>
        config = aws_config region
        return new AWS[name] aws_config(REGION)
    return svc

get_svc = (service) -> get_aws_service service, REGION

# TODO : u.block ? 
aws = (service, method, parameters) ->
    svc = get_svc service
    block = u.Block method
    svc[method] parameters, block.make_cb()
    return block.wait()

#Calls ec2 and returns the results
ec2 = (method, parameters) -> aws 'EC2', method, parameters















#Gets the given property of this object
get = (name) ->
    # if @hardcoded?[name]
    #     return @hardcoded[name]?() ? null
    u.db().get_property 'Environment', constants.BUBBLEBOT_ENV, name

get_vpc = () -> get 'vpc'

#Returns the raw data for all subnets in the VPC for this environments
get_all_subnets = (force_refresh) ->
    vpc_id = get_vpc()

    if not force_refresh
        data = vpc_to_subnets.get(vpc_id)
        if data?
            return data

    data = ec2 'describeSubnets', {Filters: [{Name: 'vpc-id', Values: [vpc_id]}]}
    vpc_to_subnets.set(vpc_id, data)
    return data

get_subnet = () ->
    data = get_all_subnets()

    for subnet in data.Subnets ? []
        if subnet.State is 'available' and subnet.AvailableIpAddressCount > 0
            return subnet.SubnetId

    throw new Error 'Could not find a subnet!  Data: ' + JSON.stringify(data)

#Returns the keypair name for this environment, or creates it if it does not exist
get_keypair_name = ->

    # TODO : is this correct ? 
    name = config['keypair_prefix'] + constants.BUBBLEBOT_ENV

    #check to see if it already exists
    try
        pairs = ec2('describeKeyPairs', {KeyNames: [name]})
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
        ec2('importKeyPair', {KeyName: name, PublicKeyMaterial: public_key})

    return name















allow_outside_ssh = () ->
    #We allow direct SSH connections to bubblebot to allow for deployments.
    #The security key for connecting should NEVER be saved locally!
    return true

#Given a security group name, fetches its meta-data (using the cache, unless force-refresh is on)
#Creates the group if there is not one with this name.
get_security_group_data = (group_name, force_refresh, retries = 2) ->
    #try the cache
    if not force_refresh
        data = sg_cache.get(group_name)

    # if data?
    #     return data

    data = ec2('describeSecurityGroups', {Filters: [{Name: 'group-name', Values: [group_name]}]}).SecurityGroups[0]
    if data?
        # sg_cache.set(group_name, data)
        return data

    if not data?
        if retries is 0
            throw new Error 'unable to create security group ' + group_name
        try
            ec2('createSecurityGroup', {Description: 'Created by bubblebot', GroupName: group_name, VpcId: get_vpc()})
        catch err
            #Handle the case of two people trying to create it in parallel
            if String(err).indexOf('InvalidGroup.Duplicate') isnt -1
                u.pause 1000
                return get_security_group_data(group_name, force_refresh, retries - 1)
            else
                throw err
        return get_security_group_data(group_name, force_refresh, retries - 1)

get_security_group_id = (group_name) -> get_security_group_data(group_name).GroupId

get_webserver_security_group: ->
    group_name = constants.BUBBLEBOT_ENV + '_webserver_sg'
    id = get_security_group_id(group_name, false)

    rules = [
        #Allow outside world access on 80 and 443
        {IpRanges: [{CidrIp: '0.0.0.0/0'}], IpProtocol: 'tcp', FromPort: 80, ToPort: 80}
        {IpRanges: [{CidrIp: '0.0.0.0/0'}], IpProtocol: 'tcp', FromPort: 443, ToPort: 443}
        #Allow other boxes in this security group to connect on any port
        {UserIdGroupPairs: [{GroupId: id}], IpProtocol: '-1'}
    ]
    #If this is a server people are allowed to SSH into directly, open port 22.
    # if @allow_outside_ssh()
    rules.push {IpRanges: [{CidrIp: '0.0.0.0/0'}], IpProtocol: 'tcp', FromPort: 22, ToPort: 22}

    #If this is not bubblebot, add the bubblebot server
    # if @id isnt constants.BUBBLEBOT_ENV
    #     bubblebot_ip_range = bbobjects.get_bbserver().get_public_ip_address() + '/32'
    #     bubblebot_private_ip_range = bbobjects.get_bbserver().get_private_ip_address() + '/32'

    #     #Allow bubblebot to connect on any port
    #     rules.push {IpRanges: [{CidrIp: bubblebot_ip_range}], IpProtocol: '-1'}
    #     rules.push {IpRanges: [{CidrIp: bubblebot_private_ip_range}], IpProtocol: '-1'}

    ensure_security_group_rules group_name, rules
    return id















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














create_server_raw = () ->
    KeyName = get_keypair_name()

    # TODO : what is a security group ? 
    security_group_id ?= get_webserver_security_group()
    if Array.isArray security_group_id
        SecurityGroupIds = security_group_id
    else
        SecurityGroupIds = [security_group_id]

    SubnetId = get_subnet()
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

    results = ec2 'runInstances', params
    id = results.Instances[0].InstanceId
    u.log 'EC2 succesfully created with id ' + id
    return id

create_bbserver = () ->
    environment = bbobjects.bubblebot_environment()

    image_id = config['bubblebot_image_id']
    instance_type = config['bubblebot_instance_type']
    instance_profile = config['bubblebot_instance_profile']

    id = create_server_raw image_id, instance_type, instance_profile

    environment.tag_resource id, 'Name', 'Bubble Bot'

    # just saves it in the postgres database
    instance = bbobjects.instance 'EC2Instance', id
    instance.create()

    u.log 'bubblebot server created, waiting for it to ready...'

    #manually set environment because we can't check database
    instance.environment = -> environment

    # TODO : what does this do
    instance.wait_for_ssh()

    u.log 'bubblebot server ready, installing software...'

    # Install node and supervisor
    command = 'node ' + config['install_directory'] + '/' + config['run_file']

    # does a bunch of stuff with yum 
    software.supervisor('bubblebot', command, config['install_directory']) instance
    # does a bunch of stuff with node
    software.node('4.4.5') instance
    # installs postgress and stuff
    software.pg_dump96() instance
    # tmp autostart stuff
    software.supervisor_auto_start() instance
    # tags a bunch of stuff
    environment.tag_resource id, config['bubblebot_role_tag'], config['bubblebot_role_bbserver']

    u.log 'bubblebot server has base software installed'

    startup_bbserver instance

    return instance

# Copied and pasted from commands.publish()
copy_to_test_server = (access_key, secret_access_key) ->
    u.SyncRun 'publish', ->
        u.log 'Searching for bubblebot server...'

        bbserver = create_bbserver()

        u.log 'Found bubblebot server'

        # Ensure we have the necessary deployment key installed
        # where does it get the private key from ? 
        bbserver.install_private_key config['deploy_key_path']

        # Clone our bubblebot installation to a fresh directory, and run npm install and npm test
        # TODO : look at this code
        install_dir = 'bubblebot-' + Date.now()
        bbserver.run('git clone ' + config['remote_repo'] + ' ' + install_dir)
        bbserver.run("cd #{install_dir} && npm install", {timeout: 300000})

        # Create a symbolic link pointing to the new directory, deleting the old one if it exits
        bbserver.run('rm -rf bubblebot-old', {can_fail: true})
        bbserver.run("mv $(readlink #{config['install_directory']}) bubblebot-old", {can_fail: true})
        bbserver.run('unlink ' + config['install_directory'], {can_fail: true})
        bbserver.run('ln -s ' + install_dir + ' ' +  config['install_directory'])

        #Ask bubblebot to restart itself
        try
            # TODO : before this, change config etc to contain releveant information so can use builtin code paths later
            results = bbserver.run("curl -X POST http://localhost:8081/shutdown")
            if results.indexOf(bubblebot_server.SHUTDOWN_ACK) is -1
                throw new Error 'Unrecognized response: ' + results
        catch err
            u.log 'Was unable to tell bubble bot to restart itself.  Server might not be running.  Will restart manually.  Error was: \n' + err.stack
            # make sure supervisord is running
            software.supervisor_start(true) bbserver
            # stop bubblebot if it is running
            bbserver.run('supervisorctl stop bubblebot', {can_fail: true})
            # start bubblebot
            res = bbserver.run('supervisorctl start bubblebot')
            if res.indexOf('ERROR (abnormal termination)') isnt -1
                console.log 'Error starting supervisor, tailing logs:'
                bbserver.run('tail -n 100 /tmp/bubblebot*')
            else
                u.log 'Waiting twenty seconds to see if it is still running...'
                try
                    software.verify_supervisor bbserver, 'bubblebot', 20
                catch err
                    console.log err.message

        process.exit()