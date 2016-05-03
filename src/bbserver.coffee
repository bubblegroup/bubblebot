bbserver = exports

bbserver.Server = class Server
    #should listen on port 8081 for commands such as shutdown
    start: ->
        server = http.createServer (req, res) ->
            res.write 'hi!!'
            res.end()

        server.listen 8080

        server2 = http.createServer (req, res) ->
            if req.url is '/shutdown'
                u.log 'Shutting down!'
                res.end bbserver.SHUTDOWN_ACK
                process.exit(1)
            else
                res.end 'unrecognized command'

        server2.listen 8081

        @slack_client = new slack.SlackClient(this)
        @slack_client.on 'new_conversation', (msg) ->
            throw u.error 'new_conversation not implemented'

        cloud = new clouds.AWSCloud()
        log_stream = cloud.get_bb_environment().get_log_stream('bubblebot', 'bubblebot_server')

        #Create the default log environment for the server
        logger = u.create_logger {
            log: log_stream.log.bind(log_stream)
            reply: -> throw new Error 'cannot reply: not in a conversation!'
            ask: -> throw new Error 'cannot ask: not in a conversation!'
            announce: @slack_client.announce.bind(@slack_client)
            report: @slack_client.report.bind(@slack_client)
        }

        u.set_default_logger logger

        u.announce 'Bubblebot is running!  Send me a PM for me info (say "hi" or "help")!  My system logs are here: ' + log_stream.get_tail_url() +

        #Handle uncaught exceptions.
        #We want to report them, with a rate limit of 10 per 30 minutes
        rate_limit_count = 0
        rate_limit_on = false
        process.on 'uncaughtException', (err) ->
            if rate_limit_on
                return

            rate_limit_count++
            if rate_limit_count is 10
                rate_limit_on = true
                setTimeout ->
                    rate_limit_count = 0
                    rate_lmit_on = false
                , 30 * 60 * 1000

            message = 'Uncaught exception: ' + (err.stack ? err)
            u.report message

    #Returns the list of admins.  Defaults to the owner of the slack channel.
    #TODO: allow this to be modified and saved in the db.
    get_admins: -> [@slack_client.get_slack_owner()]


bbserver.SHUTDOWN_ACK = 'graceful shutdown command received'


http = require 'http'
u = require './utilities'
slack = require './slack'
clouds = require './clouds'