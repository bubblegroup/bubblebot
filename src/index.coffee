bubblebot = exports

Error.stackTraceLimit = Infinity

commands = require 'commands'
server = require 'server'
utilities = require 'utilities'

#Deploys the contents of the given folder to the cloud,
#creating a fresh bubblebot installation if one does not already exist
bubblebot.publish = commands.publish

#Starts an http server and the slack bot
bubblebot.listen = server.listen