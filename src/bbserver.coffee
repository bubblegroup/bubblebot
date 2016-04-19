bbserver = exports

bbserver.Server = class Server
    #should listen on port 8081 for commands such as shutdown
    start: ->
        u.log 'starting bubblebot server'

        server = http.createServer (req, res) ->
            res.write 'hi!!'
            res.end()

        server.listen 8080

        server2 = http.createServer (req, res) ->
            if req.path is '/shutdown'
                u.log 'Shutting down!'
                res.end 'shutting down'
                process.exit(1)
            else
                res.end 'unrecognized command'

        server2.listen 8081


http = require 'http'
u = require './utilities'