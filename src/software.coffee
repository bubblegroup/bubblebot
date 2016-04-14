software = exports

#Abstraction for installing a software with dependencies
software.Software = class Software
    constructor: ->
        @dependencies = []
        @commands = []

    #Evaluates the dependency tree to get the total array of commands to execute
    get_commands: ->
        #first, build the dependency tree.
        dependencies = []

        add = (software) ->
            if dependencies.indexOf(software) isnt -1
                return
            for s in software.dependencies
                add s
            dependencies.push software

        add this

        #Then, go through each dependency and add its commands
        commands = []
        for software in dependencies
            for command in software.commands
                commands.push command

        return commands

    #Installs this stack of software on the given instance
    install: (instance) ->
        for command in @get_commands()
            instance.run(command)

    #Adds the given software to this stack
    add: (software) -> @dependencies.push software

    #Runs the given command
    run: (cmd) -> @commands.push cmd


#Sets up sudo and yum and installs GCC
software.basics = create ->
    package = new Software()

    #unfuck sudo
    package.run "cat > tmp << 'EOF'\nalias sudo='sudo env PATH=$PATH NODE_PATH=$NODE_PATH'\nEOF"
    package.run 'sudo su -c"mv tmp /etc/profile.d/fix_sudo.sh"'

    #update yum and install git + development tools
    package.run 'sudo yum update -y'
    package.run 'sudo yum -y install git'
    package.run 'sudo yum install make automake gcc gcc-c++ kernel-devel git-core ruby-devel -y '

    return package


#Installs supervisor and sets it up to run the given command
software.supervisor = create (name, command, pwd) ->
    package = new Software()

    package.add basics

    package.run 'sudo pip install supervisor==3.1'
    package.run '/usr/local/bin/echo_supervisord_conf > tmp'
    package.run 'cat >> tmp <<\'EOF\'\n\n[program:' + name + ']\ncommand=' + command + '\nenvironment=PWD="' + pwd + '"\n\nEOF'
    package.run 'sudo su -c"mv tmp /etc/supervisord.conf"'

    return package


#Installs node
software.node = create (version) ->
    package = new Software()

    package.add basics

    package.run 'git clone https://github.com/tj/n'
    package.run 'cd n; sudo make install'
    package.run 'cd n/bin; sudo ./n ' + version
    package.run 'rm -rf n'

    return package


#Manages instances
software.create = create = (fn) ->
    _instances = {}
    return (args...) ->
        key = args.join(',')
        _instances[key] ?= fn args...
        return _instances[key]
