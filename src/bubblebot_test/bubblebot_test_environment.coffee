# TODO : merge test_credentials and configuration, make sure script writes them to s3 
# with key (see config.coffee for how to construct key) get bubblebot running 

# TODO : Commit should be an input

test_env = exports

fs = require 'fs'
AWS = require 'aws-sdk'
Fiber = require 'fibers'
strip_comments = require 'strip-json-comments'
child_process = require 'child_process'

ssh = require '../ssh'
u = require '../utilities'
software = require '../software'
constants = require '../constants'
bbobjects = require '../bbobjects'

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
    remote_repo: child_process.execSync('git config --get remote.origin.url').toString().trim()
    }

for key, val of config_
    config[key] = val

for key, val of test_credentials
    config[key] = val

REGION = config['bubblebot_region']

# TODO : ask Josh, what is the difference between this and the aws_config
AWS.config.update({region: config['bubblebot_region']})

SERVER_ID = null

# NOTE : here I had to manually code REGION
get_region = () ->
    return REGION

aws_config = (REGION) ->
    # NOTE : Here I had to manually code test credentials
    accessKeyId = test_credentials['accessKeyId']
    secretAccessKey = test_credentials['secretAccessKey']
    res = {
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

# NOTE : caching globally. perhaps we should cache within an object?
AWS_CACHE = {}
get_aws_service = (name, region) ->
    key = name + ' ' + region
    if not AWS_CACHE[name]?
        svc = u.retry 20, 2000, =>
            AWS_CACHE[name] = new AWS[name] aws_config(REGION)
            u.log AWS_CACHE
            return AWS_CACHE[name]
        return svc
    else
        return AWS_CACHE[name]

get_svc = (service) ->
    get_aws_service service, REGION

aws = (service, method, parameters) ->
    svc = get_svc service
    block = u.Block method
    svc[method] parameters, block.make_cb()
    return block.wait()

ec2 = (method, parameters) ->
    aws 'EC2', method, parameters

s3 = (method, parameters) ->
    aws('S3', method, parameters)













# NOTE : here I had to manually code something; this was originally get('vpc'), but Fiber.current is null
get_vpc = () -> return config['bubblebot_vpc']

# Returns the raw data for all subnets in the VPC for this environments
get_all_subnets = (force_refresh) ->
    vpc_id = config['bubblebot_vpc'] # get_vpc()

    if not force_refresh
        data = vpc_to_subnets.get(vpc_id)
        if data?
            return data

    data = ec2('describeSubnets', {Filters: [{Name: 'vpc-id', Values: [vpc_id]}]})
    return data

get_subnet = () ->
    data = get_all_subnets(true)
    console.log(data)

    for subnet in data.Subnets ? []
        if subnet.State is 'available' and subnet.AvailableIpAddressCount > 0
            return subnet.SubnetId

    throw new Error 'Could not find a subnet!  Data: ' + JSON.stringify(data)

















# Returns the keypair name for this environment, or creates it if it does not exist
get_keypair_name = ->
    # NOTE : had to manually code constants.BUBBLEBOT_ENV
    name = config['keypair_prefix'] + constants.BUBBLEBOT_ENV

    # Check to see if it already exists
    try
        pairs = ec2('describeKeyPairs', {KeyNames: [name]})
    catch err
        if String(err).indexOf('does not exist') is -1
            u.log String(err)
            throw err

        u.log 'generating new key pair...'

        # If not, create it
        {private_key, public_key} = u.generate_key_pair()
        u.log public_key

        # Save the private key to s3
        bbobjects.put_s3_config name, private_key

        # Strip the header and footer lines
        public_key = public_key.split('-----BEGIN PUBLIC KEY-----\n')[1].split('\n-----END PUBLIC KEY-----')[0]

        # And save the public key to ec2 to use in server creation
        u.log 'importKeyPair'
        ec2('importKeyPair', {KeyName: name, PublicKeyMaterial: public_key})

    return name















# NOTE : this is redundant; get_security_group_data is called previously for no reason
ensure_security_group_rules = (group_name, rules, retries = 2) ->
    data = get_security_group_data(group_name, true)
    to_remove = []
    to_add = []

    # current rules
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

allow_outside_ssh = () ->
    # We allow direct SSH connections to bubblebot to allow for deployments.
    # The security key for connecting should NEVER be saved locally!
    return true

#Given a security group name, fetches its meta-data (using the cache, unless force-refresh is on)
#Creates the group if there is not one with this name.
get_security_group_data = (group_name, force_refresh, retries = 2) ->
    data = ec2('describeSecurityGroups', {Filters: [{Name: 'group-name', Values: [group_name]}]}).SecurityGroups[0]
    if data?
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

get_webserver_security_group = () ->
    # NOTE : had to manually code constants.BUBBLEBOT_ENV
    group_name = constants.BUBBLEBOT_ENV + '_webserver_sg'

    # TODO : extra work done here
    id = get_security_group_id(group_name, true)

    rules = [
        #Allow outside world access on 80 and 443
        {IpRanges: [{CidrIp: '0.0.0.0/0'}], IpProtocol: 'tcp', FromPort: 80, ToPort: 80}
        {IpRanges: [{CidrIp: '0.0.0.0/0'}], IpProtocol: 'tcp', FromPort: 443, ToPort: 443}
        #Allow other boxes in this security group to connect on any port
        {UserIdGroupPairs: [{GroupId: id}], IpProtocol: '-1'}
    ]
    #If this is a server people are allowed to SSH into directly, open port 22.
    if allow_outside_ssh()
        rules.push {IpRanges: [{CidrIp: '0.0.0.0/0'}], IpProtocol: 'tcp', FromPort: 22, ToPort: 22}

    ensure_security_group_rules group_name, rules
    return id



















create_server_raw = (ImageId, InstanceType, IamInstanceProfile) ->
    u.log 'getting key pair name...'
    KeyName = get_keypair_name()

    # TODO : what is a security group ? 
    u.log 'getting security groups...'
    security_group_id = get_webserver_security_group()
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
        IamInstanceProfile: {Name: IamInstanceProfile}
        KeyName
        SecurityGroupIds
        InstanceType
        InstanceInitiatedShutdownBehavior
    }

    u.log 'Creating new ec2 instance: ' + JSON.stringify(params, null, 4)
    results = ec2 'runInstances', params

    id = results.Instances[0].InstanceId
    u.log 'EC2 succesfully created with id ' + id
    return id


_startup_ran = false
# Code that we run each time on startup to make sure bbserver is up to date.  Should
# be idempotent
startup_bbserver = (instance) ->
    if _startup_ran
        return
    _startup_ran = true

    try
        software.metrics() instance
    catch err
        #We don't want to kill server startup if this fails
        u.log err










tag_resource = (id, Key, Value) ->
    ec2('createTags', {
        Resources: [id]
        Tags: [{Key, Value}]
    })
















_ssh_expected = (err) ->
    if String(err).indexOf('Timed out while waiting for handshake') isnt -1
        return true
    if String(err).indexOf('ECONNREFUSED') isnt -1
        return true
    if String(err).indexOf('All configured authentication methods failed') isnt -1
        return true
    return false

#Returns the state of the instance.  Set force_refresh to true to check for changes.
get_state = (force_refresh) -> get_data(force_refresh).State.Name

#Waits til the server is in the running state
wait_for_running = (retries = 20, target_state = 'running') ->
    u.log 'waiting for server to be ' + target_state + ' (' + retries + ')'
    data = ec2('describeInstances', {InstanceIds:[SERVER_ID]})
    
    reservations = data.Reservations ? []
    instances = reservations[0].Instances ? []
    machine = instances[0]
    
    if machine.State.Name is target_state
        return
    else if retries is 0
        throw new Error 'timed out while waiting for ' + @id + ' to be ' + target_state + ': ' + @get_state()
    else
        u.pause 10000
        wait_for_running(retries - 1, target_state)

# NOTE : here had to avoid hardcoded parameter
wait_for_ssh = () ->
    wait_for_running()
    do_wait = (retries = 20) =>
        u.log 'server running, waiting for it accept ssh connections (' + retries + ')'
        try
            bbserver_run 'hostname'
        catch err
            if retries is 0 or not _ssh_expected(err)
                throw err
            else
                u.pause 10000
                return do_wait(retries - 1)
    do_wait()


















# TODO : figure out what this does 
do_once = (name, fn) ->
    return () ->
        dependencies = bbserver_run('cat bubblebot_dependencies || echo "NOTFOUND"').trim()
        if dependencies.indexOf('NOTFOUND') isnt -1
            dependencies = ''
        if name in dependencies.split('\n')
            return

        fn()
        dependencies += '\n' + name
        bbserver_run 'cat > bubblebot_dependencies << EOF\n' + dependencies + '\nEOF'

#Sets up sudo and yum and installs GCC
basics = -> do_once 'basics', () ->
    #update yum and install git + development tools
    bbserver_run 'sudo yum update -y', {timeout: 5 * 60 * 1000}
    bbserver_run 'sudo yum -y install git'
    bbserver_run 'sudo yum install make automake gcc gcc-c++ kernel-devel git-core ruby-devel -y ', {timeout: 5 * 60 * 1000}

#Installs supervisor and sets it up to run the given command
supervisor = (name, command, pwd) -> () ->
    basics()()

    bbserver_run 'sudo pip install supervisor==3.1'
    bbserver_run '/usr/local/bin/echo_supervisord_conf > tmp'
    bbserver_run 'cat >> tmp <<\'EOF\'\n\n[program:' + name + ']\ncommand=' + command + '\ndirectory=' + pwd + '\n\nEOF'
    bbserver_run 'sudo su -c"mv tmp /etc/supervisord.conf"'

    #Set a big ulimit
    bbserver_run "echo '* soft nofile 1000000\n* hard nofile 1000000\n* soft nproc 1000000\n* hard nproc 1000000' | sudo tee /etc/security/limits.d/large.conf"

pg_dump96 = -> do_once 'pg_dump96', () ->
    bbserver_run 'sudo yum -y localinstall https://download.postgresql.org/pub/repos/yum/9.6/redhat/rhel-6-x86_64/pgdg-ami201503-96-9.6-2.noarch.rpm'
    bbserver_run 'sudo yum -y install postgresql96'

supervisor_auto_start = -> do_once 'supervisor_auto_start', () ->
    commands = """
    #start supervisor on startup
    sudo -u ec2-user -H sh -c "export PATH=/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:/opt/aws/bin:/home/ec2-user/.local/bin:/home/ec2-user/bin; supervisord" 

    #map port 80 -> 8080
    sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
    #map port 443 -> 8043
    sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8043
    """
    bbserver_run 'cat > /tmp/autostart <<\'EOF\'\n' + commands + '\n\nEOF'
    
    bbserver_run 'sudo su -c"cat /tmp/autostart >> /etc/rc.local"'
    bbserver_run 'rm /tmp/autostart'
    
# Given a local path to a private key, installs that as the main key on this box
write_github_private_key = (path) ->
    if path?
        key_data = fs.readFileSync path, 'utf8'
        put_s3_object('/bubblebot_test_github_key', key_data)
    else
        key_data = get_s3_object('/bubblebot_test_github_key') 
    
    if key_data?
        u.log 'Writing private key to ~/.ssh/id_rsa'
        bbserver_run 'cat > ~/.ssh/id_rsa << EOF\n' + key_data + '\nEOF', {no_log: true}
        bbserver_run 'chmod 600 /home/ec2-user/.ssh/id_rsa'

        #turn off strict host checking so that we don't get interrupted by prompts
        bbserver_run 'echo "StrictHostKeyChecking no" > ~/.ssh/config'
        bbserver_run 'chmod 600 /home/ec2-user/.ssh/config'
    else
        throw new Error('github private key missing!')

#Installs node
node = (version) -> do_once 'node ' + version, (instance) ->
    basics()()

    bbserver_run 'git clone https://github.com/tj/n'
    bbserver_run 'cd n; sudo make install'
    bbserver_run 'cd n/bin; sudo ./n ' + version, {timeout: 360000} #usually runs < 90 seconds, so if this keeps happening, probably just need to retry
    bbserver_run 'rm -rf n'


install_private_key = (path) ->
        private_key(path)








#Verifies that the given supervisor process is running for the given number of seconds
#
#If not, logs the tail and throws an error
verify_supervisor = (server, name, seconds) ->
    #Loop til we see it running initially
    retries = 0
    while (status = bbserver_run('supervisorctl status ' + name, {can_fail: true})).indexOf('RUNNING') is -1
        retries++
        if retries > 5
            throw new Error 'supervisor not reporting running after 20 seconds:\n' + status
        u.pause 4000

    #Then wait and see if it is still running
    u.pause (seconds + 2) * 1000
    status = bbserver_run 'supervisorctl status ' + name
    if status.indexOf('RUNNING') isnt -1
        uptime = status.split('uptime')[1].trim()
        uptime_seconds = parseInt(uptime.split(':')[2])
        uptime_minutes = parseInt(uptime.split(':')[1])
        uptime_hours = parseInt(uptime.split(':')[0])
        uptime_time = (uptime_minutes * 60) + uptime_seconds + (uptime_hours + 3600)
        if uptime_time >= seconds
            return
        else
            reason = 'up for ' + uptime_time + ' < ' + seconds
    else
        reason = 'not running'

    bbserver_run 'tail -n 100 /tmp/' + name + '*'

    throw new Error 'Supervisor not staying up ' + reason + '.\n' + status + '\nSee tailed logs below'

#Make sure ports are exposed and starts supervisord
supervisor_start = (can_fail) -> (instance) ->
    #If supervisord is already running, kills it.
    bbserver_run "sudo killall supervisord", {can_fail: true}

    #Redirects 80 -> 8080 so that don't have to run things as root
    bbserver_run "sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080", {can_fail}
    #And 443 -> 8043
    bbserver_run "sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8043", {can_fail}
    #Start supervisord
    bbserver_run "supervisord -c /etc/supervisord.conf", {can_fail}
    u.pause 5000
    u.log 'Started supervisord, checking status...'
    bbserver_run "supervisorctl status", {can_fail: true}













create_bbserver = () ->
    # TODO : sync run here
    environment = bbobjects.bubblebot_environment()

    image_id = config['bubblebot_image_id']
    instance_type = config['bubblebot_instance_type']
    instance_profile = config['bubblebot_instance_profile']

    u.log('creating raw server...')

    # awkward that this is done before bbobjects.instance 'EC2Instance'
    id = create_server_raw(image_id, instance_type, instance_profile)
    SERVER_ID = id

    instance = bbobjects.instance 'EC2Instance', id

    #manually set environment because we can't check database
    instance.environment = -> environment

    # what does this do ? 
    tag_resource(id, 'Name', 'Bubble Bot')

    u.log 'bubblebot server created, waiting for it to ready...'

    wait_for_ssh()

    u.log 'bubblebot server ready, installing software...'

    # Install node and supervisor
    command = 'node ' + config['install_directory'] + '/' + config['run_file']

    # does a bunch of stuff with yum 
    supervisor('bubblebot', command, config['install_directory'])()

    # does a bunch of stuff with node
    node('4.4.5')()
    
    # installs postgress and stuff
    pg_dump96()()
    
    # tmp autostart stuff
    supervisor_auto_start()()
    
    # tags a bunch of stuff
    tag_resource id, config['bubblebot_role_tag'], config['bubblebot_role_bbserver']

    u.log 'bubblebot server has base software installed'

    return instance










_cached_bucket = null
get_s3_config_bucket = ->
    if not _cached_bucket
        buckets = config['bubblebot_s3_bucket'].split(',')
        if buckets.length is 1
            _cached_bucket = buckets[0]
        else
            data = s3('listBuckets', {})
            our_buckets = (bucket.Name for bucket in data.Buckets ? [])
            for bucket in buckets
                if bucket in our_buckets
                    _cached_bucket = bucket
                    break
            if not _cached_bucket
                throw new Error 'Could not find any of ' + buckets.join(', ') + ' in ' + our_buckets.join(', ')
    return _cached_bucket


# Retrieves an S3 configuration file as a string, or null if it does not exists
get_s3_config = (Key) ->
    u.retry 3, 1000, ->
        try
            # TODO : make this an s3 method
            data = s3('getObject', {Bucket: get_s3_config_bucket(), Key})
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

get_s3_object = (Key) ->
    s3('getObject', {Bucket: bbobjects.get_s3_config_bucket(), Key})

# Put s3 object.
put_s3_object = (Key, Body) ->
    s3('putObject', {Bucket: get_s3_config_bucket(), Key, Body})

# Gets the private key that corresponds with @get_keypair_name()
get_private_key = ->
    keyname = get_keypair_name()
    try
        data = get_s3_config keyname
        return data
    catch err
        #We lost our key, so delete it
        if String(err).indexOf('NoSuchKey') isnt -1
            u.log 'Could not find private key for ' + keyname + ': deleting it!'
            ec2 'deleteKeyPair', {KeyName: keyname}
            throw new Error 'Could not retrieve private key for ' + keyname + '; deleted public key'
        throw err

# TODO : repair
describe_instances = (params) ->
    #http://docs.aws.amazon.com/AWSJavaScriptSDK/latest/AWS/EC2.html#describeInstances-property
    data = ec2('describeInstances', {InstanceIds:[SERVER_ID]})
    
    reservations = data.Reservations ? []
    instances = reservations[0].Instances ? []
    return instances[0]

refresh = -> return describe_instances({InstanceIds: [SERVER_ID]})

get_data = (force_refresh) ->
    return refresh()

get_public_ip_address = -> get_data().PublicIpAddress

get_address = -> get_public_ip_address()

bbserver_run = (command, options) ->
    return ssh.run get_address(), get_private_key(), command, options










#Saves the object's data to S3
backup = (filename) ->
    if not @exists()
        u.expected_error 'cannot backup: does not exist'
    if not filename
        throw new Error 'must include a filename'
    body = JSON.stringify @properties(), null, 4
    key = "#{@type}/#{@id}/#{filename}/#{Date.now()}.json"
    bbobjects.put_s3_config key, body
    u.reply 'Saved a backup to ' + key

backup_cmd =
    params: [
        {name: 'filename', default: 'backup', help: 'The name of this backup.  Backups are saved as type/id/filename/timestamp.json'}
    ]
    help: "Backs up this objects' properties to S3"
    groups: constants.BASIC













# Copied and pasted from commands.publish()
copy_to_test_server = (commit) ->
    u.SyncRun 'publish', ->
        u.log 'checking for bubblebot servers on AWS account...'

        # TODO : this does not work
        try
            servers = ec2('describeTags', {Filters : [{Name: 'tag', Values:['Bubble Bot']}]})
            u.log(JSON.stringify(servers))
            if servers.length > 0
                u.log "bubblebot server(s) already exists on AWS account " + JSON.stringify(servers)
                process.exit()
        catch err
            u.log "ERROR WAS: " + err
            u.log 'creating bubblebot test server...'
            bbserver = create_bbserver()

            u.log 'bubblebot server created.'

            # ensure we have the necessary deployment key installed
            # key here is the one used to talk to github API
            # TODO : this should save the key to/ get it from s3
            write_github_private_key('./bubblebot_test_github_key')

            # clone our bubblebot installation to a fresh directory, and run npm install and npm test
            # NOTE : was originally bbserver.run
            install_dir = 'bubblebot-' + Date.now()
            bbserver_run('git clone ' + config['remote_repo'] + ' ' + install_dir)
            bbserver_run("cd #{install_dir} && npm install coffeescript@1.6.3 && npm install --save coffee")
            bbserver_run("cd #{install_dir} && npm install", {timeout: 300000})
            if commit?
                try
                    bbserver_run("git checkout " + commit)
                catch err 
                    u.log "unable to checkout commit " commit + " ; " + err

            # create a symbolic link pointing to the new directory, deleting the old one if it exits
            bbserver_run('rm -rf bubblebot-old', {can_fail: true})
            bbserver_run("mv $(readlink #{config['install_directory']}) bubblebot-old", {can_fail: true})
            bbserver_run('unlink ' + config['install_directory'], {can_fail: true})
            bbserver_run('ln -s ' + install_dir + ' ' +  config['install_directory'])

            # ask bubblebot to restart itself
            try
                # change config etc to contain releveant information so can use builtin code paths later
                u.log 'writing config to s3...'
                put_s3_object('/bubblebot_test_config', JSON.stringify(config))
                u.log 'attempting restart...'
                results = bbserver_run("curl -X POST http://localhost:8081/shutdown")
                if results.indexOf(bubblebot_server.SHUTDOWN_ACK) is -1
                    throw new Error 'Unrecognized response: ' + results
            catch err
                u.log 'Was unable to tell bubble bot to restart itself.  Server might not be running.  Will restart manually.  Error was: \n' + err.stack
                # make sure supervisord is running
                supervisor_start(true) bbserver
                # stop bubblebot if it is running
                bbserver_run('supervisorctl stop bubblebot', {can_fail: true})
                # start bubblebot
                res = bbserver_run('supervisorctl start bubblebot')
                if res.indexOf('ERROR (abnormal termination)') isnt -1
                    u.log 'Error starting supervisor, tailing logs:'
                    bbserver_run('tail -n 100 /tmp/bubblebot*')
                else
                    u.log 'Waiting twenty seconds to see if it is still running...'
                    try
                        verify_supervisor bbserver, 'bubblebot', 20
                    catch err
                        u.log err.message

            process.exit()

if require.main is module
    copy_to_test_server()