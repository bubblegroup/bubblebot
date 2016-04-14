commands = exports


commands.publish = ->
    u.SyncRun ->
        #Load the local configuration from disk
        config.init()

        #Prompt the user for the master credential
        prompt.start()
        block = u.Block('master key')
        prompt.get(['access_key', 'secret'], block.make_cb())
        {access_key, secret} = block.wait()

        #Save the master key to our configuration
        config.set 'accessKeyId', access_key
        config.set 'secretAccessKey', secret

        cloud = new clouds.AWSCloud()

        bbserver = cloud.get_bbserver()

        if not bbserver
            winston.log 'There is no bubble bot server in this environment.  Creating one...'
            bbserver = cloud.create_bbserver()

        #Capture the current directory to a tarball, upload it, and delete it
        temp_file = u.create_tarball(process.cwd())
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
            winston.log 'Was unable to tell bubble bot to restart itself.  Server might not be running.  Will restart manually.  Error was: \n' + err.stack
            #make sure supervisord is running
            bbserver.run('sudo supervisord -c /etc/supervisord.conf', {can_fail: true})
            #stop bubblebot if it is running
            bbserver.run('sudo supervisorctl stop bubblebot', {can_fail: true})
            #start bubblebot
            bbserver.run('sudo supervisorctl start bubblebot')

        process.exit()


#Installs bubblebot into a directory
commands.install = ->
    u.SyncRun ->
        for name in ['run.js', 'configuration.json']
            console.log 'Creating ' + name
            data = fs.readFileSync __dirname + '/../templates/' + name
            try
                fs.writeFileSync name, data, {flag: 'wx'}
            catch err
                console.log 'Could not create ' + name + ' (a file with that name may already exist)'

        process.exit()

commands.update = ->
    u.SyncRun ->
        console.log 'Checking for updates...'
        console.log u.run_local 'npm update bubblebot'

        process.exit()


#Prints the help for the bubblebot command line tool
commands.print_help = ->
    console.log 'Available commands:'
    console.log '  install -- creates default files for a bubblebot installation'
    console.log '  publish -- deploys bubblebot to a remote repository'
    console.log '  update  -- updates the bubblebot code (npm update bubblebot)'
    process.exit()


#For testing purposes, fetches the latest bubblebot.
#Assumes that we are pointing to github, not npm, so does a coffeescript build
commands.test = ->
    u.SyncRun ->
        u.run_local 'npm update bubblebot'
        u.run_local 'coffee -o node_modules/bubblebot/lib -c node_modules/bubblebot/src'
        process.exit()


u = require './utilities'
clouds = require './clouds'
winston = require 'winston'
fs = require 'fs'
os = require 'os'
config = require './config'
strip_comments = require 'strip-json-comments'
prompt = require 'prompt'