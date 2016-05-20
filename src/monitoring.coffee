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

        @start_time = Date.now()

    _get_uid: (object) -> object.type + '_' + object.id

    monitor: (object) ->
        uid = @_get_uid object
        if @to_monitor[uid]
            return
        u.log 'Monitor: monitoring ' + object + ' (' + uid + ')'
        @to_monitor[uid] = object

        #Set the initial frequency
        @frequencies[uid] =  object.get_monitoring_policy().frequency
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

                #if we are in maintenance mode, skip
                if object.maintenance()
                    @health[uid] = MAINTENANCE
                    return

                #If we have any upstream dependencies, make sure we are monitoring them
                for dependency in policy.upstream ? []
                    @monitor dependency

                #Mark its health unknown
                @health[uid] = UNKNOWN

                #See if it is up
                if @hit_endpoint policy
                    @health[uid] = HEALTHY
                    return

                #Make sure all the dependencies are up... if any are down, we don't
                #want to alert on this
                while @unhealthy_dependencies(object)
                    u.pause 2000

                #See if it recovered
                if @hit_endpoint policy
                    @health[uid] = HEALTHY
                    return

                #We are now officially unhealthy
                @health[uid] = UNHEALTHY
                down = Date.now()

                #Track which services we've notified
                services = {}

                #Loop til we are healthy (or in maintenance)
                while not @hit_endpoint and not object.maintenance()
                    downtime = Date.now() - down

                    for service, threshold of policy.thresholds ? {}
                        if not services[service] and downtime > threshold
                            services[service] = true
                            @report_down service, object, downtime

                    #Wait for a second before checking again
                    u.pause 1000

                #We are healthy again.  Update our total downtime, and inform services.
                downtime = Date.now() - down
                @health[uid] = HEALTHY

                @downtime[uid] ?= 0
                @downtime[uid] += downtime

                for service, _ of services
                    @report_up service, object, downtime


            #We always want to continue monitoring
            finally
                @schedule object

    #Returns true if we have any dependencies who don't have a confirmed health
    unhealthy_dependencies: (object) ->
        for dep in object.get_monitorin_policy().dependencies ? []
            if @health[@_get_uid(dep)] isnt HEALTHY
                return true

        return false

    report_down: (service, object, downtime) ->
        if service is 'announce'
            u.announce 'Monitoring: ' + object + ' has been down for ' + u.format_time(downtime)
        else if service is 'report'
            u.report 'Monitoring: ' + object + ' has been down for ' + u.format_time(downtime)
        else if service is 'replace'
            u.report 'Monitoring: automatically replacing ' + object
            u.announce 'Monitoring: automatically replacing ' + object
            object.replace()
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
            res.push '  Frequency: ' + policy.frequency
            res.push '  Upstream: ' + (String(dep) for dep in policy.upstream ? []).join(', ')
            for service, threshold in policy.thresholds ? {}
                res.push '  ' + service + ': ' + threshold + ' ms'

        return res.join '\n'


    #Tries to access the server, returns true if it is up, false if not
    hit_endpoint: (policy) -> throw new Error 'not yet impleemented'
