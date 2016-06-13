commands = exports

build = ->
    u.log u.run_local 'rm npm-shrinkwrap.json', {can_fail: true}
    u.log u.run_local 'npm prune'
    u.run_local 'npm install'
    u.run_local 'npm dedupe'
    u.run_local 'npm shrinkwrap'
    u.log 'Build complete'


commands.build = ->
    u.SyncRun ->
        build()
        process.exit()

commands.publish = (access_key, secret_access_key) ->
    u.SyncRun ->
        #Load the local configuration from disk
        config.init()

        #Indicate that we are running from the command line
        config.set 'command_line', true

        #If the user passed in an access key / secret, set it
        if access_key
            u.log 'Got access key from command line: ' + access_key
            config.set('accessKeyId', access_key)
        if secret_access_key
            u.log 'Got secret from command line'
            config.set('secretAccessKey', secret_access_key)

        config.init_account_specific()

        u.log 'Searching for bubblebot server...'

        bbserver = bbobjects.get_bbserver()

        u.log 'Found bubblebot server'

        #First, try the quick version.  On error, do a full version
        try
            bbserver.run("cd bubblebot && git pull")
            bbserver.run("cd bubblebot && npm install")

        catch err
            u.log 'Error trying quick update.  Will do full update.  Error:\n' + err.stack

            #Ensure we have the necessary deployment key installed
            bbserver.install_private_key config.get('deploy_key_path')

            #Clone our bubblebot installation to a fresh directory, and run npm install and npm test
            install_dir = 'bubblebot-' + Date.now()
            bbserver.run('git clone ' + config.get('remote_repo') + ' ' + install_dir)
            bbserver.run("cd #{install_dir} && npm install")

            #Create a symbolic link pointing to the new directory, deleting the old one if it exits
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
            #make sure supervisord is running
            bbserver.run('supervisord -c /etc/supervisord.conf', {can_fail: true})
            #stop bubblebot if it is running
            bbserver.run('supervisorctl stop bubblebot', {can_fail: true})
            #start bubblebot
            res = bbserver.run('supervisorctl start bubblebot')
            if res.indexOf('ERROR (abnormal termination)') isnt -1
                failure = true

            if not failure
                u.log 'Waiting a few seconds to see if it is still running...'
                u.pause 5000
                res = bbserver.run('supervisorctl status bubblebot')
                if res.indexOf('RUNNING') is -1
                    failure = true

            if failure
                console.log 'Error starting supervisor, tailing logs:'
                bbserver.run('tail -n 100 /tmp/bubblebot*')

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

update = ->
    u.log 'Checking for updates...'
    u.log u.run_local 'rm npm-shrinkwrap.json', {can_fail: true}
    u.log u.run_local 'npm install bubblebot'
    u.log u.run_local 'npm update bubblebot'


commands.update = ->
    u.SyncRun ->
        update()
        build()
        process.exit()

commands.dev = ->
    u.SyncRun ->
        u.log u.run_local 'coffee -o node_modules/bubblebot/lib -c node_modules/bubblebot/src/*.coffee && node node_modules/bubblebot/node_modules/eslint/bin/eslint.js node_modules/bubblebot/lib'
        process.exit()

commands.set_config = (name, value) ->
    u.SyncRun ->
        config.init()
        config.set 'command_line', true
        config.init_account_specific()

        config.set_secure name, value
        u.log 'config set successfully'
        process.exit()

#Prints the help for the bubblebot command line tool
commands.print_help = ->
    u.log 'Available commands:'
    u.log '  install -- creates default files for a bubblebot installation'
    u.log '  build -- packages this directory for distribution'
    u.log '  publish -- deploys bubblebot to a remote repository'
    u.log '  update  -- updates the bubblebot code (npm update bubblebot)'
    u.log '  dev -- builds bubblebot assuming a development symlink'
    u.log '  set_config [name] [value] -- stores a secure config option in s3'
    process.exit()


u = require './utilities'
fs = require 'fs'
os = require 'os'
config = require './config'
strip_comments = require 'strip-json-comments'
path = require 'path'
bubblebot_server = require './bbserver'
bbobjects = require './bbobjects'