plugins = exports
plugins.librato = require './librato'
plugins.pagerduty = require './pagerduty'
plugins.sentry = require './sentry'

#Given a plugin type and fn name, finds and executes our plugin for that type
run_fn = (plugin_type, fn_name, args...) ->
    ret = undefined
    for plugin in config.get_plugins(plugin_type)
        if typeof(plugin[fn_name]) is 'function'
            ret = plugin[fn_name] args...
    return ret

#Increments a metric
plugins.increment = (source, name, value) ->
    run_fn 'metrics', 'increment', source, name, value

#Measures a metric
plugins.measure = (source, name, value) ->
    run_fn 'metrics', 'measure', source, name, value

config = require './../config'