bbserver = exports

bbserver.Server = class Server
    #should listen on port 8081 for commands such as shutdown
    start: -> console.log 'I started the server!!!'