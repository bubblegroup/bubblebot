bbserver = exports

constants = require './constants'

bbserver.Server = class Server
    constructor: ->
        @root_command = new RootCommand(this)
        @_monitor = new monitoring.Monitor(this)
        @_registered_tasks = {}

    _build_bbdb: ->
        #Make sure the database exists.  This will also set u.context().db
        bbobjects.get_bbdb_instance()
        if not u.context().db?
            throw new Error 'u.context().db is not set'

        #Get the service instance
        instance = bbobjects.bubblebot_environment().get_service('BBDBService')

        #Make sure it is fully upgraded
        if instance.version() isnt instance.codebase().get_latest_version()
            instance.deploy instance.codebase().get_latest_version(), false, 'Automatically upgrading BBDB'

        return u.context().db

    #should listen on port 8081 for commands such as shutdown
    start: ->
        u.SyncRun =>
            try
                @db = @_build_bbdb()

                server = http.createServer (req, res) =>
                    u.SyncRun =>
                        try
                            @build_context('http_request')
                            path = url.parse(req.url ? '').pathname.split('/')[1..]
                            if path[0] is 'logs'
                                @show_logs req, res, path[1...]

                            else if not path[0]
                                res.write '<html><head><title>Bubblebot</title></head><body><p>Welcome to Bubblebot!  <a href="' + @get_server_log_stream().get_tail_url() + '">Master server logs</a></p></body></html>'
                                res.end()
                            else
                                res.statusCode = 404
                                res.write "You have reached Bubblebot, but we don't recognize " + req.url
                                res.end()
                        catch err
                            res.statusCode = 500
                            res.write 'Error processing requests'
                            res.end()
                            u.report 'Error loading data from Cloudwatch: ' + (err.stack ? err)
                            return

                server.listen 8080

                server2 = http.createServer (req, res) =>
                    if req.url is '/shutdown'
                        res.end bbserver.SHUTDOWN_ACK
                        u.SyncRun =>
                            @build_context()
                            @graceful_shutdown()
                    else
                        res.end 'unrecognized command'

                server2.listen 8081

                @slack_client = new slack.SlackClient(this)
                @slack_client.on 'new_conversation', @new_conversation.bind(this)

                log_stream = @get_server_log_stream()

                #Also make this function write to the logger
                wrap_in_log = (name, fn) ->
                    return (args...) ->
                        u.log name + ': ' + String(args)
                        res = fn args...
                        if res
                            u.log name + ' response: ' + String(res)

                #Create the default log environment for the server
                u.set_default_loggers {
                    log: log_stream.log.bind(log_stream)
                    reply: wrap_in_log 'Reply', @slack_client.reply.bind(@slack_client)
                    message: wrap_in_log 'Message', @slack_client.message.bind(@slack_client)
                    ask: (msg, override_user_id) => wrap_in_log 'Ask', @slack_client.ask override_user_id ? u.context().user_id ? throw new Error 'no current user!', msg
                    confirm: (msg, override_user_id) => wrap_in_log 'Confirm', @slack_client.confirm override_user_id ? u.context().user_id ? throw new Error 'no current user!', msg
                    announce: wrap_in_log 'Announce', @slack_client.announce.bind(@slack_client)
                    report: wrap_in_log 'Report', @slack_client.report.bind(@slack_client)
                    report_no_log: @slack_client.report.bind(@slack_client)
                }

                @build_context('initial_announcement')

                u.announce 'Bubblebot is running!  Send me a PM for more info (say "hi" or "help")!  My system logs are here: ' + log_stream.get_tail_url() + '.  And my web interface is here: ' + @get_server_url()

                #Handle uncaught exceptions.
                #We want to report them, with a rate limit of 10 per 30 minutes
                rate_limit_count = 0
                rate_limit_on = false
                process.on 'uncaughtException', (err) =>
                    if rate_limit_on
                        return

                    rate_limit_count++
                    if rate_limit_count is 10
                        rate_limit_on = true
                        setTimeout ->
                            rate_limit_count = 0
                            rate_lmit_on = false
                        , 30 * 60 * 1000

                    message = 'Uncaught exception: ' + (err.stack ? err)
                    u.report message

                #Start up the task engine
                @load_tasks()
                setTimeout =>
                    @start_task_engine()
                , 10 * 1000
            catch err
                setTimeout ->
                    process.exit(0)
                , 1000

                #If we have an error during startup, we do NOT want to restart bubblebot
                msg = 'Error starting bubblebot server, permanently quitting.  Error is:\n' + (err.stack ? err)
                console.log '(DUPLICATE) ' + msg
                u.log msg

            #Tell the various objects to start themselves up
            u.SyncRun =>
                @build_context('startup')

                u.log 'Running startup'

                #Make sure we have at least one user who is an admin
                @get_admins()

                #Make a list of each type that has a startup function
                for typename, cls in bbobjects
                    if typeof(cls::startup) is 'function'
                        u.log 'Startup: loading ' + typename + 's...'
                        for id in u.db().list_objects typename
                            u.log 'Startup: sending startup() to ' + id
                            try
                                bbobjects.instance(typename, id).startup()
                            catch err
                                u.report 'Error sending startup to ' + typename + ' ' + id + ': ' + (err.stack ? err)

    #Returns the url bubblebot server is accessible at
    get_server_url: ->
        eip = bbobjects.bubblebot_environment().get_elastic_ip('bubblebot')
        if eip.get_instance()?.id isnt bbobjects.get_bbserver().id
            eip.switch bbobjects.get_bbserver()
        return 'http://' + eip.endpoint()

    #Gets the master server log stream
    get_server_log_stream: -> bbobjects.bubblebot_environment().get_log_stream('bubblebot', 'bubblebot_server')

    #Gets the stream we use to record the creation of new subloggers
    get_sublogger_stream: -> bbobjects.bubblebot_environment().get_log_stream('bubblebot', 'sublogger')

    #Creates a seperate logger for the current context
    create_sub_logger: (description) ->
        #create an id of the form timestamp_num
        ts = Date.now()
        if @_last_sl_ts is ts
            @_sl_id_count++
        else
            @_sl_id_count = 0
            @_last_sl_ts = ts

        id = ts + '_' + @_sl_id_count

        #Create the new logstream and set it as the default logger for this context
        log_stream = @get_sub_logger(id)
        u.set_logger 'log', log_stream.log.bind(log_stream)
        log_stream.log id + ' ' + description

        #Record that we created a new log stream in our list
        @get_sublogger_stream().log JSON.stringify {id, description}
        u.log 'Logs: ' + log_stream.get_tail_url()

    #Returns an array of {id, description, timestamp} of recently created subloggers
    list_sub_loggers: ->
        return (u.extend(JSON.parse(message), {timestamp}) for {message, timestamp} in @get_sublogger_stream().get_events())

    #Retrieves the sublogger with the given id
    get_sub_logger: (id) -> bbobjects.bubblebot_environment().get_log_stream('bubblebot', id)

    #Returns the URL for accessing logs
    get_logs_url: (env_id, groupname, name) -> @get_server_url() + "/logs/#{env_id}/#{groupname}/#{name}"

    #Displays logs
    show_logs: (req, res, path) ->
        [env_id, groupname, name] = path
        logstream = bbobjects.instance('Environment', env_id).get_log_stream(groupname, name)
        logstream.tail req, res


    #Returns an array of all the admin users.  If we don't have any admin users,
    #we set the owner of the slack channel as an admin user
    get_admins: ->
        #make sure we have a DB set in this context...
        u.context().db ?= @db

        admin_users = (user for user in bbobjects.list_all('User') when user.is_in_group(constants.ADMIN))
        if admin_users.length > 0
            return admin_users

        #No admins found, so make the slack owner an admin
        owner = bbobjects.instance 'User', @slack_client.get_slack_owner()
        owner.add_to_group constants.ADMIN
        return [owner]

    #Loads pre-built tasks and schedules
    load_tasks: ->
        for k, v of tasks.builtin
            @register_task k, v

        for schedule_name, {interval, task, data} of tasks.schedules
            @schedule_recurring schedule_name, interval, task, data


    monitor: (object) -> @_monitor object

    #registers a handler for a given task name
    register_task: (task, fn) ->
        @_registered_tasks[task] = fn

    #Schedules a task to run at a future time
    schedule_once: (timeout, task, data) ->
        if data.is_recurring_task
            task_fn = data.task
        else
            task_fn = task

        if not @_registered_tasks[task_fn]
            throw new Error 'task ' + task + ' is not registered!'
        u.db().schedule_task Date.now() + timeout, task, data

    #Schedules a function to run on a regular basis
    #
    #If a task with the same name is already scheduled, does nothing
    schedule_recurring: (schedule_name, interval, task, data) ->
        if not @_registered_tasks[task]
            throw new Error 'task ' + task + ' is not registered!'
        u.db().upsert_task schedule_name, {interval, is_recurring_task: true, task, data}


    #Executes scheduled tasks
    start_task_engine: ->
        @owner_id = null

        u.SyncRun =>
            @build_context('task engine')

            #exponential backoff if we are having trouble retrieving tasks
            task_engine_backoff = 5000
            while true
                #We don't want to run tasks if we are trying to shut down the server
                if @shutting_down
                    return

                try
                    {@owner_id, task_data} = u.db().get_next_task @owner_id

                    if task_data?
                        u.SyncRun =>
                            @run_task task_data

                    else
                        #No scheduled tasks right now, so pause for 10 seconds then try again
                        u.pause 10000

                    task_engine_backoff = 5000
                catch err
                    u.report 'Error trying to retrieve task: ' + (err.stack ? err)
                    u.pause task_engine_backoff
                    task_engine_backoff = task_engine_backoff * 2


    run_task: (task_data) ->
        external_cancel = false
        try
            @build_context('running task ' + JSON.stringify(task_data))
            u.log 'Beginning task run: ' + JSON.stringify(task_data)
            @create_sub_logger u.fiber_id() + ' task ' + JSON.stringify(task_data)

            #Recurring tasks have the task name and data stored as sub-properties
            if task_data.properties.is_recurring_task
                task_fn = task_data.properties.task
                data = task_data.properties.data

            else
                task_fn = task_data.task
                data = task_data.properties

            if not @_registered_tasks[task_fn]
                throw new Error 'no task named ' + task_fn

            @_registered_tasks[task_fn] data
            u.log 'Task completed successfully: ' + JSON.stringify(task_data)

        catch err
            #If the user cancels this task, or times out replying, reschedule it in 12 hours
            if err.reason in [u.CANCEL, u.USER_TIMEOUT]
                u.log 'User cancelled task, rescheduling: ' + JSON.stringify(task_data)
                @schedule_once 12 * 60 * 60 * 1000, task_data.task, task_data.properties
            #If the task was cancelled externally, just log it
            else if err.reason in u.EXTERNAL_CANCEL
                u.uncancel_fiber()
                u.log 'Task cancelled externally: ' + JSON.stringify(task_data)
            else
                u.report 'Unexpected error running task ' + JSON.stringify(task_data) + '.  Error was: ' + (err.stack ? err)
        finally
            #We always want to make sure scheduled tasks get rescheduled
            if task_data.properties.is_recurring_task
                @schedule_once task_data.properties.interval, task_data.task, task_data.properties

            #Mark the task as complete.
            u.db().complete_task task_data.id


    #Adds things to the current context.
    build_context: (name) ->
        context = u.context()
        context.name = name
        context.server = this
        context.schedule_once = @schedule_once.bind(this)
        context.db = @db

    #Called by our slack client
    new_conversation: (user_id, msg) ->
        u.ensure_fiber =>
            context = u.context()
            @build_context(msg)
            context.user_id = user_id
            context.original_message = msg
            context.current_user = -> bbobjects.instance 'User', user_id

            #If we are not in the basic group, we are not allowed to talk to the bot
            current_user = context.current_user()
            if not current_user.is_in_group constants.BASIC
                #if we are not in the ignore group, and we haven't been reported to the admins
                #yet, let them know we have a new user
                @_reported_new_users ?= {}
                if not @_reported_new_users[current_user.id]
                    @_reported_new_users[current_user.id] = true
                    if not current_user.is_in_group constants.IGNORE
                        u.report 'A new user is attempting to talk to bubblebot.  The user is ' + current_user + '.  Consider adding to a security group, such as ' + [constants.ADMIN, constants.TRUSTED, constants.BASIC, constants.IGNORE].join(', ')

                u.log 'Ignoring command from unauthorized user ' + current_user
                return

            #If the command is lengthy, it can create a sublogger...
            context.create_sub_logger = =>
                @create_sub_logger u.fiber_id() + ' ' + current_user.name() + ' ' + msg

            u.log current_user.name() + ': ' + msg

            try
                args = parse_command msg
                u.context().parsed_message = args
                @root_command.execute [], args
            catch err
                cmd = context.original_message

                if err.reason is u.CANCEL
                    u.reply 'Cancelled: ' + cmd
                else if err.reason is u.USER_TIMEOUT
                    u.reply 'Timed out waiting for your reply: ' + cmd
                else if err.reason in u.EXTERNAL_CANCEL
                    u.uncancel_fiber()
                    u.reply 'Cancelled (via the cancel cmd): ' + cmd
                else
                    u.reply 'Sorry, I hit an unexpected error trying to handle ' + cmd + ': ' + err.stack ? err
                    if context.user_id
                        current_user = bbobjects.instance('User', context.user_id)
                    if not current_user?.is_in_group(constants.ADMIN)
                        name = current_user?.name() ? '<no name, user_id: ' + context.user_id + '>'
                        u.report 'User ' + name + ' hit an unexpected error trying to run ' + cmd + ': ' + err.stack ? err

    graceful_shutdown: ->
        u.announce 'A request to restart bubblebot has been received.  Will restart once everything else is stopped...'

        my_id = u.fiber_id()

        @shutting_down = true

        #wait til there are no more named active fibers
        while true
            can_shutdown = true
            for fiber in u.active_fibers ? []
                if get_fiber_display(fiber) and fiber._fiber_id isnt my_id
                    can_shutdown = false
                    break
            if can_shutdown
                u.announce 'Restarting bubblebot now!'
                process.exit(1)
            else
                u.pause(2000)



#Given a message typed in by a user, parses it as a bot command
parse_command = (msg) ->
    args = []

    #Go through and chunk based on whitespace or on quotes
    while msg.length > 0
        while msg[0] is ' '
            msg = msg[1..]

        if msg[0] is '"'
            msg = msg[1..]
            endpos = msg.indexOf('"')
        else if msg[0] is "'"
            msg = msg[1..]
            endpos = msg.indexof("'")
        else
            endpos = msg.indexOf(' ')

        #if we don't see our chunk segment, go to the end of the string
        if endpos is -1
            endpos = msg.length

        args.push msg[...endpos]

        msg = msg[endpos + 1..]

    return args


#Base class for building a command tree: ie, a command that isn't directly
#executable but has a bunch of subcommands.
#
#Children can add commands by:
#  -calling add with an explicit command
#
#  -Adding a [function name]_cmd: {} argument for each function on the tree
#   we want to expose as a command, where {} is an object with arguments to pass
#   to bbserver.build_command.
#
#  -Or overriding the get_commands method altogether
#
bbserver.CommandTree = class CommandTree
    constructor: (@subcommands) ->
        @subcommands ?= {}

        #Go through and look for functions that we want to expose as commands
        for k, v of this
            if typeof(v) is 'function' and @[k + '_cmd']?
                #if we specify raw, we assume the function should be immediately called with
                #this, and the return result is a command or a command tree
                if @[k + '_cmd'] is 'raw'
                    @add k, v.call(this)
                else
                    cmd = bbserver.build_command u.extend {run: v.bind(this), target: this}, @[k + '_cmd']
                    @add k, cmd

    get_commands: -> @subcommands

    #Adds a subcommand
    add: (name, command) ->
        @subcommands[name] = command

    #Lists all available subcommands
    list: -> (k for k, v of @get_commands())

    #Gets the subcommand, returning null if not found
    get: (command) -> @get_commands()[command] ? null

    #Executes a command.  Previous args is the path through the outer tree to this tree,
    #and args are the forward navigation: args[0] should be a subcommand of this tree.
    execute: (prev_args, args) ->
        if args.length is 0
            msg = u.ask 'You entered ' + prev_args.join(' ') + ', which is a partial command... please enter remaining arguments (or "cancel" to abort). Options are: ' + (k for k, v of @get_commands()).join ', '
            args = parse_command msg

        first = args[0]
        subcommand = @get_commands()[first.toLowerCase()]

        if subcommand
            new_prev_args = prev_args.concat(first)
            new_args = args[1..]
            return subcommand.execute new_prev_args, new_args

        if prev_args.length is 0
            help = 'help'
        else
            help = 'help ' + prev_args.join(' ')
        u.reply "I'm sorry, I don't know what #{prev_args.concat(first).join(' ')} means.  To see available commands, say '#{help}'"

    #Since this is a tree, we don't show the args, we show a "see 'help ' for more info" message
    display_args: (prev) -> "                   _(see 'help #{prev}' for more info)_"

    get_help: (prev) ->
        res = []
        if prev is ''
            res.push 'The following commands are available:'
        else
            res.push "The command '#{prev}' has the following sub-commands:\n"

        for name, command of @get_commands()
            full = prev + ' ' + name
            res.push '*' + full + '* ' + command.display_args(full)

        return res.join('\n')


#Renders JSON in a format designed to be viewed by a human over slack
bbserver.pretty_print = (obj, indent = 0) ->
    indent_string = (new Array(indent * 4)).join ' '

    #Handle the simple cases of things we can just display as is
    if not obj?
        return indent_string + 'null'
    if typeof(obj) in ['string', 'number']
        return indent_string + obj

    #If we've defined a pretty print function on the object, use that
    if typeof(obj.pretty_print) is 'function'
        return obj.pretty_print()

    if Array.isArray obj
        #if everything in the array is simple, just list it
        all_simple = true
        for entry in obj
            if entry? and typeof(entry) not in ['string', 'number']
                all_simple = false
                break

        if all_simple
            return indent_string + obj.join(', ')

        #otherwise, we're going to treat it as an object with numeric keys
        keys = [0...obj.length]
    else
        keys = Object.keys(obj)


    res = []
    for key in keys
        res.push indent_string + key + ':\n'
        res.push bbserver.pretty_print(obj[key], indent + 1)
    return res.join ''



#Helper function for building new commands.  Options should contain run,
#and optionally help, params and additional_params, which are passed
#straight through to class Command below.
#
#Can also add a reply parameter.  If true, will reply with the return value (after
#running it through bbserver.pretty_print); if a string, will reply with that string.
bbserver.build_command = (options) ->
    cmd = new bbserver.Command()

    if options.reply
        old_run = options.run
        options.run = (args...) ->
            res = old_run args...
            if typeof(options.reply) is 'string'
                return u.reply options.reply

            if typeof(options.reply) is 'function'
                res = options.reply.call options.target, res
            message = bbserver.pretty_print(res)
            if message.indexOf('\n') is -1
                u.reply 'Result: ' + message
            else
                u.reply 'Result:\n' + message

    u.extend cmd, options
    return cmd


#Casts the value into the expected type (boolean, string, number).
#Re-queries the user if necessary.
#
#Either takes a string, or an object with details
bbserver.do_cast = do_cast = (param, val) ->
    if typeof(param) is 'string'
        param = {type: param}

    #Typing "go" always goes with the default value if there is one.
    if val is 'go' and param.default
        return param.default

    #If name is set, we use that in the feedback
    if param.name
        feedback = "Hey, for parameter '#{param.name}' you typed #{val}... "
    else
        feedback = "Hey, you typed #{val}..."
    prompt = "Try again? (Or type 'cancel' to abort)"

    if not param.type or param.type is 'string'
        result = String(val)
    else if param.type is 'boolean'
        if val.toLowerCase() in ['no', 'false']
            result =  false
        else if val.toLowerCase() in ['yes', 'true']
            result = true
        else
            result = do_cast param, u.ask feedback + "we're expecting no / false or yes / true, though.  " + prompt
    else if param.type is 'number'
        result = parseFloat val
        if isNaN result
            result = do_cast param, u.ask feedback + "we're expecting a number, though.  " + prompt
    else if param.type is 'list'
        options = param.options()
        if val in options()
            result = val
        else
            result = do_cast param, feedback + "we're expecting one of: #{options.join(', ')}  " + prompt

    else
        throw new Error "unrecognized parameter type for #{param.name}: #{param.type}"

    #If we have a validation function defined, run it
    if param.validate
        result = param.validate result

    return result


#Base class for building commands.  Children should add a run(args) method
bbserver.Command = class Command
    #See CommandTree::execute above
    execute: (prev_args, args) ->
        processed_args = []

        for param, idx in @params ? []
            if args[idx]?
                processed_args.push do_cast param, args[idx]
            else
                if param.default?
                    processed_args.push param.default
                else if param.required
                    processed_args.push do_cast param, u.ask "What's the value for #{param.name}?" + (if param.help then '  (' + param.help + ')' else '') + (if param.type is 'list' then '  Options: ' + param.options().join(', ') else '')

        #If we take an array of additional parameters, add that in from the remainder of the command line
        if @additional_params?
            processed_args.push args[@params?.length ? 0..]...

        #If we have non-command line questions defined, evaluate those and add those in
        if typeof(@questions) is 'function'
            next = @questions
            while next
                #Call the question-getter function bound to whatever the target of the command is,
                #and passing through all the args we have so far
                next = next.call @target, processed_args...
                if next?
                    processed_args.push do_cast next, u.ask next.help + (if param.type is 'list' then '  Options: ' + param.options().join(', ') else '')

                    #See if there is a next question
                    next = next.next


        #Store the command broken into the path and and arg components so that we
        #can see what we were called with
        u.context().command = {path: prev_args, args: processed_args}

        msg = @check_privilege processed_args
        if msg
            u.reply msg
            return

        if @sublogger
            u.context().create_sub_logger()

        @run processed_args

    #Checks to see if you have the right to run this command.  Returns a message if you
    #aren't, or nll if you are
    check_privilege: (processed_args) ->
        #figure out what groups are allowed to call this command
        groups = @groups

        #If groups is a function, call it
        if typeof(groups) is 'function'
            groups.apply @target, processed_args

        #if groups is as string, turn it into an array
        if typeof(groups) is 'string'
            groups = [groups]

        #if groups is null, assume a) that it requires admin permissions, and b) that it is dangerous
        if not groups?
            groups = [constants.ADMIN]
            dangerous = true

        #otherwise, see if dangerous is defined
        else
            dangerous = @dangerous
            if typeof(dangerous) is 'function'
                dangerous = dangerous.apply @target, processed_args

        #Go through the allowed groups and see if the user belongs to any of them
        current_user = u.current_user()
        found = false
        for group in groups
            if current_user.is_in_group group
                found = true
                break
        if not found
            return "Sorry, you apparently aren't authorized to do that"

        #If dangerous is true, make the user confirm
        if dangerous
            if not bbserver.do_cast 'boolean', u.ask 'This is a dangerous operation.  Are you sure you want to continue?'
                return 'Okay, aborting'

        #Indicate the user can proceed
        return null

    #For compatibility with the CommandTree interface... if we try to navigate into
    #a sub-command, it just returns the current command.
    get: -> this

    #Prints out a human-readable description of this commands' arguments
    display_args: ->
        disp = (param) ->
            if param.required
                return '<' + param.name + '>'
            else
                return '[' + param.name + ']'
        res = (disp(param) for param in @params ? []).join(' ')

        if @additional_params?
            res += '[' + @additional_params.name + '...]'

        return res

    get_help: (prev) ->
        res = 'Usage:\n\n*' + prev + '* ' + @display_args() + '\n\n' + (@help ? '')
        res += '\n'
        for param in @params ? []
            if param.required
                default_info = 'required'
            else if param.default?
                default_info = 'optional, defaults to ' + param.default
            else
                default_info = 'optional'

            res += "\n    #{param.name} (#{param.type}, #{default_info})"
            if param.help
                res += ': ' + param.help

        if @additional_params?
            res += "\n    #{additional_params.name} (list of strings)"
            if @additional_params.help
                res += ': ' + @additional_params.help
        return res




class Help extends Command
    additional_params: {name: 'commands'}

    help: "Displays help for the given command. 'help' by itself will display the list of top-level commands, 'help my_command my_subcommand' will display more information about that particular subcommand"

    constructor: (@tree) ->

    run: (commands) ->
        targ = @tree
        for command, idx in commands
            targ = targ.get(command)
            if not targ?
                parent = commands[0...idx].join(' ')
                u.reply "We could not find the command '#{command}' under '#{parent}'.  Try 'help #{parent}' to see what commands are available"
                return

        u.reply targ.get_help(commands.join(' '))
        return

    groups: constants.BASIC

class Hi extends Command
    run: ->
        u.reply 'Hi ' + u.current_user().name() + "!  I'm bubblebot.  Say 'help' to me to learn more about what I can do!"

    groups: constants.BASIC

class New extends Command
    help: 'Creates a new environment'
    params: [
        {name: 'id', type: 'string', required: true, help:"The id of the new environment"}
        {name: 'template', type: 'string', required: true, help: "The environment template to use to build this environment.  Pass 'blank' to create an empty environment"}
        {name: 'prod', type: 'boolean', required: true, help: 'if true, we treat this like production; we protect against accidentally deleting things, and we monitor for downtime'}
        {name: 'region', type: 'string', help: 'The AWS region to host this environment in.  Defaults to same as bubblebot.'}
        {name: 'vpc', type: 'string', help: 'The AWS VPC id to host this environment in.  Defaults to same as bubblebot.'}
    ]

    run: (id, template, prod, region, vpc) ->
        if u.db().exists name
            u.reply 'An environment with id ' + id + ' already exists!'
            return
        if name is 'bubblebot'
            u.reply "Sorry, you cannot name an environment 'bubblebot'"
            return

        #fill in missing values from bubble bot environment
        bb_environment = bbobjects.bubblebot_environment()
        region ?= bb_environment.get_region()
        vpc ?= bb_environment.get_vpc()

        environment = bbobjects.instance 'Environment', id
        environment.create prod, template, region, vpc

        u.reply 'Environment successfully created!'
        return

    groups: constants.BASIC

get_fiber_user = (fiber) ->
    if fiber.current_context.user_id
        return ' ' + bbobjects.instance('User', fiber.current_context.user_id).name()

get_fiber_display = (fiber) -> fiber.current_context?.original_message ? fiber.current_context?.name

get_full_fiber_display = (fiber) -> fiber._fiber_id + get_fiber_user(fiber) + ': ' + get_fiber_display(fiber)

#Command for listing all ongoing processes
class PS extends Command
    help: 'List currently running commands'
    params: [
        {name: 'all', type: 'boolean', help: 'If true, lists commands by other users, not just you'}
    ]

    run: (all) ->
        to_display = []
        anonymous = 0

        for fiber in u.active_fibers
            #only include fibers that have a name
            if get_fiber_display fiber
                if all or fiber.current_context.user_id is u.current_user().id
                    to_display.push fiber
            else
                anonymous++

        res = (get_full_fiber_display fiber for fiber in to_display)

        if all
            res.push anonymous + ' anonymous fibers'

        u.reply res.join('\n')

    groups: constants.BASIC

#Command for listing recent loggers
class Logs extends Command
    help: 'Show recent logging streams'
    params: [
        {name: 'number', type: 'number', default: 10, help: 'The number of recent streams to show'}
    ]

    run: (number) ->
        server = u.context().server
        u.reply 'Master server logs: ' + server.get_server_log_stream().get_tail_url()
        res = ['Recent logs:']
        for {id, description, timestamp} in server.list_sub_loggers().reverse()[...number].reverse()
            logger = server.get_sub_logger(id)
            res.push u.print_date(new Date(timestamp)) + ' ' + description + ' ' + logger.get_tail_url()
        u.reply res.join('\n')

    groups: constants.BASIC

class Cancel extends Command
    help: 'Cancels running commands.  By default, cancels all commands that you started'
    params: [
        {name: 'command', type: 'number', help: 'The number of the specific command to cancel'}
    ]

    run: (command) ->
        to_cancel = []
        for fiber in u.active_fibers
            if command
                if fiber._fiber_id is command
                    to_cancel.push fiber
            else
                if fiber.current_context?.user_id is u.current_user().id
                    to_cancel.push fiber

        res = (get_full_fiber_display fiber for fiber in to_cancel)

        for fiber in to_cancel
            u.cancel_fiber fiber

        u.reply 'Cancelled the following:\n\n' + res.join('\n')

    #Anyone can cancel their own commands, admins can cancel other users
    groups: (command) ->
        if not command
            return constants.BASIC

        for fiber in u.active_fibers
            if command
                if fiber._fiber_id is command
                    if fiber.current_context?.user_id isnt u.current_user().id
                        return constants.ADMIN

        return constants.BASIC




class Monitor extends Command
    constructor: (@server) ->

    help: 'Prints out monitoring information'
    params: [
        {name: 'show policies', type: 'boolean', help: 'If set, shows the monitoring policies instead of the current status'}
    ]

    run: (show_policies) ->
        if show_policies
            u.reply @server._monitor.policies()
        else
            u.reply @server._monitor.statuses()

    groups: constants.BASIC


class Sudo extends Command
    constructor: ->

    help: 'Temporarily grants adminstrative access... for use in emergencies if an adminstrator is not available'

    questions: -> {
        name: 'confirm'
        type: 'boolean'
        help: 'This will let you run dangerous commands for the next 30 minutes.  It should only be used if an administrator is not available.  Are you sure?'
    }

    run: (confirm) ->
        if not confirm
            u.reply 'Okay, aborting'
            return
        u.report 'Warning!  User ' + u.current_user() + ' just ran "sudo"'
        u.current_user().set 'sudo', Date.now()
        u.reply 'Okay, you now have temporary administrator privileges'

    groups: constants.TRUSTED

#The initial command structure for the bot
class RootCommand extends CommandTree
    constructor: (@server) ->
        @commands = {}
        @commands.help = new Help(this)
        @commands.hi = new Hi()
        @commands.env = new EnvTree()
        @commands.new = new New()
        @commands.servers = new ServersTree()
        @commands.ps = new PS()
        @commands.cancel = new Cancel()
        @commands.monitor = new Monitor(@server)
        @commands.users = new UsersTree()
        @commands.security_groups = new SecurityGroupsTree()
        @commands.logs = new Logs()


    get_commands: ->
        #We put all the environments in the default command namespace to save
        #typing.  If there's a name conflict, the command takes precedence, and the
        #user can explicitly say "env" to access the environment
        return u.extend {}, @commands.env.get_commands(), @commands


#A command tree that lets you navigate environments
class EnvTree extends CommandTree
    get_commands: ->
        commands = {}
        for environment in bbobjects.list_environments()
            commands[environment.id] = environment
        return commands

#A command tree that lets you navigate servers
class ServersTree extends CommandTree
    get_commands: ->
        commands = {}
        for instance in bbobjects.get_all_instances()
            commands[instance.id] = instance
        return commands

#A command tree that lets you navigate users
class UsersTree extends CommandTree
    get_commands: ->
        commands = {}
        for user in bbobjects.list_users()
            commands[user.id] = user
        return commands

class SecurityGroupsTree extends CommandTree
    get_commands: ->
        commands = {}

        #Make sure all the builtin ones exists in the database
        for groupname, description of bbobjects.BUILTIN_GROUP_DESCRIPTION[groupname]
            group = bbobjects.instance('SecurityGroup', groupname)
            if not group.exists()
                group.create()

        for group in bbobjects.list_all 'SecurityGroup'
            commands[group.id] = group

        #Creates a new security group
        commands.new = bbserver.build_command {
            run: (groupname, about) ->
                if groupname is 'new'
                    u.reply 'You are not allowed to name a group "new", sorry'
                    return
                new_group = bbobjects.instance('SecurityGroup', groupname)
                if new_group.exists()
                    u.reply 'Group ' + groupname + ' already exists'
                    return

                new_group.create about

            target: null

            params: [
                {name: 'groupname', required: true, help: 'The name of the group to create'}
                {name: 'about', required: true, help: 'A description of the purpose of this new group'}
            ]

            help: 'Creates a new security group'

            groups: constants.TRUSTED
        }

        return commands



bbserver.SHUTDOWN_ACK = 'graceful shutdown command received'


http = require 'http'
u = require './utilities'
slack = require './slack'
bbdb = require './bbdb'
bbobjects = require './bbobjects'
tasks = require './tasks'
monitoring = require './monitoring'
url = require 'url'