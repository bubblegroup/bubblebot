ssh = exports

#As we get output from the server, we want to write it to our logger in chunks...
#preferably all at once, but if a slow-running command has periodic output we
#log every 30 seconds
class LogFlusher
    constructor: (@name, @logger) ->
        @queue = []

        @flush_scheduled = null

        if @logger.is_console
            @interval = 1000
        else
            @interval = 30000

    write: (data) ->
        if @_finished
            throw new Error 'writing to a finished flusher'
        @queue.push data

        if not @flush_scheduled?
            @flush_scheduled = setTimeout @flush.bind(this), @interval

    flush: (finished) ->
        if finished
            @_finished = true

        if @queue.length > 0
            output = @queue.join('')

            @logger output
            @queue = []

        if @flush_scheduled?
            clearTimeout @flush_scheduled
            @flush_scheduled = null


#Returns a stream object that represents an interactive session
#supports .on 'data', .stderr.on 'data', .on 'close', .write, and .end
ssh.shell = (host, private_key) ->
    conn = get_connection(host, private_key)
    block = u.Block 'establishing shell'
    conn.shell block.make_cb()
    stream = block.wait()
    return stream

#Like run, but uses a shell instead of opening up a connection
ssh.shell_run = (host, private_key, cmd, options) ->
    {can_fail, timeout, no_log, logger} = options ? {}

    if not logger?
        if no_log
            logger = ->
        else
            logger = u.get_logger('log')

    logger '\Shell: ' + host + ': ' + cmd

    output = []

    stdout_log = new LogFlusher 'stdout', logger
    stderr_log = new LogFlusher 'stderr', logger

    stream = ssh.shell host, private_key

    on_data = (data) ->
        stdout_log.write data
        output.push data
    stream.on 'data', on_data

    on_stderr_data = (data) ->
        stderr_log.write data
        output.push data
    stream.stderr.on 'data', on_stderr_data

    stream.write cmd + '\n'

    stream.on 'error', (err) ->
        msg = 'Error from shell_run: ' + String(err)
        stdout_log.write msg
        output.push msg

    stream.stderr.on 'error', (err) ->
        msg = 'Stderr error from shell_run: ' + String(err)
        stderr_log.write msg
        output.push msg

    block = u.Block 'wait'
    setTimeout ->
        block.success()
    , timeout ? 10 * 1000
    block.wait(timeout + 10000)

    stream.end()

    stdout_log.flush(true)
    stderr_log.flush(true)

    output = output.join ''

    return output


ssh.run = (host, private_key, cmd, options) ->
    {can_fail, timeout, no_log, logger, shell} = options ? {}
    if shell
        return ssh.shell_run host, private_key, cmd, options

    if not logger?
        if no_log
            logger = ->
        else
            logger = u.get_logger('log')

    logger '\nSSH ' + host + ': ' + cmd

    stream = exec_ssh host, private_key, cmd

    output = []

    exit_code = null

    stdout_log = new LogFlusher 'stdout', logger
    stderr_log = new LogFlusher 'stderr', logger

    close_block = u.Block('ssh.run close block')
    block = u.Block('ssh.run')
    stderr_end = u.Block('ssh.run stderr_end')
    on_data = (data) ->
        stdout_log.write data
        output.push data
    stream.on 'data', on_data

    on_stderr_data = (data) ->
        stderr_log.write data
        output.push data
    stream.stderr.on 'data', on_stderr_data

    on_stderr_end = ->
        stderr_end.success()
    stream.stderr.on 'end', on_stderr_end

    on_error = (err) ->
        block.fail err
        close_block.fail err
    stream.on 'error', on_error

    on_close = (code) ->
        exit_code = code
        setTimeout ->
            close_block.success()
        , 200
    stream.on 'close', on_close

    on_end = ->
        setTimeout ->
            block.success()
        , 200
    stream.on 'end', on_end

    close_block.wait(timeout)
    block.wait(10000)
    stderr_end.wait(5000)

    stream.removeListener 'data', on_data
    stream.stderr.removeListener 'data', on_stderr_data
    stream.stderr.removeListener 'end', on_stderr_end
    stream.removeListener 'error', on_error
    stream.removeListener 'close', on_close
    stream.removeListener 'end', on_end

    stdout_log.flush(true)
    stderr_log.flush(true)

    output = output.join ''

    if exit_code isnt 0 and not can_fail
        error = new Error 'call "' + cmd + '" failed with non-zero exit code ' + exit_code
        error.output = output
        throw error

    return output


ssh.upload_file = (host, privateKey, filename, path) ->
    block = u.Block 'upload_file'
    if not privateKey
        throw new Error 'missing private key'
    u.log 'Uploading ' + filename + ' to ' + host + ':' + path
    scp2.scp filename, {host, privateKey, path, username: 'ec2-user'}, block.make_cb()
    block.wait(360000)

ssh.write_file = (host, privateKey, destination, content) ->
    block = u.Block 'write_file'
    client = new scp2.Client {host, privateKey, username: 'ec2-user'}
    client.write {destination, content}, block.make_cb()
    block.wait()

exec_ssh = (host, private_key, cmd) ->
    block = u.Block('exec_ssh')
    conn = get_connection(host, private_key)
    conn.exec cmd, {pty: true}, (err, stream) ->
        if err
            block.fail err
        else
            block.success stream
    handler = (err) ->
        block.fail err
    conn.once 'error', handler
    res = block.wait()
    res.setEncoding 'utf8'
    conn.removeListener 'error', handler
    return res


#Gets or creates a connection to the given host
get_connection = (host, private_key) ->
    if not private_key
        throw new Error 'missing private key!'

    context = u.context()
    if not context.ssh_connections
        context.ssh_connections = {}
        context.events.on 'destroy', ->
            for host, conn of context.ssh_connections
                conn.end()
            context.ssh_connections = null

    ssh_connections = context.ssh_connections

    if not ssh_connections[host]

        conn = new SSHClient()
        block = u.Block('getting connection')

        conn.on 'ready', -> block.success()

        conn.on 'end', ->
            if ssh_connections[host] is conn
                delete ssh_connections[host]

        conn.on 'close', ->
            if ssh_connections[host] is conn
                delete ssh_connections[host]

        conn.connect {
            host: host
            port: 22
            username: 'ec2-user'
            privateKey: private_key
        }

        conn.once 'error', (err) -> block.fail err

        block.wait()

        ssh_connections[host] = conn

        #If we get further errors, we just want to close the connection
        conn.on 'error', (err) ->
            if ssh_connections[host] is conn
                delete ssh_connections[host]
            try
                conn.end()
            catch err
                true


    return ssh_connections[host]

u = require './utilities'
SSHClient = require('ssh2').Client
scp2 = require 'scp2'