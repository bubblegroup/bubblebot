commands = exports


commands.publish = (access_key) ->
    u.SyncRun ->
        #Load the local configuration from disk
        config.init()

        #Indicate that we are running from the command line
        config.set 'command_line', true

        #Prompt the user for the credentials
        if not access_key
            prompt.start()
            block = u.Block('prompt')
            prompt.get(['access_key'], block.make_cb())
            {access_key} = block.wait()

        u.log 'Publishing to account ' + access_key

        config.set 'accessKeyId', access_key

        #load any access_key specific configuration
        env_config_path = access_key + '.json'
        try
            raw = fs.readFileSync env_config_path, {encoding: 'utf8'}
        catch err
            u.log "Creating #{env_config_path} to save access-key-specific configuration..."
            raw = '{\n//Store access-key-specific configuration here\n}'
            fs.writeFileSync env_config_path, raw

        try
            for k, v of JSON.parse strip_comments raw
                config.set k, v
        catch err
            u.log 'Error parsing ' + env_config_path + '; make sure it is valid json!'
            throw err

        #Prompt for the secret
        if not config.get 'secretAccessKey', null
            prompt.start()
            block = u.Block('prompt')
            prompt.get({properties: {secret: {hidden: true}}}, block.make_cb())
            {secret} = block.wait()

            config.set 'secretAccessKey', secret

        cloud = new clouds.AWSCloud()

        u.log 'Searching for bubblebot server...'

        bbserver = cloud.get_bbserver()

        if not bbserver
            u.log 'There is no bubble bot server in this environment.  Creating one...'
            bbserver = cloud.create_bbserver()

        u.log 'Found bubblebot server'

        #Capture the current directory to a tarball, upload it, and delete it
        temp_file = u.create_tarball(process.cwd())
        u.log 'Saved current directory to ' + temp_file
        bbserver.upload_file(temp_file, '~')
        bbserver.run("tar -xf ~/#{temp_file} -C #{config.get('install_directory')}")
        bbserver.run("rm ~/#{temp_file}")
        fs.removeFileSync temp_file

        #Save the configuration information to bubblebot
        bbserver.write_file(config.export(), config.get('install_directory') + config.get('configuration_file'))

        #Ask bubblebot to restart itself
        try
            bbserver.run("curl -X POST http://localhost:8081/shutdown")
        catch err
            u.log 'Was unable to tell bubble bot to restart itself.  Server might not be running.  Will restart manually.  Error was: \n' + err.stack
            #make sure supervisord is running
            bbserver.run('sudo supervisord -c /etc/supervisord.conf', {can_fail: true})
            #stop bubblebot if it is running
            bbserver.run('sudo supervisorctl stop bubblebot', {can_fail: true})
            #start bubblebot
            bbserver.run('sudo supervisorctl start bubblebot')

        process.exit()


#Installs bubblebot into a directory
#If force is set to "force", overwrites existing files
commands.install = (force) ->
    force = force is "force"

    u.SyncRun ->
        for name in ['run.js', 'configuration.json']
            u.log 'Creating ' + name
            data = fs.readFileSync __dirname + '/../templates/' + name
            try
                fs.writeFileSync name, data, {flag: if force then 'w' else 'wx'}
            catch err
                u.log 'Could not create ' + name + ' (a file with that name may already exist)'

        u.log 'Installation complete!'

        process.exit()

commands.update = ->
    u.SyncRun ->
        u.log 'Checking for updates...'
        u.log u.run_local 'npm install bubblebot'
        u.log u.run_local 'npm update bubblebot'

        process.exit()


#Prints the help for the bubblebot command line tool
commands.print_help = ->
    u.log 'Available commands:'
    u.log '  install -- creates default files for a bubblebot installation'
    u.log '  publish -- deploys bubblebot to a remote repository'
    u.log '  update  -- updates the bubblebot code (npm update bubblebot)'
    process.exit()


u = require './utilities'
clouds = require './clouds'
fs = require 'fs'
os = require 'os'
config = require './config'
prompt = require 'prompt'
strip_comments = require 'strip-json-comments'