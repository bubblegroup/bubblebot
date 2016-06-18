software = exports

#Functions for installing various software packages, and simple dependency management.

#Most software functions return a (instance) -> function that installs the software on the instance

#Given an (instance) -> ... function, returns an (instance) -> ... function that checks
#to see if the instance already has the installed software on it, and if so, does not install
#it again.
#
#This is useful for allowing multiple code paths to specify the same dependencies without worrying
#about installing the dependencies multiple times
software.do_once = do_once = (name, fn) ->
    return (instance) ->
        dependencies = instance.run 'cat bubblebot_dependencies || echo ""'
        if name in dependencies.split('\n')
            return

        fn instance
        dependencies += '\n' + name
        instance.run 'cat > bubblebot_dependencies << EOF\n' + dependencies + '\nEOF'



#Sets up sudo and yum and installs GCC
software.basics = -> do_once 'basics', (instance) ->
    #Redirects 80 -> 8080 so that don't have to run things as root
    instance.run "sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080"
    #And 443 -> 8043
    instance.run "sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8043"

    #update yum and install git + development tools
    instance.run 'sudo yum update -y'
    instance.run 'sudo yum -y install git'
    instance.run 'sudo yum install make automake gcc gcc-c++ kernel-devel git-core ruby-devel -y '


#Installs supervisor and sets it up to run the given command
software.supervisor = (name, command, pwd) -> (instance) ->
    software.basics() instance

    instance.run 'sudo pip install supervisor==3.1'
    instance.run '/usr/local/bin/echo_supervisord_conf > tmp'
    instance.run 'cat >> tmp <<\'EOF\'\n\n[program:' + name + ']\ncommand=' + command + '\ndirectory=' + pwd + '\n\nEOF'
    instance.run 'sudo su -c"mv tmp /etc/supervisord.conf"'

#Verifies that the given supervisor process is running for the given number of seconds
#
#If not, logs the tail and throws an error
software.verify_supervisor = (server, name, seconds) ->
    u.pause (seconds + 2) * 1000
    status = server.run 'supervisorctl status ' + name
    if status.indexOf('RUNNING') isnt -1
        uptime = status.split('uptime ')[1]
        uptime_seconds = parseInt(uptime.split(':')[2])
        uptime_minutes = parseInt(uptime.split(':')[1])
        if (uptime_minutes * 60) + uptime_seconds >= seconds
            return

    server.run 'tail -n 100 /tmp/' + name + '*'

    throw new Error 'Supervisor not running for at least ' + seconds + ' seconds: ' + status + '.  See tailed logs below'

#Installs node
software.node = (version) -> do_once 'node ' + version, (instance) ->
    software.basics() instance

    instance.run 'git clone https://github.com/tj/n'
    instance.run 'cd n; sudo make install'
    instance.run 'cd n/bin; sudo ./n ' + version
    instance.run 'rm -rf n'


#Installs the server metrics plugin
software.metrics = -> do_once 'metrics_plugin', (instance) ->
    metrics_plugins = config.get_plugins 'metrics'

    if metrics_plugins.length is 0
        u.log 'WARNING: no metrics plugin installed... metrics package will not do anything'

    for plugin in metrics_plugins
        plugin.get_server_metrics_software() instance


#Installs pg_dump for postgres 9.5
software.pg_dump95 = -> do_once 'pg_dump95', (instance) ->
    instance.run 'sudo yum -y localinstall https://download.postgresql.org/pub/repos/yum/9.5/redhat/rhel-6-x86_64/pgdg-ami201503-95-9.5-2.noarch.rpm'
    instance.run 'sudo yum -y install postgresql95'


#Given a local path to a private key, installs that as the main key on this box
software.private_key = (path) -> (instance) ->
    #Write the key
    key_data = fs.readFileSync path, 'utf8'
    u.log 'Writing private key to ~/.ssh/id_rsa'
    instance.run 'cat > ~/.ssh/id_rsa << EOF\n' + key_data + '\nEOF', {no_log: true}
    instance.run 'chmod 600 /home/ec2-user/.ssh/id_rsa'

    #turn off strict host checking so that we don't get interrupted by prompts
    instance.run 'echo "StrictHostKeyChecking no" > ~/.ssh/config'
    instance.run 'chmod 600 /home/ec2-user/.ssh/config'


u = require './utilities'
config = require './config'
fs = require 'fs'