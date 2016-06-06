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
            if response.nextToken
                throw new Error 'Unable to list all the streams in ' + @groupname + ' ' + @name + ' on one page!  Pick a better stream naming convention'

        @queue = []

    #logs a message to this stream
    log: (message) ->
        timestamp = Date.now()
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
                u.get_logger().report_no_log 'Error writing to cloud watch logs: ' + (err.stack ? err)
                return

            if res.rejectedLogEventsInfo?
                u.get_logger().report_no_log 'Rejected logs: ' + JSON.stringify res.rejectedLogEventsInfo

            @uploadSequenceToken = res.nextSequenceToken

            #If more logs have come in in the interim, schedule another put,
            #otherwise indicate that we are no longer scheduled
            if @queue.length > 0
                setTimeout @do_put.bind(this), 200
            else
                @put_scheduled = false

    #Returns a url that a user can view to tail the logs
    get_tail_url: -> bbobjects.get_bbserver().get_logs_url @environment.id, @groupname, @name

    #Returns the most recent events
    get_events: (cb) ->
        @environment.get_svc('CloudWatchLogs').getLogEvents {
            logGroupName: @groupname
            logStreamName: @name
        }, (err, response) =>
            if err
                cb err
            else
                cb null, response.events ? []

    #Does the actual tail, given a web request
    tail: (req, res) ->
        options = url.parse(req.url, true).query

        nextToken = options.nextToken
        startFromHead = options.startFromHead is 'true'

        @environment.get_svc('CloudWatchLogs').getLogEvents {
            logGroupName: @groupname
            logStreamName: @name
            nextToken
            startFromHead
        }, (err, response) =>
            if err
                res.statusCode = 500
                res.write 'Error loading data from Cloudwatch'
                res.end()
                u.report 'Error loading data from Cloudwatch: ' + (err.stack ? err)
                return

            #Generate the navigation links
            older = @get_tail_url() + '?nextToken=' + response.nextBackwardToken + '&startFromHead=' + String(startFromHead)
            newer = @get_tail_url() + '?nextToken=' + response.nextForwardToken + '&startFromHead=' + String(startFromHead)
            reverse = @get_tail_url() + '?startFromHead=' + String(not startFromHead)
            navigation = '<p><a href="' + older + '">Older events</a></p><p><a href="' + newer + '">Newer events</a></p><p><a href="' + reverse + '">Reverse order</a></p>'

            #Write the body
            res.write '<html><head><title>BubbleBot Log ' + @environment.id + ', ' + @groupname + ', ' + @name + '</title></head>'
            res.write '<body>'
            res.write navigation

            for {timestamp, message} in response.events ? []
                res.write '<p><span>' + String(new Date(timestamp)) + ': </span><span>' + message + '</span></p>'

            res.write navigation
            res.write '</body></html>'
            res.end()



u = require './utilities'
bbobjects = require './bbobjects'
url = require 'url'