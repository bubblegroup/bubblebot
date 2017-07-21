fs = require 'fs'
AWS = require 'aws-sdk'
strip_comments = require 'strip-json-comments'

bbobjects = require './bbobjects'
software = require './software'

test_credentials = JSON.parse(fs.readFileSync('test_credentials.json'))
config = JSON.parse strip_comments fs.readFileSync('configuration.json').toString()
config_ = {
    run_file: 'run.js'
    install_directory: '/home/ec2-user/bubblebot'
    deploy_key_path : 'deploy_key_rsa'
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
    bubblebot_use_https: false,
    # TODO : what is this ?
    remote_repo: 'bubblebot'
    }

for key, val of config_
    config[key] = val

REGION = config['bubblebot_region']
console.log(config)

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

# Copied and pasted from bbobjects; this essentially creates an EC2 Instance
aws_config = () ->
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

call_aws_api = () ->
    return

create_bbserver = () ->
    aws_config()

    environment = bbobjects.bubblebot_environment()

    image_id = config['bubblebot_image_id']
    instance_type = config['bubblebot_instance_type']
    instance_profile = config['bubblebot_instance_profile']

    id = environment.create_server_raw image_id, instance_type, instance_profile
    environment.tag_resource id, 'Name', 'Bubble Bot'

    # TODO : how does this work. does it set up on a new machine? is there an ssh needed?
    instance = bbobjects.instance 'EC2Instance', id
    # instance.create()

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

# Gets the underlying AWS service object
# get_svc = (service) ->
#     get_aws_service service, @get_region()

# If we are in the database, we can get the environment's region.
# We also maintain a cache of regions by id, for dealing with objects that
# exist in AWS but don't have a region
# get_region = () ->
#     environment = @environment()
#     if environment
#         return environment.get_region()
#     region = region_cache.get(@type + '-' + @id)
#     if region
#         return region
#     throw new Error 'could not find a region for ' + @type + ' ' + @id + '.  Please use cache_region...'

# TODO : what is going to call this function ? 
# Copied and pasted from commands.publish()
copy_to_test_server = (access_key, secret_access_key) ->
    u.SyncRun 'publish', ->
        u.log 'Searching for bubblebot server...'

        bbserver = create_bbserver()

        u.log 'Found bubblebot server'

        # Ensure we have the necessary deployment key installed
        bbserver.install_private_key config['deploy_key_path']

        # Clone our bubblebot installation to a fresh directory, and run npm install and npm test
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