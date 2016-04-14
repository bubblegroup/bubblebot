bubblebot = exports

commands = require './commands'
config = require './config'
bbserver = require './bbserver'

#Export everything in commands
for k, v of commands
    bubblebot[k] = v

#Export config.init
bubblebot.initialize_configuration = config.init

#Export the Server class
bubblebot.Server = bbserver.Server