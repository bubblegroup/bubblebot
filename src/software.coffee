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

        add = (pkg) ->
            if dependencies.indexOf(pkg) isnt -1
                return
            for s in pkg.dependencies
                add s
            dependencies.push pkg

        add this

        #Then, go through each dependency and add its commands
        commands = []
        for pkg in dependencies
            for command in pkg.commands
                commands.push command

        return commands

    #Installs this stack of software on the given instance
    install: (instance) ->
        for command in @get_commands()
            instance.run(command)

    #Adds the given software to this stack
    add: (pkg) -> @dependencies.push pkg

    #Runs the given command
    run: (cmd) -> @commands.push cmd


#Manages instances
software.create = create = (fn) ->
    _instances = {}
    return (args...) ->
        key = args.join(',')
        _instances[key] ?= fn args...
        return _instances[key]


#Sets up sudo and yum and installs GCC
software.basics = create ->
    pkg = new Software()

    #unfuck sudo
    pkg.run "cat > tmp << 'EOF'\nalias sudo='sudo env PATH=$PATH NODE_PATH=$NODE_PATH'\nEOF"
    pkg.run 'sudo su -c"mv tmp /etc/profile.d/fix_sudo.sh"'

    #update yum and install git + development tools
    pkg.run 'sudo yum update -y'
    pkg.run 'sudo yum -y install git'
    pkg.run 'sudo yum install make automake gcc gcc-c++ kernel-devel git-core ruby-devel -y '

    return pkg


#Installs supervisor and sets it up to run the given command
software.supervisor = create (name, command, pwd) ->
    pkg = new Software()

    pkg.add software.basics()

    pkg.run 'sudo pip install supervisor==3.1'
    pkg.run '/usr/local/bin/echo_supervisord_conf > tmp'
    pkg.run 'cat >> tmp <<\'EOF\'\n\n[program:' + name + ']\ncommand=' + command + '\nenvironment=PWD="' + pwd + '"\n\nEOF'
    pkg.run 'sudo su -c"mv tmp /etc/supervisord.conf"'

    return pkg


#Installs node
software.node = create (version) ->
    pkg = new Software()

    pkg.add software.basics()

    pkg.run 'git clone https://github.com/tj/n'
    pkg.run 'cd n; sudo make install'
    pkg.run 'cd n/bin; sudo ./n ' + version
    pkg.run 'rm -rf n'

    return pkg


