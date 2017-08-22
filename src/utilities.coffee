u = exports

#Creates a tarball out of the given directory and saves it to a temporary file.
#Returns the path to the temp file
u.create_tarball = (directory) ->
    tempfile = tmp.tmpNameSync()
    u.run_local "tar -cf #{tempfile} -C #{directory} ."
    return tempfile

u.run_local = (cmd, options = {}) ->
    {can_fail, env, return_stderr, timeout} = options
    logger = u.get_logger('log')
    logger 'Running locally: ' + cmd
    block = u.Block 'run_local ' + cmd

    child_process.exec cmd, {encoding: 'utf8', env, maxBuffer: 10000*1024}, (err, stdout, stderr) ->
        if stdout
            logger stdout
        if stderr
            logger stderr
        if return_stderr
            ret = {stdout, stderr}
        else
            ret = stdout
        if err
            if can_fail
                block.success ret
            else
                block.fail err
        else
            block.success ret
    return block.wait(timeout)

#Removes all occurrences of val from this array
u.array_remove = (array, val) ->
    if not array?
        return
    while (idx = array.indexOf val) != -1
        array.splice idx, 1


#Given a destination object and one or more source objects, copies
#the key / values from the sources into the destination.  Not recursive, just
#touches the top level keys
u.extend = (dest, srcs...) ->
    for src in srcs
        for k, v of src ? {}
            dest[k] = v
    return dest

#Deep copies an object by converting it to JSON then parsing it
u.json_deep_copy = (obj) -> JSON.parse JSON.stringify obj


#converts a duration in ms to something human readable
u.format_time = (ms) ->
    seconds = Math.floor(ms / 1000)
    minutes = Math.floor(seconds / 60)
    hours = Math.floor(minutes / 60)
    days = Math.floor(hours / 24)

    minutes = minutes % 60
    seconds = seconds % 60
    hours = hours % 24
    tenths = Math.floor(ms / 100) % 10

    add = (name, amt) -> if amt is 1 then "1 #{name}, " else if amt > 0 then "#{amt} #{name}s, " else ""

    return add('day', days) + add('hour', hours) + add('minute', minutes) + seconds + '.' + tenths + ' seconds'

#converts 0.0234 -> 2.3%
u.format_percent = (decimal) ->
    return String(Math.floor(decimal * 1000) / 10) + '%'

#Converts 12.567 into 12.6
u.format_decimal = (decimal) -> String(Math.round(decimal * 10) / 10)


#Returns {private_key, public_key}
u.generate_key_pair = ->
    cmd = 'openssl genrsa 2048'
    block = u.Block cmd
    child_process.exec cmd, {encoding: 'ascii'}, block.make_cb()
    private_key = block.wait()

    block = u.Block 'openssl rsa -pubout'
    stderr = ''
    stdout = ''
    make_pub = child_process.spawn 'openssl', ['rsa', '-pubout']
    make_pub.stderr.on  'data', (data) -> stderr += data
    make_pub.stdout.on 'data', (data) -> stdout += data
    make_pub.on 'error', (err) -> block.fail err
    make_pub.on 'close', (code) ->
        if code is 0
            block.success stdout
        else
            block.fail u.error 'error running generating public key: ' + stderr
    make_pub.stdin.write private_key
    make_pub.stdin.end()
    public_key = block.wait()

    return {private_key, public_key}



#Chatting (at various levels of verbosity ranging from most critical to hear to least):
# report -- for problems (default is to pm administrators and current user)
# announce -- for updates like a new deployment (default is to post in a public channel)
# reply -- for things relevant to the current user (default is to pm current user)
# log -- for everything else (default is to save to a transcript)

# Log, announce, and report must work off fiber.

#Reports a problem / failure / error (and logs to current context)
u.report = (msg) -> u.get_logger('report') msg

#Reports a message over slack without writing it to log as well
u.report_no_log = (msg) -> u.get_logger('report_no_log') msg

#Announces a message in to all users (And logs to current context)
u.announce = (msg) -> u.get_logger('announce') msg

#Sends a message to the given user
u.message = (user_id, msg) -> u.get_logger('message') user_id, msg

#Replies to the current user
u.reply = (msg) -> u.get_logger('reply') msg

#Asks the current user a question and returns their response
u.ask = (msg, user_id) -> return u.get_logger('ask') msg, user_id

#Confirms the user wants to do something, returning a boolean
u.confirm = (msg) -> return u.get_logger('confirm') msg

#Logs a message to the current context
u.log = (msg) -> u.get_logger('log') msg

bound_console = console.log.bind(console)
bound_console.is_console = true

#Gets a log function.  Sees if it is set in the current context... if not, uses the default logger
u.get_logger = (log_fn) ->
    u.context()?.loggers?[log_fn] ? u.default_loggers?[log_fn] ? bound_console

#Runs fn in the context of the given logger    
u.with_logger = (name, log_fn, fn) ->
    old_logger = u.context().loggers?[name]
    try
        u.set_logger name, log_fn
        return fn()
    finally
        u.context().loggers[name] = old_logger
        
#Runs a function redirecting 'reply' and 'announce' to 'log'
u.run_silently = (fn) ->
    silent_reply = (msg) -> u.log 'Reply (silenced): ' + msg
    silent_announce = (msg) -> u.log 'Announce (silenced): ' + msg
    return u.with_logger 'reply', silent_reply, ->
        return u.with_logger 'announce', silent_announce, fn
        

#Sets a function in the current context
u.set_logger = (name, fn) ->
    context = u.context()
    context.loggers ?= {}
    context.loggers[name] = fn

#Sets the loggers to use when we are outside of a context
u.set_default_loggers = (loggers) -> u.default_loggers = loggers


#Gets the global environment for the current fiber, or null
#if we are off-fiber
#
#If we pass in a fiber, returns that fibers' context instead of the current one
#
#If we are not on any fiber, returns null
u.context = (fiber) ->
    fiber ?= Fiber.current
    if not fiber?
        return null

    if not fiber.current_context
        fiber.current_context = {}
        fiber.current_context.events = new events.EventEmitter()

    return fiber.current_context


#Shortcut for getting the current context's databse
u.db = -> u.context()?.db

#Shortcut for getting the current user
u.current_user = -> u.context()?.current_user?() ? null

#Pauses the current fiber for this # of ms
u.pause = (ms) ->
    block = u.Block 'pause'
    setTimeout block.make_cb(), ms
    block.wait(ms + 20000)


#Generates a command for the user to type in based on an array of args... takes care of adding quotes
#if necessary
u.build_command = (args) ->
    print_arg = (arg) ->
        arg = String(arg)
        if arg.indexOf(' ') is -1
            return arg
        else if arg.indexOf('"') is -1
            return '"' + arg + '"'
        else
            return "'" + arg + "'"
    return (print_arg arg for arg in args).join(' ')



#Tries running the function multiple times until it runs without an error
#
#tries is optional: defaults to 10 before throwing
#
#pause is optional: defaults to 100 ms in between tries
#
#Calls:
#
#u.retry(fn)
#u.retry(tries, fn)
#u.retry(tries, pause, fn)
u.retry = (a, b, c) ->
    if not b?
        fn = a
    else if not c?
        tries = a
        fn = b
    else
        tries = a
        pause = b
        fn = c

    tries ?= 10
    pause ?= 100

    try
        return fn()
    catch err
        if tries > 1
            u.pause pause
            return u.retry(tries - 1, pause, fn)
        else
            throw err



#Creates a lock object that fibers can acquire and release
#
#Acquiring the same lock multiple times has no effect
#
#n is the number of parallel fibers that can aquire the same lock.  Defaults to 1.
u.Lock = (acquire_timeout, n, name) -> new Lock acquire_timeout, n, name

class Lock
    constructor: (@acquire_timeout, @n = 1, @name = '') ->
        @waiting_on = []

        #fibers currently holding the lock 
        @owners = []

    #Acquires the lock, runs the function, then releases the lock.
    #This is the recommended way to use locks... if we use a lower-level
    #function there is no guarantee the lock is ever released.
    run: (fn) ->
        if Fiber.current in @owners
            return fn()
        
        @acquire()
        try
            return fn()
        finally
            @release()

    acquire: ->
        if not Fiber.current
            throw new Error 'Cannot acquire a lock off-fiber!'
            
        if Fiber.current in @owners
            throw new Error 'You already hold this lock!'
    
        #while someone else owns this lock, wait...
        while @owners.length is @n and Fiber.current not in @owners
            #u.log 'Waiting on lock ' + @name + ' (owned by ' + (u.fiber_id(owner) for owner in @owners).join(', ') + ')'
            
            if @owners.length is @n and Fiber.current not in @owners
                block = u.Block 'waiting on lock'
                @waiting_on.push block
                block.wait(@acquire_timeout)

        #own this lock
        @owners.push Fiber.current

    release: ->
        #Only the holding thread can release
        if Fiber.current not in @owners
            throw new Error 'cannot release lock, you do not own it'

        #Release the lock
        u.array_remove @owners, Fiber.current

        #shift the first thing waiting on this lock off the stack and let it
        #try to acquire the lock again
        next = @waiting_on.shift()
        next?.success()
        
        #if next
        #    u.log 'Released lock ' + @name
        
        



#Some standard error codes
u.TIMEOUT = 'timeout'                 #generic timeout (lots of things could cause this)
u.CANCEL = 'cancel'                   #user cancelled the command
u.USER_TIMEOUT = 'user_timeout'       #timed out waiting on a user reply
u.EXTERNAL_CANCEL = 'external_cancel' #was cancelled from off-fiber
u.EXPECTED = 'expected'               #this error is expected and should be passed on to the end user

u.expected_error = (msg) ->
    err = new Error msg
    err.reason = u.EXPECTED
    throw err

#Marks this fiber as cancelled, and schedules it to run
#
#Reason allows inserting a custom reason
u.cancel_fiber = (fiber, reason) ->
    fiber._externally_cancelled = reason ? true
    setTimeout ->
        start_fiber_run fiber
    , 1
    clearTimeout fiber._u_fiber_timeout_cb

#Un-marks the current fiber as being cancelled... useful in error handling code
#so that we can continue cleaning up
u.uncancel_fiber = ->
    Fiber.current._externally_cancelled = false



# #### u.Block
# Interface for working with fibers.  Returns a block, which you can call success (data) and fail (err), and wait (returns success data or throws fail error)
# Example:
#
# block = u.Block(name)
# async_function (err, result) ->
#    if err
#       block.fail err
#    else
#       block.success result
#
# my_result = block.wait()
#
u.Block = (name) -> new Block(name)

class Block
    constructor: (@name) ->
        if not @name?
            throw new Error 'blocks must be named'

    #See if this fiber has been marked as cancelled externally: if so, throw a cancellation error.
    check_cancelled: ->
        if Fiber.current._externally_cancelled
            #If it's a custom reason, clear the cancel state and throw an error with that reason
            if typeof(Fiber.current._externally_cancelled) is 'string'
                reason = Fiber.current._externally_cancelled
            else
                reason = u.EXTERNAL_CANCEL

            err = new Error 'this fiber was cancelled'
            err.reason = reason
            throw err

    wait: (timeout) ->
        if not Fiber.current
            throw new Error 'Not inside SyncRun!'

        @check_cancelled()

        old_timeout = Fiber.current._u_fiber_timeout
        if timeout?
            Fiber.current._u_fiber_timeout = timeout

        if not @finished
            @my_fiber = Fiber.current
            start_fiber_timeout()

            @yielded = true
            record_stop()
            Fiber.yield()
            @yielded = false

            @check_cancelled()

            check_fiber_timeout(@name)

            #avoid hanging onto the reference now that we don't need it
            @my_fiber = null

        [err, data] = @result

        if err?
            #capture the current call stack as well:
            if not (err instanceof Error)
                err = new Error err
            err.stack ?= ''
            err.stack += '\n\n' + (new Error('Outer Error (see above for inner error)')).stack
            throw err

        Fiber.current._u_fiber_timeout = old_timeout

        return data

    success: (data) -> @_complete [null, data]

    #Returns an (err, res) -> callback that calls this block
    make_cb: -> return (err, res) => if err then @fail err else @success res

    fail: (err) -> @_complete [err]

    _complete: (result) ->
        if @finished
            return
        @finished = true
        @result = result

        if @yielded
            start_fiber_run @my_fiber


#Keep track of how much time we spend in each fiber
fiber_timing = {}
current_fiber_name = null
current_fiber_start = null
current_server_start = null
last_fiber_stop = null

#Breaks up a fiber run into multiple named segments (for u.get_cpu_usage)
u.cpu_checkpoint = (name) ->
    record_stop()
    Fiber.current.cpu_name = name
    record_start Fiber.current


#Indicate that we have left the execution thread of this fiber
record_stop = ->
    if not current_fiber_name
        throw new Error 'record_stop with no fiber name!'

    cur = Date.now()
    run_time = cur - current_fiber_start
    last_fiber_stop = cur
    fiber_timing[current_fiber_name] ?= 0
    fiber_timing[current_fiber_name] += run_time
    current_fiber_name = null
    current_fiber_start = null


#Indicate that we are beginning the execution thread of this fiber
record_start = (fiber) ->
    if current_fiber_name?
        throw new Error 'already on ' + current_fiber_name
    current_fiber_name = fiber.cpu_name
    cur = Date.now()
    current_fiber_start = cur
    current_server_start ?= cur

#Returns data about which fibers have been consuming CPU cycles.
u.get_cpu_usage = ->
    total_time = last_fiber_stop - current_server_start
    res = {}
    for k, v of fiber_timing
        res[k] = v / total_time
    return res


#Starts the given fiber running, and records the timestamp on the fiber.
#Use instead of fiber.run()
start_fiber_run = (my_fiber) ->
    #Calling fiber run on a fiber that's finished will restart it!
    if my_fiber.fiber_is_finished
        throw new Error 'Trying to resume finished fiber!'

    do_it = ->
        record_start my_fiber
        my_fiber.run()

    #if we are on a fiber right now, we want to wait until this fiber yields
    if Fiber.current
        setImmediate do_it
    else
        do_it()


#Makes sure we are in a fiber to run the given function; if not, creates a new one
u.ensure_fiber = (fn) ->
    if Fiber.current?
        fn()
    else
        u.SyncRun 'ensure_fiber', fn

#Runs a function in a fiber that shares a context with the parent fiber.
#This allows running things in parallel from the same process.
#
#Returns a wait() function that waits for the sub-fiber to finish and returns the result or throws the error
#
#We set a very long timeout on the sub-fiber... the sub-fiber is responsible for having sensible
#internal timeouts
u.sub_fiber = (fn) ->
    shared_context = u.context()
    block = u.Block 'running sub-fiber'
    u.SyncRun 'sub_fiber', ->
        try
            Fiber.current.current_context = u.extend {}, shared_context
            #Build a copy of the loggers object so u.with_logger can override logger for just this sub-fiber
            Fiber.current.current_context.loggers = u.extend {}, (Fiber.current.current_context.loggers ? {})
            
            if Fiber.current.current_context.original_message
                Fiber.current.current_context.original_message + ' (sub-fiber)'
            if Fiber.current.current_context.name
                Fiber.current.current_context.name + ' (sub-fiber)'

            block.success fn()
        catch err
            block.fail err
    return block.wait.bind(block, 24 * 60 * 60 * 1000)

#A list of all ongoing fibers
u.active_fibers = []

fiber_id_counter = 0

#Gets the fiber id for the current fiber.  Or pass in a fiber to get the id for that fiber.
u.fiber_id = (fiber) ->
    fiber ?= Fiber.current
    return fiber._fiber_id

#Gets the current fiber
u.fiber = -> Fiber.current


# #### u.SyncRun
#Runs the callback in a fiber.  Safe to call either from within a fiber or from non-fiber
#code... runs it in on a setImmediate block, so this function returns immediately.
#
#If ignore_fiber_lock is true, this makes the fiber run regardless of whether there's
#a fiber lock
#
#cpu_name is what we name the fiber for cpu usage monitoring purposes
u.SyncRun = SyncRun = (cpu_name, cb) ->
    go = ->
        f = null
        run_fn = ->
            try
                if not f
                    throw new Error 'restarting dead fiber'
            
                #track the fiber
                u.active_fibers.push f
                f._fiber_id = fiber_id_counter
                fiber_id_counter++

                cb()
            catch err
                throw err
            finally
                record_stop()
                f.fiber_is_finished = true #fibers will restart if run is called after they finished!

                u.array_remove u.active_fibers, f

                #Destroy the context
                f.current_context?.events.emit 'destroy'

                #Keeping a reference to the fiber will hold it in memory permanently
                f = null

        f = Fiber run_fn
        f.cpu_name = cpu_name
        f._u_fiber_timeout = 90 * 1000 #we set a default timeout, since accidentally not setting a timeout can lead to memory leaks
        start_fiber_run f

    setImmediate go


u.FiberTimeout = (timeout) ->
    Fiber.current._u_fiber_timeout = timeout

u.GetFiberTimeout = -> Fiber.current._u_fiber_timeout


# Call this right before a fiber yields to see if a timeout is set, and if so to start it
start_fiber_timeout = ->
    my_fiber = Fiber.current
    if my_fiber._u_fiber_timeout
        my_fiber._u_fiber_timeout_cb = setTimeout ->
            clearTimeout my_fiber._u_fiber_timeout_cb

            #We set another timeout because in case the timeout happened because something
            #was hogging the event loop, we want to give the actual callback a chance to
            #run first before throwing an error
            my_fiber._u_fiber_timeout_cb = setTimeout ->
                my_fiber._u_fiber_did_timeout = true
                start_fiber_run my_fiber

                #clear the reference to fiber timeout callback, since it references the fiber!!
                clearTimeout my_fiber._u_fiber_timeout_cb
                my_fiber._u_fiber_timeout_cb = null
            , 500
        , my_fiber._u_fiber_timeout


#call this right after a fiber yield to see if the timeout fired, and if so to raise an error
check_fiber_timeout = (name) ->
    my_fiber = Fiber.current

    if my_fiber._u_fiber_timeout_cb
        clearTimeout my_fiber._u_fiber_timeout_cb
        my_fiber._u_fiber_timeout_cb = null

    if my_fiber._u_fiber_did_timeout
        #clear this since we might do more on this fiber in the error handling process
        my_fiber._u_fiber_did_timeout = null

        msg = my_fiber._u_fiber_timeout_msg ? 'Current fiber timed out after ' + Fiber.current._u_fiber_timeout + ' ms'
        err = new Error msg
        err.reason = u.TIMEOUT
        throw err

#Generates a random password
u.gen_password = (size = 13) -> crypto.randomBytes(size).toString('hex')

#Pretty-prints a date in the default timezone
u.print_date = (date) ->
    moment(date).tz(config.get('default_timezone')).format('MM/DD/YY hh:mm:ss a z')


#Pads text with extra spaces up to num, and wraps in back-ticks
pad_text = (text, num) ->
    return '`' + text + (new Array(num - text.length)).join(' ') + '`'

#Given a [Rows...] array where each row is a [columns...] array, prints out a padded table
u.make_table = (rows) ->
    #compute the max size of each column
    maxes = []
    for row in rows
        for column, c_idx in row
            if not maxes[c_idx]? or column.length > maxes[c_idx]
                maxes[c_idx] = column.length

    print_column = (column, idx) ->
        #don't pad the last column
        if idx is maxes.length - 1
            return column
        else
            return pad_text(column, maxes[idx] + 1)

    print_row = (row) -> (print_column column, c_idx for column, c_idx in row).join('    ')

    return (print_row row for row in rows).join('\n')


#Generates a sha256 hex digest of the given text
u.digest = (text, encoding = 'utf8') ->
    hasher = crypto.createHash 'sha256'
    hasher.update text, encoding
    return hasher.digest 'hex'


child_process = require 'child_process'
tmp = require 'tmp'
Fiber = require 'fibers'
crypto = require 'crypto'
moment = require 'moment'
require 'moment-timezone'
config = require './config'
events = require 'events'