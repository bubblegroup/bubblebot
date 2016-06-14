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

    #Adds a log message to the list of commands
    log: (msg) ->
        if @locked
            throw new Error 'locked!'
        @commands.push {log: msg}
        return this

    #Installs this stack of software on the given instance
    install: (instance) ->
        for command in @get_commands()
            if command.log
                u.log command.log
            else if command.fn
                command.fn instance
            else
                instance.run(command.cmd, {timeout: command.timeout ? 300000, no_log: command.no_log})

    #Adds the given software to this stack.  Returns itself to ease chaining.
    add: (pkg) ->
        if @locked
            throw new Error 'locked!'
        @dependencies.push pkg
        return this

    #Runs the given command as part of this package.  Returns itself to ease chaining
    run: (cmd, additional) ->
        if @locked
            throw new Error 'locked!'
        if typeof(cmd) is 'string'
            cmd = {cmd}
        if additional?
            u.extend cmd, additional
        @commands.push cmd
        return this

    #Runs the given function as part of this package
    call: (fn) ->
        if @locked
            throw new Error 'locked!'
        @commands.push {fn}

    #indicates that we are complete.  this is to avoid accidentally modifying built-in software
    lock: -> @locked = true


#Manages instances
software.create = create = (fn) ->
    _instances = {}
    return (args...) ->
        key = args.join(',')
        _instances[key] ?= fn args...
        _instances[key].lock()
        return _instances[key]


#Sets up sudo and yum and installs GCC
software.basics = create ->
    pkg = new Software()

    #Redirects 80 -> 8080 so that don't have to run things as root
    pkg.run "sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080"

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
    pkg.run 'cat >> tmp <<\'EOF\'\n\n[program:' + name + ']\ncommand=' + command + '\ndirectory=' + pwd + '\n\nEOF'
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


#Installs the server metrics plugin
software.metrics = create ->
    metrics_plugins = config.get_plugins 'metrics'

    if metrics_plugins.length is 0
        u.log 'WARNING: no metrics plugin installed... metrics package will not do anything'

    pkg = new Software()
    for plugin in metrics_plugins
        pkg.add plugin.get_server_metrics_software()

    return pkg

#Installs pg_dump for postgres 9.5
software.pg_dump95 = create ->
    pkg = new Software()
    #make have to do sudo yum -y erase postgresql92 postgresql92-libs

    pkg.run 'sudo yum -y localinstall https://download.postgresql.org/pub/repos/yum/9.5/redhat/rhel-6-x86_64/pgdg-ami201503-95-9.5-2.noarch.rpm'
    pkg.run 'sudo yum -y install postgresql95'

    return pkg

#Given a local path to a private key, installs that as the main key on this box
software.private_key = create (path) ->
    pkg = new Software()

    #Write the key
    key_data = fs.readFileSync path, 'utf8'
    pkg.log 'Writing private key to ~/.ssh/id_rsa'
    pkg.run {cmd: 'cat > ~/.ssh/id_rsa << EOF\n' + key_data + '\nEOF', no_log: true}
    pkg.run 'chmod 600 /home/ec2-user/.ssh/id_rsa'

    #turn off strict host checking so that we don't get interrupted by prompts
    pkg.run 'echo "StrictHostKeyChecking no" > ~/.ssh/config'
    pkg.run 'chmod 600 /home/ec2-user/.ssh/config'

    return pkg

u = require './utilities'
config = require './config'
fs = require 'fs'