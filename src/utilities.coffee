u = exports

#Creates a tarball out of the given directory and saves it to a temporary file.
#Returns the path to the temp file
u.create_tarball = (directory) ->
    tempfile = tmp.tmpNameSync()
    u.run_local "tar -cf #{tempfile} -C #{directory} ."
    return tempfile

u.run_local = (cmd, options = {}) ->
    {can_fail} = options
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


#Gets the global environment for the current fiber
u.get_context = ->
    if not Fiber.current?
        throw new Error 'No current fiber!'
    Fiber.current.current_context ?= {}
    return Fiber.current.current_context


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

    wait: ->
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
        throw new Error msg, {name}




child_process = require 'child_process'
tmp = require 'tmp'
Fiber = require 'fibers'