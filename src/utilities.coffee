u = exports

#Creates a tarball out of the given directory and saves it to a temporary file.
#Returns the path to the temp file
u.create_tarball = (directory) ->
    tempfile = tmp.tmpNameSync()
    u.run_local "tar -cf #{tempfile} -C #{directory} ."
    return tempfile

u.run_local = (cmd, options = {}) ->
    {can_fail} = options
    u.log 'Running locally: ' + cmd
    block = u.Block 'run_local ' + cmd
    child_process.exec cmd, {encoding: 'utf8'}, (err, stdout, stderr) ->
        if err
            if can_fail
                block.success stdout + stderr
            else
                block.fail err
        else
            block.success stdout + stderr
    return block.wait()


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
u.report = (msg) -> u.get_logger().report msg

#Announces a message in to all users (And logs to current context)
u.announce = (msg) -> u.get_logger().announce msg

#Replies to the current user
u.reply = (msg) -> u.get_logger().reply msg

#Asks the current user a question and returns their response
u.ask = (msg) -> return u.get_logger().ask msg

#Logs a message to the current context
u.log = (msg) -> u.get_logger().log msg

#Gets the current context's logger
u.get_logger = -> u.get_context()?.logger ? u.get_default_logger()

#Sets the current context's logger
u.set_logger = (logger) ->
    context = u.get_context()
    if not context
        throw new Error 'no context!'
    context.logger = logger

#Creates a logger object where all non-log methods also log
u.create_logger = (methods) ->
    logger = {}
    logger.log = methods.log
    for name in ['report', 'announce', 'reply']
        logger[name] = (msg) ->
            try
                logger.log '\n\n' + name.toUpperCase() + ': ' + msg
            catch err
                console.log err.stack ? err
            methods[name]? msg
        logger[name + '_no_log'] = methods[name]
    return logger

#Gets a logger that just console.logs everything
_default_logger = u.create_logger {log: console.log.bind(log)}

#Gets the logger to use when we are outside of a context
u.get_default_logger = ->
    return _default_logger

#Sets the logger to use when we are outside of a context
u.set_default_logger = (logger) ->
    _default_logger = logger
    #


#Gets the global environment for the current fiber, or null
#if we are off-fiber
u.get_context = ->
    Fiber.current?.current_context ?= {}
    return Fiber.current?.current_context ? null

#Shortcut for getting the current context's databse
u.db = -> u.get_context()?.db

#Pauses the current fiber for this # of ms
u.pause = (ms) ->
    block = u.Block 'pause'
    setTimeout block.make_cb(), ms
    block.wait()


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
u.Lock = -> new Lock()

class Lock
    constructor: (@acquire_timeout) ->
        @waiting_on = []

    #Acquires the lock, runs the function, then releases the lock.
    #This is the recommended way to use locks... if we use a lower-level
    #function there is no guarantee the lock is ever released.
    run: (fn) ->
        @acquire()
        try
            return fn()
        finally
            @release()

    acquire: ->
        #while someone else owns this lock, wait...
        while @owner? and @owner isnt Fiber.current?
            block = u.Block 'waiting on lock'
            @waiting_on.push block
            block.wait(@acquire_timeout)

        #own this lock
        @owner = Fiber.current

    release: ->
        #Only the holding thread can release
        if @owner isnt Fiber.current?
            return

        #Release the lock
        @owner = null

        #shift the first thing waiting on this lock off the stack and let it
        #try to acquire the lock again
        next = @waiting_on.shift()
        block.success()


#Some standard error codes
u.TIMEOUT = 'timeout'               #generic timeout (lots of things could cause this)
u.CANCEL = 'cancel'                 #user cancelled the command
u.USER_TIMEOUT = 'user_timeout'     #timed out waiting on a user reply



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

    wait: (timeout) ->
        old_timeout = Fiber.current._u_fiber_timeout
        if timeout?
            Fiber.current._u_fiber_timeout = timeout

        if not @finished
            if not Fiber.current
                throw new Error 'Not inside SyncRun!'
            @my_fiber = Fiber.current
            start_fiber_timeout()

            @yielded = true
            Fiber.yield()
            @yielded = false

            check_fiber_timeout(@name)

            #avoid hanging onto the reference now that we don't need it
            @my_fiber = null

        [err, data] = @result

        if err?
            #capture the current call stack as well:
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


#Starts the given fiber running, and records the timestamp on the fiber.
#Use instead of fiber.run()
start_fiber_run = (my_fiber) ->
    #Calling fiber run on a fiber that's finished will restart it!
    if my_fiber.fiber_is_finished
        throw new Error 'Trying to resume finished fiber!'

    my_fiber.run()


#Makes sure we are in a fiber to run the given function; if not, creates a new one
u.ensure_fiber = (fn) ->
    if Fiber.current?
        fn()
    else
        u.SyncRun fn

# #### u.SyncRun
#Runs the callback in a fiber.  Safe to call either from within a fiber or from non-fiber
#code... runs it in on a setImmediate block, so this function returns immediately.
#
#If ignore_fiber_lock is true, this makes the fiber run regardless of whether there's
#a fiber lock
u.SyncRun = SyncRun = (cb) ->
    go = ->
        f = null
        run_fn = ->
            try
                cb()
            catch err
                throw err
            finally
                f.fiber_is_finished = true #fibers will restart if run is called after they finished!

                #Keeping a reference to the fiber will hold it in memory permanently
                f = null

        f = (Fiber run_fn)
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




child_process = require 'child_process'
tmp = require 'tmp'
Fiber = require 'fibers'