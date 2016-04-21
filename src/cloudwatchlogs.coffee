cloudwatchlogs = exports

#Class for managing a log stream
cloudwatchlogs.LogStream = class LogStream
    constructor: (@environment, @groupname, @name) ->
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
    get_tail_url: -> throw new Error 'not implemented'


u = require './utilities'