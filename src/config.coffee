config = exports

_config = null

#Initializes bubblebot with a set of configuration options
#If options is null, loads the configuration from disk
config.init = (options) ->
    if not options?
        #Load the options from disk
        _config = JSON.parse strip_comments fs.readSync config.get('configuration_file'), {encoding: 'utf8'}
    else
        _config = JSON.parse JSON.stringify options

#Retrieves an individual key, throwing an error if undefined
config.get = (key) ->
    val = _config?[key]
    if not val?
        if DEFAULTS[key]?
            return DEFAULTS[key]
        throw u.error 'Missing configuration key: ' + key
    return val

#Sets a key on our configuration
config.set = (key, value) ->
    _config[key] = value

#Retrieves all the config options as JSON
config.export = -> return JSON.stringify _config


#Some hard-coded configuration defaults.  This is mostly for bootstrapping... most defaults
#should be put in the configuration.json template file.
DEFAULTS =
    configuration_file: 'configuration.json'

strip_comments = require 'strip-json-comments'