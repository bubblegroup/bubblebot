bubblebot = exports

Error.stackTraceLimit = Infinity

commands = require './commands'
server = require './server'
utilities = require './utilities'

#Export everything in commands
for k, v of commands
    bubblebot[k] = v
