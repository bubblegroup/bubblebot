cloudwatchlogs = exports

not_flushed = {}


#Waits until all logs are flushed
cloudwatchlogs.wait_for_flushed = ->
    while (k for k, nf of not_flushed when nf).length > 0
        u.pause 500

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
        @not_flushed()
        setTimeout @do_put.bind(this), 200

    #Indicates that we have unflushed logs
    not_flushed: ->
        key = String(@environment) + '_' + @groupname + '_' + @name
        not_flushed[key] = true

    #Indicates that all our logs are flushed
    flushed: ->
        key = String(@environment) + '_' + @groupname + '_' + @name
        not_flushed[key] = false

    #do an actual upload
    do_put: ->
        u.SyncRun 'cloudwatch_put', =>
            logEvents = @queue
            @queue = []

            try
                res = @environment.CloudWatchLogs 'putLogEvents', {
                    logGroupName: @groupname
                    logStreamName: @name
                    sequenceToken: @uploadSequenceToken
                    logEvents
                }
                if res.rejectedLogEventsInfo?
                    console.log 'Rejected logs: ' + JSON.stringify res.rejectedLogEventsInfo
                    u.report_no_log 'Rejected logs: ' + JSON.stringify res.rejectedLogEventsInfo

                @uploadSequenceToken = res.nextSequenceToken


            catch err
                u.report_no_log 'Error writing to cloud watch logs: ' + (err.stack ? err)
                console.log 'Error writing to cloud watch logs: ' + (err.stack ? err)


            #If more logs have come in in the interim, schedule another put,
            #otherwise indicate that we are no longer scheduled
            if @queue.length > 0
                setTimeout @do_put.bind(this), 200
            else
                @put_scheduled = false
                @flushed()



    #Returns a url that a user can view to tail the logs
    get_tail_url: ->
        if not u.context()?.server
            throw new Error 'no server in this context'
        return u.context().server.get_logs_url @environment.id, @groupname, @name

    #Returns the most recent events
    get_events: ->
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
        build_link = (startFromHead, nextToken) => @get_tail_url() ? '?' + querystring.stringify({startFromHead, nextToken})

        refresh = build_link startFromHead

        #Include an older link unless we are at the beginning of start from head
        if (not startFromHead) or nextToken
            older = build_link startFromHead, response.nextBackwardToken

        #Include a newer link unless we are the beginning of normal
        if startFromHead or nextToken
            newer = build_link startFromHead, response.nextForwardToken

        reverse = build_link (not startFromHead)

        link_html = (text, link) -> '<div class="navlink"><a href="' + link + '">' + text + '</a></div>\n'
        navigation = '<div class="navsection">\n'
        navigation += link_html 'Refresh', refresh
        if older
            navigation += link_html 'Older events', older
        if newer
            navigation += link_html 'Newer events', newer
        navigation += link_html 'Reverse order', reverse
        navigation += '</div>'

        #Write the body
        res.write """
        <html><head><title>BubbleBot Log #{@environment.id}, #{@groupname},#{@name}</title>
        <style>
        pre.message {
            margin-top: 5px;
        }
        .timestamp {
            font-family: monospace;
            color: #03A9F4;
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
        response.events.sort (a, b) -> (parseInt(a.timestamp) - parseInt(b.timestamp)) * (if startFromHead then 1 else -1)

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
querystring = require 'querystring'