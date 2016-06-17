bubblebot = exports

commands = require './commands'
config = require './config'
bbserver = require './bbserver'
u = require './utilities'

#Export everything in commands
for k, v of commands
    bubblebot[k] = v

#Export config.init
bubblebot.initialize_configuration = (options, cb) ->
    if typeof(options) is 'function'
        cb = options
        options = null

    u.SyncRun ->
        if options?
            config.init options
        else
            config.init()
            config.init_account_specific()
        cb?()


#Export the Server class
bubblebot.Server = bbserver.Server

#Export various files...
bubblebot.utilities = u
bubblebot.templates = require './templates'
bubblebot.github = require './github'
bubblebot.config = require './config'
bubblebot.software = require './software'
bubblebot.bbobjects = require './bbobjects'
bubblebot.plugins = require './plugins'