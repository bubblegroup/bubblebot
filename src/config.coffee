config = exports

_config = null

#Initializes bubblebot with a set of configuration options
config.init = (config) ->
    _config = JSON.parse JSON.stringify config

#Retrieves an individual key, throwing an error if undefined
config.get = (key) ->
    val = _config[key]
    if not val?
        throw u.error 'Missing configuration key: ' + key
    return val

#Sets a key on our configuration
config.set = (key, value) ->
    _config[key] = value

#Retrieves all the config options as JSON
config.export = -> return JSON.stringify _config