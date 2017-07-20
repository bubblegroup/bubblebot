fs = require 'fs'
bbobjects = require './bbobjects'

# hacky, where will this be in production ? 
# test_credentials = JSON.parse(fs.readFileSync('AKIAIEFNCTPKEJ4GUE3A.json'))
config = fs.readFileSync('configuration.json')
config = JSON.parse(JSON.stringify(config.toString()))

# Copied and pasted from bbobjects; this essentially creates an EC2 Instance
# config['bubblebot_region']: null,
aws_config = () ->
    accessKeyId = test_credentials['accessKeyId']
    secretAccessKey = test_credentials['secretAccessKey']
    res = {
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

create_bbserver = () ->
    # create bubblebot environment
    environment = bbobjects.bubblebot_environment()

    # TODO: is this the proper order ? 
    aws_config()

    # TODO : where do these come from? 
    # config has to be set before these
    image_id = config.get('bubblebot_image_id')
    instance_type = config.get('bubblebot_instance_type')
    instance_profile = config.get('bubblebot_instance_profile')

    # TODO : what is the id
    id = environment.create_server_raw image_id, instance_type, instance_profile

    environment.tag_resource id, 'Name', 'Bubble Bot'

    # TODO : how does this work. does it set up on a new machine? is there an ssh needed?
    instance = bbobjects.instance 'EC2Instance', id

    u.log 'bubblebot server created, waiting for it to ready...'

    #manually set environment because we can't check database
    instance.environment = -> environment

    # TODO : what does this do
    instance.wait_for_ssh()

    u.log 'bubblebot server ready, installing software...'

    # Install node and supervisor
    command = 'node ' + config.get('install_directory') + '/' + config.get('run_file')

    software.supervisor('bubblebot', command, config.get('install_directory')) instance
    software.node('4.4.5') instance
    software.pg_dump96() instance
    software.supervisor_auto_start() instance

    environment.tag_resource id, config.get('bubblebot_role_tag'), config.get('bubblebot_role_bbserver')

    u.log 'bubblebot server has base software installed'

    startup_bbserver instance

    return instance

 #Gets the underlying AWS service object
get_svc = (service) ->
    get_aws_service service, @get_region()

#If we are in the database, we can get the environment's region.
#We also maintain a cache of regions by id, for dealing with objects that
#exist in AWS but don't have a region
get_region = () ->
    environment = @environment()
    if environment
        return environment.get_region()
    region = region_cache.get(@type + '-' + @id)
    if region
        return region
    throw new Error 'could not find a region for ' + @type + ' ' + @id + '.  Please use cache_region...'

# TODO : what is going to call this function ? 
# Copied and pasted from commands.publish()

test_credentials = {
    #THIS IS THE TEST ACCOUNT

    #AccessKeyID
    "accessKeyId" : "AKIAIEFNCTPKEJ4GUE3A",
    
    #Secret.  Storing it here because this is just a test account -- don't do this for production!!
    "secretAccessKey": "o5hzE6ALakxe0R7ma5iJCplLAAzYt7E+P4xZfRgr",

    "bubblebot_vpc": "vpc-cd2bf9a9",
    "slack_token": "xoxb-4998842545-FkdRlHVMa6hOaA0nf5aUNQXE",
    
    #The permissions we run bubblebot server with
    "bubblebot_instance_profile": {
        "Arn": "arn:aws:iam::046929484307:instance-profile/bubblebot_server"
    },
    
    "this_is_to": "absorb_commas"
}


# TODO : 
copy_to_test_server = (access_key, secret_access_key) ->
    u.SyncRun 'publish', ->
        u.log 'Searching for bubblebot server...'

        # TODO : this will not work by itself, we need to CREATE a new server
        bbserver = create_bbserver()

        u.log 'Found bubblebot server'

        # Ensure we have the necessary deployment key installed
        bbserver.install_private_key config.get('deploy_key_path')

        # Clone our bubblebot installation to a fresh directory, and run npm install and npm test
        install_dir = 'bubblebot-' + Date.now()
        bbserver.run('git clone ' + config.get('remote_repo') + ' ' + install_dir)
        bbserver.run("cd #{install_dir} && npm install", {timeout: 300000})

        # Create a symbolic link pointing to the new directory, deleting the old one if it exits
        bbserver.run('rm -rf bubblebot-old', {can_fail: true})
        bbserver.run("mv $(readlink #{config.get('install_directory')}) bubblebot-old", {can_fail: true})
        bbserver.run('unlink ' + config.get('install_directory'), {can_fail: true})
        bbserver.run('ln -s ' + install_dir + ' ' +  config.get('install_directory'))

        #Ask bubblebot to restart itself
        try
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

if require.main is module
    console.log config
    console.log test_credentials