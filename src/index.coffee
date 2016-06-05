bubblebot = exports

commands = require './commands'
config = require './config'
bbserver = require './bbserver'

#Export everything in commands
for k, v of commands
    bubblebot[k] = v

#Export config.init
bubblebot.initialize_configuration = (options) ->
    if options?
        config.init options
    else
        config.init()
        config.init_account_specific()


#Export the Server class
bubblebot.Server = bbserver.Server