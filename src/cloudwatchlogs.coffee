cloudwatchlogs = exports

#Class for managing a log stream
cloudwatchlogs.LogStream = class LogStream
    constructor: (@environment, @groupname, @name) ->
        #See if the group exists and create it if it does not
        found = false
        response = @environment.CloudWatchLogs 'describeLogGroups', {logGroupNamePrefix: @groupname}
        for group in response.logGroups
            if group.logGroupName is @groupname
                found = true
                break

        if not found
            #create it...
            @environment.CloudWatchLogs 'createLogGroup', {logGroupName: @groupname}

        #Retrieve the uploadSequenceToken
        response = @environment.CloudWatchLogs 'describeLogStreams', {logGroupName: @groupname, logStreamNamePrefix: @name}
        for stream in response.logStreams ? []
            if stream.logStreamName is @name
                @uploadSequenceToken = stream.uploadSequenceToken
                break

        if not @uploadSequenceToken
            #Possibility 1: exists, but didn't show up in results
            if response.nextToken
                throw new Error 'Unable to list all the streams in ' + @groupname + ' ' + @name + ' on one page!  Pick a better stream naming convention'
            #Possibility 2: does not exist
            else
                @environment.CloudWatchLogs 'createLogStream', {logGroupName: @groupname, logStreamName: @name}


        @queue = []

    #logs a message to this stream
    log: (message) ->
        if not message
            return
        if String(message).trim() is ''
            return

        timestamp = Date.now()
        if message.length > 100000
            message = message[...100000] + '\n[Truncated: too big for CloudWatch]'

        @queue.push {timestamp, message}

        @ensure_put_scheduled()

    #ensure that we are going to upload events at some point
    ensure_put_scheduled: ->
        if @put_scheduled
            return
        @put_scheduled = true
        setTimeout @do_put.bind(this), 200

    #do an actual upload
    do_put: ->
        logEvents = @queue
        @queue = []

        @environment.get_svc('CloudWatchLogs').putLogEvents {
            logGroupName: @groupname
            logStreamName: @name
            sequenceToken: @uploadSequenceToken
            logEvents
        }, (err, res) =>
            if err
                u.report_no_log 'Error writing to cloud watch logs: ' + (err.stack ? err)
                console.log 'Error writing to cloud watch logs: ' + (err.stack ? err)
                return

            if res.rejectedLogEventsInfo?
                console.log 'Rejected logs: ' + JSON.stringify res.rejectedLogEventsInfo
                u.report_no_log 'Rejected logs: ' + JSON.stringify res.rejectedLogEventsInfo

            @uploadSequenceToken = res.nextSequenceToken

            #If more logs have come in in the interim, schedule another put,
            #otherwise indicate that we are no longer scheduled
            if @queue.length > 0
                setTimeout @do_put.bind(this), 200
            else
                @put_scheduled = false

    #Returns a url that a user can view to tail the logs
    get_tail_url: ->
        if not u.context()?.server
            throw new Error 'no server in this context'
        return u.context().server.get_logs_url @environment.id, @groupname, @name

    #Returns the most recent events
    get_events: (cb) ->
        response = @environment.CloudWatchLogs 'getLogEvents', {
            logGroupName: @groupname
            logStreamName: @name
        }
        return response.events ? []

    #Does the actual tail, given a web request
    tail: (req, res) ->
        options = url.parse(req.url, true).query

        nextToken = options.nextToken
        startFromHead = options.startFromHead is 'true'

        response = @environment.CloudWatchLogs 'getLogEvents', {
            logGroupName: @groupname
            logStreamName: @name
            nextToken
            startFromHead
        }

        #Generate the navigation links
        older = @get_tail_url() + '?nextToken=' + encodeURIComponent(response.nextBackwardToken) + '&startFromHead=' + String(startFromHead)
        newer = @get_tail_url() + '?nextToken=' + encodeURIComponent(response.nextForwardToken) + '&startFromHead=' + String(startFromHead)
        reverse = @get_tail_url() + '?startFromHead=' + String(not startFromHead)
        navigation = '<div class="navsection"><div class="navlink"><a href="' + older + '">Older events</a></div><div class="navlink"><a href="' + newer + '">Newer events</a></div><div class="navlink"><a href="' + reverse + '">Reverse order</a></div></navsection>'

        #Write the body
        res.write """
        <html><head><title>BubbleBot Log #{@environment.id}, #{@groupname},#{@name}</title>
        <style>
        pre.message {
            margin-top: 5px;
        }
        .timestamp {
            font-family: monospace;
            color: gray;
            margin-top: 20px;
        }
        .navsection {
            font-family: monospace;
            margin-bottom: 20px;
        }
        .navsection .navlink a {
            text-decoration: none;
            color: blue;
        }
        </style>
        </head>
        """
        res.write '<body>'
        res.write navigation

        response.events ?= []
        if not startFromHead
            response.events.reverse()

        if response.events.length > 0
            for {timestamp, message} in response.events
                res.write '<div class="log_entry"><div class="timestamp">' + u.print_date(new Date(timestamp)) + '</div><pre class="message">' + message + '</pre></div>'
            res.write navigation
        else
            res.write '<div class="log_entry">No more events</div>'

        res.write '</body></html>'
        res.end()



u = require './utilities'
bbobjects = require './bbobjects'
url = require 'url'