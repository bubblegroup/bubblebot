server = exports

server.Server = class Server
    #Starts bubble bot running on a machine, including the web server and slack client
    start: ->
        winston.log 'Starting bubblebot...'