#Metrics plugin backed by Librato

librato = exports

librato.get_server_metrics_software = -> software.do_once 'librato_server_metrics_software1',  (instance) ->
    #Write the yum config.  We first write it to a temporary file, then as root we move
    #it into the correct location
    yumconfig = """
[librato_librato-amazonlinux-collectd]
name=librato_librato-amazonlinux-collectd
baseurl=https://packagecloud.io/librato/librato-amazonlinux-collectd/el/6/x86_64
repo_gpgcheck=1
gpgcheck=0
enabled=1
priority=1
gpgkey=https://packagecloud.io/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
"""
    cmd = 'cat > /tmp/librato_librato-amazonlinux-collectd.repo <<EOF\n' + yumconfig + '\nEOF'
    instance.run cmd

    instance.run "sudo runuser -l root -c 'mv /tmp/librato_librato-amazonlinux-collectd.repo /etc/yum.repos.d/librato_librato-amazonlinux-collectd.repo'"

    #Dependencies for GPG key verification
    instance.run "sudo yum install -y pygpgme --disablerepo='librato_librato-amazonlinux-collectd'", {timeout: 5 * 60 * 1000}
    instance.run "sudo yum install -y yum-utils --disablerepo='librato_librato-amazonlinux-collectd'", {timeout: 5 * 60 * 1000}
    instance.run "sudo yum -q makecache -y --disablerepo='*' --enablerepo='librato_librato-amazonlinux-collectd'", {timeout: 5 * 60 * 1000}

    #Enable the EPEL repository
    instance.run "sudo yum install -y epel-release"
    instance.run "sudo yum-config-manager --enable epel"

    #May not be necessary, debugging an issue...
    u.log 'pausing before collectd installation'
    u.pause 1000
    instance.run "sudo killall yum", {can_fail: true}

    #Install the librato agent
    instance.run "sudo yum install -y collectd"

    #Set the user and password
    user = config.get "plugins.librato.email"
    password = config.get "plugins.librato.token"
    instance.run """sed 's/User ""/User "#{user}"/' /opt/collectd/etc/collectd.conf.d/librato.conf | sed 's/Password ""/Password "#{password}"/' > /tmp/librato.conf"""
    instance.run "sudo runuser -l root -c 'mv /tmp/librato.conf /opt/collectd/etc/collectd.conf.d/librato.conf'"

    instance.run 'sudo service collectd restart'

measures = {}
counts = {}

#Saves a measurement
librato.measure = (source, name, value) ->
    if not value?
        throw new Error 'librato.measure with null value for ' + source + ', ' + name

    start_flusher()

    measures[source] ?= {}
    measures[source][name] ?= []
    measures[source][name].push value


#Increments a counter
librato.increment = (source, name, value = 1) ->
    if not name or typeof(name) is 'number'
        throw new Error 'librato.increment without a name'

    start_flusher()

    counts[source] ?= {}
    counts[source][name] ?= 0
    counts[source][name] += value


#Sends an annotation
librato.annotate = (stream, title, description) ->
    librato_client().post '/annotations/' + stream, {
        title
        description
    }, (err, res) ->
        if err
            throw err



LIBRATO_INTERVAL = 10 * 1000

librato_client = -> librato_metrics.createClient {
    email: config.get 'plugins.librato.email'
    token: config.get 'plugins.librato.token'
}

sanitize_source = (source) ->
    source = source.replace(/[^A-Za-z0-9\.:\-_]/g, '.')
    source = source[...63]
    return source

_flusher_on = false
start_flusher = ->
    if _flusher_on
        return
    _flusher_on = true

    setInterval ->
        gauges = []

        for source, data of measures
            for name, values of data
                gauges.push {
                    source: sanitize_source source
                    name
                    count: values.length
                    sum: values.reduce ((prev, cur) -> prev + cur), 0
                    max: Math.max values...
                    min: Math.min values...
                    sum_squares: values.reduce ((prev, cur) -> prev + (cur * cur)), 0
                }

        for source, data of counts
            for name, count of data
                gauges.push {
                    source: sanitize_source source
                    name
                    value: count
                }

        measures = {}
        counts = {}

        if gauges.length > 0
            librato_client().post '/metrics', {
                gauges
            }, (err, res) ->
                if err
                    u.log 'Error posting to librato: ' + (if res then '\n' + JSON.stringify(res) + '\n' else '') + (err.stack ? err)

    , LIBRATO_INTERVAL



config = require './../config'
software = require './../software'
librato_metrics = require 'librato-metrics'
u = require './../utilities'