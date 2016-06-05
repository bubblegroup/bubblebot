config = exports

_config = null


plugins = {}

plugin_names = ['metrics', 'alerting']

#Sets the given plugin
config.set_plugin = (name, plugin) ->
    if name not in plugin_names
        throw new Error 'unrecognized plugin name: ' + name
    plugins[name] ?= []
    plugins[name].push plugin

#Gets the plugins installed for the given name
config.get_plugins = (name) ->
    if name not in plugin_names
        throw new Error 'unrecognized plugin name: ' + name
    return plugins[name] ? []

#Initializes bubblebot with a set of configuration options
#If options is null, loads the configuration from disk
config.init = (options) ->
    if not options?
        #Load the options from disk
        u.log 'Loading options from disk: ' + config.get('configuration_file') + ' (cwd: ' + process.cwd() + ')'
        _config = JSON.parse strip_comments fs.readFileSync config.get('configuration_file'), {encoding: 'utf8'}

    else
        _config = JSON.parse JSON.stringify options


#load any account specific configuration
config.init_account_specific = ->
    u.log 'Loading account specific environment'

    #Get the id of the AWS user we are running as
    aws_user = bbobjects.bubblebot_environment().get_aws_user()

    u.log 'AWS user: ' + aws_user.UserName + ' ' + aws_user.UserId

    env_config_path = aws_user.UserId + '.json'
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

#Retrieves an individual key, throwing an error if undefined
#
#Can pass a value for default (including null) to avoid throwing an error
config.get = (key, default_value) ->
    val = _config?[key]
    if not val?
        if DEFAULTS[key]?
            if typeof(DEFAULTS[key]) is 'function'
                return DEFAULTS[key]()
            else
                return DEFAULTS[key]
        if default_value isnt undefined
            return default_value
        throw new Error 'Missing configuration key: ' + key
    return val

#Sets a key on our configuration
config.set = (key, value) ->
    _config[key] = value

#Retrieves all the config options as JSON
config.export = -> return JSON.stringify _config


#Asks the user for a value and stores it
_prompts = {}
prompt_for = (key, schema) ->
    if not schema?
        schema = [key]

    if not _prompts[key]?
        prompt.start()
        block = u.Block('prompt')
        prompt.get(schema, block.make_cb())
        res = block.wait()
        _prompts[key] = res[key]

    return _prompts[key]



#Some hard-coded configuration defaults.  This is mostly for bootstrapping... most defaults
#should be put in the configuration.json template file.
DEFAULTS =
    configuration_file: 'configuration.json'
    accessKeyId: ->
        #If this is running on the command line, prompt for it
        #otherwise, return null to indicate we are using IAM roles
        if not config.get('command_line', false)
            return null
        return prompt_for 'AWS access key'

    secretAccessKey: ->
        #If this is running on the command line, prompt for it
        #otherwise, return null to indicate we are using IAM roles
        if not config.get('command_line', false)
            return null
        return prompt_for 'AWS secret', {properties: {"AWS secret": {hidden: true}}}

    remote_repo: -> u.run_local('git config --get remote.origin.url').trim()

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




strip_comments = require 'strip-json-comments'
fs = require 'fs'
prompt = require 'prompt'
u = require './utilities'

bbobjects = require './bbobjects'