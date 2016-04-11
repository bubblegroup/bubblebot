commands = exports


commands.publish = (configuration) ->
    #Set up the configuration for the remainder of this call
    config.init configuration

    cloud = new clouds.Cloud()

    bbserver = cloud.get_bbserver()

    if not bbserver
        winston.log 'There is no bubble bot server in this environment.  Creating one...'
        bbserver = cloud.create_bbserver()

    #Capture the current directory to a tarball, upload it, and delete it
    temp_file = u.create_tarball(process.cwd())
    bbserver.upload_file(temp_file, config.get('install_directory'))
    fs.removeFileSync temp_file

    #Save the configuration information to bubblebot
    bbserver.write_file(config.export(), config.get('install_directory') + config.get('configuration_file'))

    #Ask bubblebot to restart itself
    try
        bbserver.post_authenticated('/restart_me')
    catch err
        winston.log 'Was unable to tell bubble bot to restart itself.  Server might not be running.  Will restart manually.  Error was: \n' + err.stack
        #make sure supervisord is running
        bbserver.run('sudo supervisord -c /etc/supervisord.conf', {can_fail: true})
        #stop bubblebot if it is running
        bbserver.run('sudo supervisorctl stop bubblebot', {can_fail: true})
        #start bubblebot
        bbserver.run('sudo supervisorctl start bubblebot')


#Starts bubble bot running on a machine, including the web server and slack client
commands.start_server = ->
    #Load the configuration from disk
    saved_config = fs.readSync config.get('install_directory') + config.get('configuration_file'), {encoding: 'utf8'}
    config.init JSON.parse saved_config






u = require './utilities'
clouds = require './clouds'
winston = require 'winston'
fs = require 'fs'
os = require 'os'
config = require './config'