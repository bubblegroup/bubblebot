config = exports

_config = null

#Initializes bubblebot with a set of configuration options, adding defaults as necessary
config.init = (config) ->
    _config = JSON.parse JSON.stringify config
    _config.install_directory ?= '~/bubblebot/'
    _config.configuration_file ?= 'saved_config.json'

#Retrieves an individual key, throwing an error if undefined
config.get = (key) ->
    val = _config[key]
    if not val?
        throw u.error 'Missing configuration key: ' + key
    return val

#Retrieves all the config options as JSON
config.export = -> return JSON.stringify _config