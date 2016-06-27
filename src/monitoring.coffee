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
        @_is_scheduled = {}

        @start_time = Date.now()

    _get_uid: (object) -> object.type + '_' + object.id

    monitor: (object) ->
        if not object
            return
        policy = object.get_monitoring_policy()

        uid = @_get_uid object
        if @to_monitor[uid]
            return
        u.log 'Monitor: monitoring ' + object + ' (' + uid + ')'
        @to_monitor[uid] = object

        #Set the initial frequency
        @frequencies[uid] = policy.frequency ? 30 * 1000
        @health[uid] = UNKNOWN

        #and schedule the initial check
        @schedule object

    #Schedules the next monitoring run for this object
    schedule: (object) ->
        uid = @_get_uid object
        if @_is_scheduled[uid]
            return
        @_is_scheduled[uid] = true
        setTimeout @check.bind(this, object), @frequencies[uid]

    #Performs a check on this object
    check: (object) ->
        u.SyncRun 'monitor_check', =>
            try
                @do_check object
            catch err
                u.report 'Bug in monitoring:\n' + err.stack

            #We always want to continue monitoring
            finally
                @_is_scheduled[uid] = false
                @schedule object

    #The inner body of check (we break it out because this is performance critical)
    do_check: (object) ->
        uid = @_get_uid object

        u.cpu_checkpoint 'monitor_check.' + uid + '.build_context'

        @server.build_context()

        u.cpu_checkpoint 'monitor_check.' + uid + '.generate_metadata'

        policy = object.get_monitoring_policy()
        if policy.monitor is false
            return

        #update the frequency in case it changed
        @frequencies[uid] = policy.frequency

        #If we have any upstream dependencies, make sure we are monitoring them
        for dependency in policy.dependencies ? []
            @monitor dependency

        u.cpu_checkpoint 'monitor_check.' + uid + '.check_state'

        #Check its current state and reason
        [state, reason] = @get_state(object)

        u.cpu_checkpoint 'monitor_check.' + uid + '.handle_state'

        #If it is unhealthy, start tracking downtime...
        if state is UNHEALTHY
            u.log 'Monitor: detected unhealthy state for ' + uid
            @health[uid] = state
            down = Date.now()

            #Track which services we've notified
            services = {}

            #Loop while we are still unhealthy
            while state is UNHEALTHY
                downtime = Date.now() - down

                for service, threshold of policy.thresholds ? {}
                    #If we haven't reported to this service yet and are over the threshold...
                    if threshold? and not services[service] and downtime > threshold
                        #If there's a limit on how frequently we can report to this service,
                        #make sure we are within the limit
                        if policy.limits?[service] and @last_service_times[uid]?[service]
                            within_limit = (Date.now() - @last_service_times[uid][service]) > policy.limits[service]
                        else
                            within_limit = true

                        if within_limit
                            services[service] = true
                            try
                                @report_down service, object, downtime, reason
                            catch err
                                u.report 'Bug in monitoring reporting down to ' + service + ':\n' + err.stack

                #Wait for a second before checking again
                u.pause 1000
                [state, reason] = @get_state(object)

            u.log 'Monitor: no longer in unhealthy state for ' + uid

            #We are no longer unhealthy, so update our total downtime, and inform services.
            downtime = Date.now() - down

            @downtime[uid] ?= 0
            @downtime[uid] += downtime

            for service, _ of services
                try
                    @report_up service, object, downtime
                catch err
                    u.report 'Bug in monitoring reporting up to ' + service + ':\n' + err.stack

        #We are now in some non-UNHEALTHY state.  Update our state...
        @health[uid] = state

    #Given an object, returns HEALTHY / UNHEALTHY / MAINTENANCE
    get_state: (object) ->
        #first, see if the object thinks it is in maintenance mode
        if object.maintenance()
            return [MAINTENANCE, 'self-report']

        #Then, see if any of its dependencies are unhealthy / unknown / in maintenance.
        #
        #If so, we consider this in maintenance mode
        if @unhealthy_dependencies(object)
            return [MAINTENANCE, 'dependency is down']

        #Then try to hit it
        [up, reason] = @hit_endpoint object
        if up
            return [HEALTHY]
        else
            return [UNHEALTHY, reason]


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

    report_down: (service, object, downtime, reason) ->
        #Record that we've reported down to this service
        uid = @_get_uid(object)
        @last_service_times[uid] ?= {}
        @last_service_times[uid][service] = Date.now()

        if service is 'announce'
            u.announce 'Monitoring: ' + object + ' has been down for ' + u.format_time(downtime) + ':\n' + reason
        else if service is 'report'
            u.report 'Monitoring: ' + object + ' has been down for ' + u.format_time(downtime) + ':\n' + reason
        else if service is 'restart'
            u.SyncRun 'monitor_restart', =>
                @server.build_context 'monitoring: restarting ' + object
                object.restart()
        else if service is 'replace'
            u.report 'Monitoring: automatically replacing ' + object
            u.announce 'Monitoring: automatically replacing ' + object
            u.SyncRun 'monitor_replace', =>
                @server.build_context 'monitoring: replacing ' + object
                object.replace()
        else
            plugin = @get_alerting_plugin(service)
            if plugin
                plugin.report_down object, downtime, reason
            else
                u.report 'Monitoring: unrecognized reporting service ' + service


    report_up: (service, object, downtime) ->
        if service is 'announce'
            u.announce 'Monitoring: ' + object + ' is back up.  It was down for ' + u.format_time(downtime)
        else if service is 'report'
            u.report 'Monitoring: ' + object + ' is back up.  It was down for ' + u.format_time(downtime)
        else if service is 'restart'
            true
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
            if @health[uid] is HEALTHY
                uptime = (total_time - (@downtime[uid] ? 0)) / total_time
                res.push String(object) + ': ' + @health[uid] + ' (' + u.format_percent(uptime) + ')'
            else
                res.push String(object) + ': ' + @health[uid]

        return res.join '\n'

    #Returns a description of the monitoring policies of all monitored objects
    policies: ->
        res = []

        for uid, object of @to_monitor
            policy = object.get_monitoring_policy()
            if policy.monitor is false
                continue
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


    #Tries to access the server, returns [up, reason] where up is a boolean inicating
    #if the server is accessible, and reason is a string giving more info on why it's not up
    hit_endpoint: (object) ->
        policy = object.get_monitoring_policy()
        if policy.monitor is false
            return [false, 'monitoring policy no longer exists']
        protocol = policy.endpoint.protocol
        retries = policy.endpoint.retries ? 2
        timeout = policy.endpoint.timeout ? 10000

        while retries > 0

            if protocol in ['http', 'https']
                if policy.endpoint.user and policy.endpoint.password
                    login = policy.endpoint.user + ':' + policy.endpoint.password + '@'
                else
                    login = ''

                path = policy.endpoint.path ? ''

                #clean url has the login hidden, for reporting purposes
                clean_url = protocol + '://' + policy.endpoint.host + path
                url = protocol + '://' + login + policy.endpoint.host + path

                expected_status = policy.endpoint.expected_status ? 200
                expected_body = policy.endpoint.expected_body ? null

                start = Date.now()
                block = u.Block clean_url
                request url, block.make_cb()
                timed_out = setTimeout ->
                    block.fail 'timed out after ' + timeout
                , timeout
                try
                    res = block.wait()
                    latency = Date.now() - start
                    clearTimeout timed_out

                    if res.statusCode isnt expected_status or expected_body and res.body.indexOf(expected_body) is -1
                        result = false
                        reason = 'Could not hit ' + clean_url + ': ' + res.statusCode + ' ' + res.body
                    else
                        result = true
                catch err
                    result = false
                    reason = 'Could not hit ' + clean_url + ': ' + err.message

            else if protocol is 'postgres'
                db = new databases.Postgres object
                try
                    start = Date.now()
                    db.query 'select 1'
                    latency = Date.now() - start
                    result = true
                    reason = null
                catch err
                    result = false
                    reason = err.stack

            else
                throw new Error 'monitoring: unrecognized protocol ' + protocol

            #Report the latency to metrics
            if result
                for plugin in config.get_plugins('metrics')
                    if typeof(plugin.measure) is 'function'
                        plugin.measure object.type + '_' + object.id, 'bubblebot_monitor_latency', latency

            if result
                return [result, reason]
            else
                retries--

        return [result, reason]


u = require './utilities'
config = require './config'
request = require 'request'
databases = require './databases'