bubblebot = exports

Error.stackTraceLimit = Infinity

commands = require './commands'

#Export everything in commands
for k, v of commands
    bubblebot[k] = v
