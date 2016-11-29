monitoring = exports

#status
HEALTHY = 'healthy'
UNKNOWN = 'unknown'
UNHEALTHY = 'unhealthy'
MAINTENANCE = 'maintenance'
NOT_MONITORING = 'not monitoring'

total_checks = 0

#Monitoring and alerting provider
monitoring.Monitor = class Monitor
    constructor: (@server) ->
        @to_monitor = {}
        @policies = {}

        @in_maintenance = {}

        @health = {}
        @downtime = {}
        @last_action_times = {}
        @_is_scheduled = {}

        @start_time = Date.now()

        @schedule_update_policies()

    _get_uid: (object) -> object.type + '_' + object.id

    schedule_update_policies: ->
        if @_update_scheduled
            return
        @_update_scheduled = true

        setTimeout =>
            @_update_scheduled = false
            u.SyncRun 'update_policies', =>
                @server.build_context()

                @update_policies()

                @schedule_update_policies()

        , 60000

    #Goes through everything we are monitoring, and updates policies
    update_policies: ->
        for uid, object of @to_monitor
            try
                @update_policy uid, object
            catch err
                u.report 'Bug updating policy for ' + object + ':\n' + err.stack

    #Update our cached policy / maintenance state for the given object and uid
    update_policy: (uid, object) ->
        @policies[uid] = object.get_monitoring_policy()
        if @policies[uid].monitor isnt false
            @in_maintenance[uid] = object.maintenance()

    monitor: (object) ->
        if not object
            return
        uid = @_get_uid object

        if @to_monitor[uid]
            return
        @to_monitor[uid] = object

        u.log 'Monitor: monitoring ' + object + ' (' + uid + ')'

        #Set the initial policy
        @update_policy uid, object
        @health[uid] = UNKNOWN

        #and schedule the initial check
        @schedule object

    #Schedules the next monitoring run for this object
    schedule: (object) ->
        uid = @_get_uid object
        if @_is_scheduled[uid]
            return
        @_is_scheduled[uid] = true
        setTimeout @check.bind(this, object), @policies[uid]?.frequency ? 30 * 1000

    #Performs a check on this object
    check: (object) ->
        u.SyncRun 'monitor_check', =>
            total_checks++
            try
                uid = @_get_uid object
                @do_check uid, object
            catch err
                u.report 'Bug in monitoring:\n' + err.stack

            #We always want to continue monitoring
            finally
                @_is_scheduled[uid] = false
                @schedule object

    #The inner body of check (we break it out because this is performance critical)
    do_check: (uid, object) ->
        @server.build_context()

        policy = @policies[uid]
        if policy.monitor is false
            @health[uid] = NOT_MONITORING
            return

        #Check its current state and reason
        [state, reason] = @get_state(uid, object, policy)

        #If it is unhealthy, start tracking downtime...
        if state is UNHEALTHY
            u.log 'Monitor: detected unhealthy state for ' + uid
            @health[uid] = state
            down = Date.now()

            #Track which actions we've notified
            actions = {}

            #Loop while we are still unhealthy
            while state is UNHEALTHY
                downtime = Date.now() - down

                for action_name, action of policy.actions ? {}
                    #If we haven't reported to this action yet and are over the threshold...
                    if action.threshold? and not actions[action_name] and downtime > action.threshold
                        #If there's a limit on how frequently we can report to this action,
                        #make sure we are within the limit
                        if action.limit? and @last_action_times[uid]?[action_name]
                            within_limit = (Date.now() - @last_action_times[uid][action_name]) > action.limit
                        else
                            within_limit = true

                        if within_limit
                            actions[action_name] = true
                            try
                                @report_down action_name, action, object, downtime, reason
                            catch err
                                u.report 'Bug in monitoring reporting down to ' + action_name + ':\n' + err.stack

                #Wait for a second before checking again
                u.pause 1000

                #make sure the policy is up to date...
                @update_policy uid, object
                policy = @policies[uid]

                #and check again
                [state, reason] = @get_state(uid, object, policy)

            u.log 'Monitor: no longer in unhealthy state for ' + uid

            #We are no longer unhealthy, so update our total downtime, and inform any actions.
            downtime = Date.now() - down

            @downtime[uid] ?= 0
            @downtime[uid] += downtime

            for action_name, _ of actions
                try
                    @report_up action_name, action, object, downtime
                catch err
                    u.report 'Bug in monitoring reporting up to ' + action_name + ':\n' + err.stack

        #We are now in some non-UNHEALTHY state.  Update our state...
        @health[uid] = state

    #Given an object, returns HEALTHY / UNHEALTHY / MAINTENANCE
    get_state: (uid, object, policy) ->
        #If we've turned of monitoring, that is our state
        if policy.monitor is false
            return [NOT_MONITORING]

        #first, see if the object thinks it is in maintenance mode
        if @in_maintenance[uid]
            return [MAINTENANCE, 'self-report']

        #Then, see if any of its dependencies are unhealthy / unknown / in maintenance.
        #
        #If so, we consider this in maintenance mode
        if policy.dependencies?.length and @unhealthy_dependencies(policy)
            return [MAINTENANCE, 'dependency is down']

        #Then try to hit it
        [up, reason] = @hit_endpoint object, policy
        if up
            return [HEALTHY]
        else
            return [UNHEALTHY, reason]


    #Returns true if we have any dependencies who don't have a confirmed health
    unhealthy_dependencies: (policy) ->
        for dep in policy.dependencies
            dep_uid = @_get_uid(dep)
            if @health[dep_uid] not in [HEALTHY, NOT_MONITORING]
                #make sure we are monitoring...
                if not @health[dep_uid]
                    @monitor dep
                return true

        #If we have any upstream dependencies, make sure we are monitoring them
        for dependency in policy.dependencies ? []
            @monitor dependency

        return false

    get_alerting_plugin: (plugin_name) ->
        for plugin in config.get_plugins('alerting')
            if plugin.name() is plugin_name
                return plugin

    report_down: (action_name, action, object, downtime, reason) ->
        #Record that we've reported down for this action
        uid = @_get_uid(object)
        @last_action_times[uid] ?= {}
        @last_action_times[uid][action_name] = Date.now()

        #Log / announce that we are calling this, if appropriate
        msg = 'Monitoring: calling ' + action_name + ' on ' + object
        if action.report
            u.report msg
        if action.announce
            u.announce msg
        u.log msg

        #Perform the action
        switch action.action
            when 'announce'
                u.announce 'Monitoring: ' + object + ' has been down for ' + u.format_time(downtime) + ':\n' + reason

            when 'report'
                u.report 'Monitoring: ' + object + ' has been down for ' + u.format_time(downtime) + ':\n' + reason

            when 'method'
                params = action.params ? []
                method = action.method
                if not object[method]
                    u.report 'Monitoring: method call failed, could not find ' + method + ' on ' + object
                    return

                @server.run_fiber msg, =>
                    object[method] params...

            when 'plugin'
                plugin = @get_alerting_plugin(action.plugin)
                if plugin
                    plugin.report_down object, downtime, reason
                else
                    u.report 'Monitoring: unrecognized reporting plugin ' + action.plugin


    report_up: (action_name, action, object, downtime) ->
        switch action.action
            when 'announce'
                u.announce 'Monitoring: ' + object + ' is back up.  It was down for ' + u.format_time(downtime)
            when 'report'
                u.report 'Monitoring: ' + object + ' is back up.  It was down for ' + u.format_time(downtime)
            when 'method'
                true #no-op for now, though we could let the user specify an up message
            when 'plugin'
                plugin = @get_alerting_plugin(action.plugin)
                if plugin
                    plugin.report_up object, downtime
                else
                    u.report 'Monitoring: unrecognized reporting plugin ' + action.plugin

    #Returns a description of the current status of all monitored objects
    statuses: ->
        res = []
        total_time = Date.now() - @start_time
        res.push 'Bubblebot has been up for ' + u.format_time(total_time)
        res.push ''

        healthy = []
        other = []

        for uid, object of @to_monitor
            if @health[uid] is HEALTHY
                uptime = (total_time - (@downtime[uid] ? 0)) / total_time
                healthy.push String(object) + ': ' + @health[uid] + ' (' + u.format_percent(uptime) + ')'
            else
                other.push String(object) + ': ' + @health[uid]

        #First show unhealthy, then healthy
        res.push other...
        res.push healthy...

        res.push '\n\nChecks per second: ' + u.format_decimal(total_checks / (total_time / 1000))

        return res.join '\n'

    #Returns a description of the monitoring policies of all monitored objects
    get_policies: ->
        res = []

        for uid, object of @to_monitor
            policy = @policies[uid]
            if policy.monitor is false
                continue
            res.push ''
            res.push String(object) + ':'
            res.push '  Frequency: ' + u.format_time(policy.frequency)
            res.push '  Upstream: ' + (String(dep) for dep in policy.dependencies ? []).join(', ')
            res.push bbserver.pretty_print(policy.actions)

        return res.join '\n'


    #Tries to access the server, returns [up, reason] where up is a boolean inicating
    #if the server is accessible, and reason is a string giving more info on why it's not up
    hit_endpoint: (object, policy) ->
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
                    setTimeout ->
                        block.fail 'timed out after ' + timeout
                    , 1000 #In case bubblebot CPU is overwhelmed
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
                    block = u.Block 'monitor hitting pg'
                    pg_hit_timeout = setTimeout ->
                        setTimeout ->
                            block.fail 'timed out after 6 seconds'
                        , 1000
                    , 5000
                    u.sub_fiber ->
                        start = Date.now()
                        db.query 'select 1'
                        block.success Date.now() - start

                    latency = block.wait()
                    result = true
                    reason = null
                catch err
                    result = false
                    reason = err.stack
                clearTimeout pg_hit_timeout

            else if protocol is 'redis'
                try
                    block = u.Block 'connecting'

                    redis_hit_timeout = setTimeout ->
                        setTimeout ->
                            block.fail 'timed out after 5 seconds'
                        , 1000 #in case bubblebot cpu is overwhelmed
                    , 5000

                    client = redis.createClient 'redis://' + policy.endpoint.host
                    client.on 'error', (err) -> block.fail err

                    start = Date.now()
                    client.get 'x', (err, reply) ->
                        if err
                            block.fail err
                        else
                            block.success Date.now() - start

                    latency = block.wait()
                    result = true
                    reason = null
                catch err
                    result = false
                    reason = err.stack
                finally
                    try
                        client?.quit()
                    catch e
                        u.log 'Error quitting redis client:\n' + e.stack
                clearTimeout redis_hit_timeout


            else if protocol is 'custom'
                start = Date.now()
                try
                    policy.endpoint.custom_fn policy.endpoint
                    result = true
                catch err
                    result = false
                    reason = err.stack ? err.message
                latency = Date.now() - start

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
bbserver = require './bbserver'
redis = require 'redis'