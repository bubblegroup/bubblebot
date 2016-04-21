slack = exports
events = require 'events'

slack.SlackClient = class SlackClient extends events.EventEmitter
    constructor: ->
        @api = new RtmClient config.get('slack_token')
        @api.start()

        ready = u.Block 'slack api initializing'

        _opened = false

        @api.on 'message', @handle_message.bind(this)

        @api.on 'open', ->
            _opened = true
            ready.success()

        @api.on 'error', (err) =>
            #if we haven't opened yet, shut down the server
            if not _opened
                msg = 'ERROR CONNECTING TO SLACK: ' + (err.stack ? err)
                @shutdown msg

            #Otherwise, this is just an uncaught exception
            else
                throw err

        @api.on 'disconnect', =>
            @shutdown 'SLACK CLIENT DISCONNECTED.  SHUTTING DOWN THE SERVER IN 30 SECONDS...'

        ready.wait()

    #If our slack client becomes broken, we want to kill bubblebot because we can't communicate.
    #We log to the default logger and to the console, wait 30 seconds to give logs a chance to flow
    #and to avoid an excessive number of retries, then shut down the server
    shutdown: (msg) ->
        setTimeout ->
            process.exit(1)
        , 30000
        console.log msg
        u.log msg


    #Handles incoming messages
    handle_message: (message) ->

    #Asks the given user a question, and returns their reply
    ask: (user, msg) ->


    #Sends a message to the announcements channel
    announce: (msg) ->

    #Sends a PM to admin users
    report: (msg) ->

    #TODO: Should make this configurable.  Right now it just takes the first one
    get_announcement_channel: ->


RtmClient = require('@slack/client').RtmClient
u = require './utilities'
