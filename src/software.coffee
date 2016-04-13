software = exports

#Abstraction for installing a software with dependencies
software.Software = class Software
    #Installs this stack of software on the given instance
    install: (instance) ->

    #Adds the given software to this stack
    add: (software) ->

#Installs supervisor and sets it up to run the given command
software.supervisor = create (command) ->

#Installs node
software.node = create (version) ->



#Manages instances
software.create = create = (fn) ->
    _instances = {}
    return (args...) ->
        key = args.join(',')
        _instances[key] ?= fn args..
        return _instances[key]