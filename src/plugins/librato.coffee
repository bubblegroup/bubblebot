#Metrics plugin backed by Librato

librato = exports

get_agent_token = -> config.get 'plugins.librato.agent_token'

librato.get_server_metrics_software = -> software.do_once 'librato_server_metrics_software',  (instance) ->
    token = get_agent_token()

    instance.run 'curl -s https://metrics-api.librato.com/agent_installer/' + token


measures = {}
counts = {}

#Saves a measurement
librato.measure = (source, name, value) ->
    if not value?
        throw new Error 'librato.measure with null value for ' + source + ', ' + name

    start_flusher()

    measures[source] ?= {}
    measures[source][name] ?= []
    measures[source][name].push value


#Increments a counter
librato.increment = (source, name, value = 1) ->
    if not name or typeof(name) is 'number'
        throw new Error 'librato.increment without a name'

    start_flusher()

    counts[source] ?= {}
    counts[source][name] ?= 0
    counts[source][name] += value


#Sends an annotation
librato.annotate = (stream, title, description) ->
    librato_client().post '/annotations/' + stream, {
        title
        description
    }, (err, res) ->
        if err
            throw err



LIBRATO_INTERVAL = 10 * 1000

librato_client = -> librato_metrics.createClient {
    email: config.get 'plugins.librato.email'
    token: config.get 'plugins.librato.token'
}

sanitize_source = (source) ->
    source = source.replace(/[^A-Za-z0-9\.:\-_]/g, '.')
    source = source[...63]
    return source

_flusher_on = false
start_flusher = ->
    if _flusher_on
        return
    _flusher_on = true

    setInterval ->
        gauges = []

        for source, data of measures
            for name, values of data
                gauges.push {
                    source: sanitize_source source
                    name
                    count: values.length
                    sum: values.reduce ((prev, cur) -> prev + cur), 0
                    max: Math.max values...
                    min: Math.min values...
                    sum_squares: values.reduce ((prev, cur) -> prev + (cur * cur)), 0
                }

        for source, data of counts
            for name, count of data
                gauges.push {
                    source: sanitize_source source
                    name
                    value: count
                }

        measures = {}
        counts = {}

        if gauges.length > 0
            librato_client().post '/metrics', {
                gauges
            }, (err, res) ->
                if err
                    u.log 'Error posting to librato: ' + (if res then '\n' + JSON.stringify(res) + '\n' else '') + (err.stack ? err)

    , LIBRATO_INTERVAL



config = require './../config'
software = require './../software'
librato_metrics = require 'librato-metrics'
u = require './../utilities'