config = exports

_config = null


plugins = {}

plugin_names = ['metrics', 'alerting', 'bug_report']

#Adds the given plugin to this category
config.add_plugin = (name, plugin) ->
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

    #If we have the aws username, use that to find the json file...

    if _config.accessKeyId
        env_config_path = _config.accessKeyId + '.json'
        try
            raw = fs.readFileSync env_config_path, {encoding: 'utf8'}
            u.log 'Loaded account specific config from ' + env_config_path
        catch err
            u.log "Creating #{env_config_path} to save access-key-specific configuration..."
            raw = '{\n//Store access-key-specific configuration here\n}'
            fs.writeFileSync env_config_path, raw

        try
            specific_config = JSON.parse strip_comments raw
        catch err
            u.log 'Error parsing ' + env_config_path + '; make sure it is valid json!'
            throw err

        #Save the configuration to S3
        bbobjects.put_s3_config 'bubblebot_account_specific_config.json', JSON.stringify specific_config

    #Otherwise, load it from s3
    else
        from_s3 = bbobjects.get_s3_config 'bubblebot_account_specific_config.json'
        if not from_s3?
            throw new Error 'could not find bubble account specific configuration in s3'
        specific_config = JSON.parse from_s3

    #And add it to our configuration
    for k, v of specific_config
        config.set k, v


#We cache values from get_secure to avoid having to hit S3 each time
_secure_cache = {}

#Gets a configuration option that we want to store in S3 instead of in code.
#
#This is not used in the bubblebot codebase, but can be useful for specific
#instances of bubblebot to save credentials
config.get_secure = (name, missing_okay) ->
    if not _secure_cache[name]?
        res = bbobjects.get_s3_config 'bubblebot_config_get_secure_' + name
        if not res?
            if missing_okay
                return null
            throw new Error 'missing secure config ' + name + ': use bubblebot set_config [name] [value]'
        _secure_cache[name] = res
    return _secure_cache[name]

#See get_secure above.  Should be called from the bubblebot command line tool via:
#
#bubblebot set_config [name] [value]
config.set_secure = (name, value) ->
    bbobjects.put_s3_config 'bubblebot_config_get_secure_' + name, value
    _secure_cache[name] = value





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

    bubblebot_domain: ''

    bubblebot_use_https: false




strip_comments = require 'strip-json-comments'
fs = require 'fs'
prompt = require 'prompt'
u = require './utilities'

bbobjects = require './bbobjects'