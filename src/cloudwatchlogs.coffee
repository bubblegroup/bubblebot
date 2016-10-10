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

        @queue = []

        @refresh_sequence_token()

    refresh_sequence_token: ->
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



    #logs a message to this stream
    log: (message) ->
        if not message
            return
        if String(message).trim() is ''
            return

        pieces = 0
        while message.length > 100000
            pieces++
            if pieces > 10
                @log 'Truncating: Too big for Cloudfront'
                return
            @log message[...100000]
            message = message[100000..]

        timestamp = Date.now()
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


    #Low-level helper for do_put: just writes the logs
    put_to_cloudwatch: (logEvents) ->
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


    #do an actual upload
    do_put: ->
        u.SyncRun 'cloudwatch_put', =>
            logEvents = @queue
            @queue = []

            try
                @put_to_cloudwatch logEvents

            catch err
                #recover from the token getting out of sequence
                if String(err).indexOf('InvalidSequenceTokenException') isnt -1
                    #Refresh the token
                    @refresh_sequence_token()

                    #And try again
                    @put_to_cloudwatch logEvents
                else
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

    #Returns the most recent events.  Sorted newest to oldest
    get_events: ->
        response = @environment.CloudWatchLogs 'getLogEvents', {
            logGroupName: @groupname
            logStreamName: @name
        }
        res = response.events ? []
        res.sort (a, b) -> (parseInt(a.timestamp) - parseInt(b.timestamp)) * -1
        return res

    #Does the actual tail, given a web request
    tail: (req, res) ->
        options = url.parse(req.url, true).query

        nextToken = options.nextToken
        startFromHead = options.startFromHead is 'true'

        if options.filterPattern
            params = {
                logGroupName: @groupname
                filterPattern: options.filterPattern
                interleaved: true
            }
            if nextToken
                params.nextToken = nextToken
            if options.all isnt 'yes'
                params.logStreamNames = [@name]
            response = @environment.CloudWatchLogs 'filterLogEvents', params
        else

            response = @environment.CloudWatchLogs 'getLogEvents', {
                logGroupName: @groupname
                logStreamName: @name
                nextToken
                startFromHead
            }

        #Generate the navigation links
        build_link = (startFromHead, nextToken) =>
            data = {}
            if startFromHead
                data.startFromHead = startFromHead
            if nextToken
                data.nextToken = nextToken
            @get_tail_url() + '?' + querystring.stringify(data)

        refresh = build_link startFromHead

        #If we are in filtering mode...
        if options.filterPattern
            if response.nextToken
                older = build_link false, response.nextToken

        else

            #Include an older link unless we are at the beginning of start from head
            if (not startFromHead) or nextToken
                older = build_link startFromHead, response.nextBackwardToken

            #Include a newer link unless we are the beginning of normal
            if startFromHead or nextToken
                newer = build_link startFromHead, response.nextForwardToken

        reverse = build_link (not startFromHead)

        link_html = (text, link) -> '\n<div class="navlink"><a href="' + link + '">' + text + '</a></div>\n'
        navigation = '\n<div class="navsection">\n'
        navigation += link_html 'Refresh', refresh
        if older
            navigation += link_html 'Older events', older
        if newer
            navigation += link_html 'Newer events', newer
        navigation += link_html (if startFromHead then 'Switch to newest first' else 'Switch to oldest first'), reverse

        if options.all is 'yes'
            all_checked = 'checked'
            this_checked = ''
        else
            all_checked = ''
            this_checked = 'checked'

        navigation += """
        <form id="searchform" action="" method="get">
        <input name="filterPattern" type="text" value="#{options.filterPattern ? ''}" placeholder="Search logs">
        <input type="radio" name="all" value="yes" #{all_checked}> All logs <input type="radio" name="all" value="no" #{this_checked}> This log
        </form>
        """
        navigation += '\n</div>\n'

        #Write the body
        res.write """
        <html>
        <head>
        <title>BubbleBot Log #{@environment.id}, #{@groupname},#{@name}</title>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <link rel="icon" type="image/png" href="https://d1muf25xaso8hp.cloudfront.net/http://s3.amazonaws.com/appforest_uf/f1412116867925x202730323653668160/apple_touch_icon_precomposed.png?w=124.80000000000001&h=&fit=max" />
        <style>
        #searchform {
            margin-top: 15px;
            margin-bottom: 35px;
        }
        pre.message {
            margin-top: 5px;
            white-space: pre-line;
            width: 100%;
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
        res.write '\n<body>'
        res.write navigation

        response.events ?= []
        response.events.sort (a, b) -> (parseInt(a.timestamp) - parseInt(b.timestamp)) * (if startFromHead then 1 else -1)

        if response.events.length > 0
            for {timestamp, message, logStreamName} in response.events
                #If this is a search across multiple logs, include a link to the source log
                if options.all is 'yes' and options.filterPattern
                    log_link = ' <a href="' + (new LogStream @environment, @groupname, logStreamName).get_tail_url() + '">' + logStreamName + '</a>'
                else
                    log_link = ''

                res.write '\n<div class="log_entry"><div class="timestamp">' + u.print_date(new Date(timestamp)) + log_link + '</div><pre class="message">' + escape_html(message) + '</pre></div>'
            res.write navigation
        else
            res.write '\n<div class="log_entry">No more events</div>'

        res.write '\n</body></html>'
        res.end()



u = require './utilities'
bbobjects = require './bbobjects'
url = require 'url'
querystring = require 'querystring'
escape_html = require 'escape-html'