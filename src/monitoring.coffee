monitoring = exports

#status
HEALTHY = 'healthy'
UNKNOWN = 'unknown'
UNHEALTHY = 'unhealthy'
MAINTENANCE = 'maintenance'

#Monitoring and alerting provider
monitoring.Monitor = class Monitor
    constructor: (@server) ->
        @to_monitor = {}
        @frequencies = {}
        @health = {}
        @downtime = {}
        @last_service_times = {}

        @start_time = Date.now()

    _get_uid: (object) -> object.type + '_' + object.id

    monitor: (object) ->
        policy = object.get_monitoring_policy()
        if policy.monitor is false
            return

        uid = @_get_uid object
        if @to_monitor[uid]
            return
        u.log 'Monitor: monitoring ' + object + ' (' + uid + ')'
        @to_monitor[uid] = object

        #Set the initial frequency
        @frequencies[uid] =  policy.frequency
        @health[uid] = UNKNOWN

        #and schedule the initial check
        @schedule object

    #Schedules the next monitoring run for this object
    schedule: (object) ->
        uid = @_get_uid object
        setTimeout @check.bind(this, object), @frequencies[uid]

    #Performs a check on this object
    check: (object) ->
        u.SyncRun =>
            try
                uid = @_get_uid object

                @server.build_context()

                policy = object.get_monitoring_policy()

                #update the frequency in case it changed
                @frequencies[uid] = policy.frequency

                #If we have any upstream dependencies, make sure we are monitoring them
                for dependency in policy.dependencies ? []
                    @monitor dependency

                #Mark its health unknown until we get a positive confirmation on its state
                @health[uid] = UNKNOWN

                #Check its current state
                state = @get_state(object)

                #If it is unhealthy, start tracking downtime...
                if state is UNHEALTHY
                    @health[uid] = state
                    down = Date.now()

                    #Track which services we've notified
                    services = {}

                    #Loop while we are still unhealthy
                    while state is UNHEALTHY
                        downtime = Date.now() - down

                        for service, threshold of policy.thresholds ? {}
                            #If we haven't reported to this service yet and are over the threshold...
                            if not services[service] and downtime > threshold
                                #If there's a limit on how frequently we can report to this service,
                                #make sure we are within the limit
                                if policy.limits?[service] and @last_service_times[uid]?[service]
                                    within_limit = (Date.now() - @last_service_times[uid][service]) > policy.limits[service]
                                else
                                    within_limit = true

                                if within_limit
                                    services[service] = true
                                    @report_down service, object, downtime

                        #Wait for a second before checking again
                        u.pause 1000
                        state = @get_state(object)

                    #We are no longer unhealthy, so update our total downtime, and inform services.
                    downtime = Date.now() - down

                    @downtime[uid] ?= 0
                    @downtime[uid] += downtime

                    for service, _ of services
                        @report_up service, object, downtime

                #We are now in some non-UNHEALTHY state.  Update our state...
                @health[uid] = state

            #We always want to continue monitoring
            finally
                @schedule object

    #Given an object, returns HEALTHY / UNHEALTHY / MAINTENANCE
    get_state: (object) ->
        #first, see if the object thinks it is in maintenance mode
        if object.maintenance()
            return MAINTENANCE

        #Then, see if any of its dependencies are unhealthy / unknown / in maintenance.
        #
        #If so, we consider this in maintenance mode
        if @unhealthy_dependencies(object)
            return MAINTENANCE

        #Then try to hit it
        if @hit_endpoint object
            return HEALTHY
        else
            return UNHEALTHY


    #Returns true if we have any dependencies who don't have a confirmed health
    unhealthy_dependencies: (object) ->
        for dep in object.get_monitoring_policy().dependencies ? []
            if @health[@_get_uid(dep)] isnt HEALTHY
                return true

        return false

    get_alerting_plugin: (service) ->
        for plugin in config.get_plugins('alerting')
            if plugin.name() is service
                return plugin

    report_down: (service, object, downtime) ->
        #Record that we've reported down to this service
        uid = @_get_uid(object)
        @last_service_times[uid] ?= {}
        @last_service_times[uid][service] = Date.now()

        if service is 'announce'
            u.announce 'Monitoring: ' + object + ' has been down for ' + u.format_time(downtime)
        else if service is 'report'
            u.report 'Monitoring: ' + object + ' has been down for ' + u.format_time(downtime)
        else if service is 'replace'
            u.report 'Monitoring: automatically replacing ' + object
            u.announce 'Monitoring: automatically replacing ' + object
            object.replace()
        else
            plugin = @get_alerting_plugin(service)
            if plugin
                plugin.report_down object, downtime
            else
                u.report 'Monitoring: unrecognized reporting service ' + service


    report_up: (service, object, downtime) ->
        if service is 'announce'
            u.announce 'Monitoring: ' + object + ' is back up.  It was down for ' + u.format_time(downtime)
        else if service is 'report'
            u.report 'Monitoring: ' + object + ' is back up.  It was down for ' + u.format_time(downtime)
        else if service is 'replace'
            true #no op
        else
            plugin = @get_alerting_plugin(service)
            if plugin
                plugin.report_up object, downtime
            else
                u.report 'Monitoring: unrecognized reporting service ' + service

    #Returns a description of the current status of all monitored objects
    statuses: ->
        res = []
        total_time = Date.now() - @start_time
        res.push 'Bubblebot has been up for ' + u.format_time(total_time)
        res.push ''
        for uid, object of @to_monitor
            uptime = (total_time - (@downtime[uid] ? 0)) / total_time
            res.push String(object) + ': ' + @health[uid] + ' (' + u.format_percent(uptime) + ')'

        return res.join '\n'

    #Returns a description of the monitoring policies of all monitored objects
    policies: ->
        res = []

        for uid, object of @to_monitor
            policy = object.get_monitoring_policy()
            res.push ''
            res.push String(object) + ':'
            res.push '  Frequency: ' + u.format_time(policy.frequency)
            res.push '  Upstream: ' + (String(dep) for dep in policy.dependencies ? []).join(', ')
            for service, threshold in policy.thresholds ? {}
                if policy.limits?[service]
                    limit_text = '  (limit every ' + u.format_time(policy.limits[service]) + ')'
                else
                    limit_text = ''
                res.push '  ' + service + ': ' + threshold + ' ms' + limit_text

        return res.join '\n'


    #Tries to access the server, returns true if it is up, false if not
    hit_endpoint: (object) ->
        policy = object.get_monitoring_policy()
        endpoint = object.endpoint()
        protocol = policy.endpoint.protocol

        if protocol in ['http', 'https']
            url = protocol + '://' + endpoint

            start = Date.now()
            block = u.Block url
            request url, block.make_cb()
            try
                res = block.wait()
                latency = Date.now() - start

                result = 200 <= res.statusCode <= 299
            catch err
                result = false

        else if protocol is 'postgres'
            db = databases.Postgres object
            try
                start = Date.now()
                db.query 'select 1'
                latency = block.wait()
                result = true
            catch err
                result = false

        else
            throw new Error 'monitoring: unrecognized protocol ' + protocol

        #Report the latency to metrics
        if result
            for plugin in config.get_plugins('metrics')
                if typeof(plugin.measure) is 'function'
                    plugin.measure object.type + '_' + object.id, 'bubblebot_monitor_latency', latency

        return result


u = require './utilities'
config = require './config'
request = require 'request'