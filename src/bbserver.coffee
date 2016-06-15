bbserver = exports

constants = require './constants'

#Schedule name for one-time tasks
ONCE = 'once'

bbserver.Server = class Server
    constructor: ->
        @root_command = new RootCommand(this)
        @_monitor = new monitoring.Monitor(this)

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
                        return res

                #Create the default log environment for the server
                u.set_default_loggers {
                    log: log_stream.log.bind(log_stream)
                    reply: wrap_in_log 'Reply', @slack_client.reply.bind(@slack_client)
                    message: wrap_in_log 'Message', @slack_client.message.bind(@slack_client)
                    ask: wrap_in_log 'Ask', (msg, override_user_id) => @slack_client.ask(override_user_id ? u.context().user_id, msg)
                    confirm: wrap_in_log 'Confirm', (msg, override_user_id) => @slack_client.confirm(override_user_id ? u.context().user_id ? throw new Error 'no current user!', msg)
                    announce: wrap_in_log 'Announce', @slack_client.announce.bind(@slack_client)
                    report: wrap_in_log 'Report', @slack_client.report.bind(@slack_client)
                    report_no_log: @slack_client.report.bind(@slack_client)
                }

                @build_context('initial_announcement')

                u.announce 'Bubblebot is running!  Send me a PM for more info (say *hi* or *help*)!  My system logs are here: ' + log_stream.get_tail_url() + '.  And my web interface is here: ' + @get_server_url()

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

                @create_sub_logger 'startup'

                #Make sure we have at least one user who is an admin
                @get_admins()

                #Make a list of each type that has a startup function
                for typename, cls of bbobjects
                    if (cls::) and typeof(cls::on_startup) is 'function'
                        u.log 'Startup: loading ' + typename + 's...'
                        for id in u.db().list_objects typename
                            u.log 'Startup: sending on_startup() to ' + id
                            try
                                bbobjects.instance(typename, id).on_startup()
                            catch err
                                u.report 'Error sending startup to ' + typename + ' ' + id + ': ' + (err.stack ? err)

                u.log 'Startup complete'

    #Starts a long operation on its own fiber
    run_fiber: (name, fn) ->
        u.SyncRun =>
            @build_context(name)
            sub_logger = @create_sub_logger name
            try
                fn()
            catch err
                #If the user cancels this task, or times out replying, just log it
                if err.reason in [u.CANCEL, u.USER_TIMEOUT]
                    u.log 'Operation cancelled: ' + err.reason

                #If the task was cancelled externally, just log it
                else if err.reason in u.EXTERNAL_CANCEL
                    u.uncancel_fiber()
                    u.log 'Operation cancelled externally'

                else
                    u.report 'Unexpected error running operation ' + name + '.  Error was:\n' + (err.stack ? err)  + '\n\nTranscript: ' + sub_logger.get_tail_url()

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
    #
    #Returns the new sublogger
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
        u.log 'Logs for ' + description + ': ' + log_stream.get_tail_url()
        u.set_logger 'log', log_stream.log.bind(log_stream)
        log_stream.log id + ' ' + description

        #Record that we created a new log stream in our list
        @get_sublogger_stream().log JSON.stringify {id, description}

        return log_stream

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

    #Loads pre-built task schedules
    load_tasks: ->
        for schedule_name, {interval, type, id, method, params} of tasks.schedules
            @schedule_recurring interval, schedule_name, type, id, method, params...


    monitor: (object) -> @_monitor.monitor object

    #Errors if we try to schedule a bad task
    _check_valid_schedule: (type, id, method) ->
        instance = bbobjects.instance(type, id)
        if not instance.exists()
            throw new Error 'trying to schedule a task on an instance that does not exist'
        if not instance[method]
            throw new Error 'Instance ' + String(instance) + ' does not have method ' + method

    #Schedules a task to run at a future time
    schedule_once: (timeout, type, id, method, params...) ->
        @_check_valid_schedule type, id, method
        u.db().schedule_task Date.now() + timeout, ONCE, {type, id, method, params}

    #Schedules a function to run on a regular basis
    #
    #If a task with the same schedule_name is already scheduled, does nothing
    schedule_recurring: (interval, schedule_name, type, id, method, params...) ->
        @_check_valid_schedule type, id, method
        u.db().upsert_task schedule_name, {interval, type, id, method, params}

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
        try
            #Extract the task data
            {interval, type, id, method, params} = task_data.properties
            schedule_name = task_data.task

            #build a human friendly name for the task
            if schedule_name is ONCE
                friendly = "(#{type} #{id}).#{method})"
            else
                friendly = schedule_name

            #Create the server context and a fresh sub-logger for running the task under
            @build_context('running task ' + friendly)
            u.log "Task started on fiber #{u.fiber_id()}: #{friendly}"
            @create_sub_logger "#{u.fiber_id()} Task #{friendly}"
            u.log 'Beginning task run: ' + JSON.stringify(task_data, null, 4)

            instance = bbobjects.instance(type, id)
            if not instance.exists()
                u.log 'Instance no longer exists, so aborting'
                return

            instance[method] params...

            u.log 'Task completed successfully'

        catch err
            #If the user cancels this task, or times out replying, reschedule it in 12 hours
            if err.reason in [u.CANCEL, u.USER_TIMEOUT]
                u.log 'User cancelled task, rescheduling: ' + JSON.stringify(task_data)
                u.db().schedule_task Date.now() + 12 * 60 * 60 * 1000, schedule_name, task_data.properties
            #If the task was cancelled externally, just log it
            else if err.reason in u.EXTERNAL_CANCEL
                u.uncancel_fiber()
                u.log 'Task cancelled externally: ' + JSON.stringify(task_data)
            else
                u.report 'Unexpected error running task ' + JSON.stringify(task_data) + '.  Error was: ' + (err.stack ? err)
        finally
            #We always want to make sure scheduled tasks get rescheduled
            if schedule_name isnt ONCE
                u.db().schedule_task Date.now() + task_data.properties.interval, schedule_name, task_data.properties

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
                sub_logger = @create_sub_logger u.fiber_id() + ' ' + current_user.name() + ' ' + msg
                link = sub_logger.get_tail_url()
                u.reply 'Logging transcript here: ' + link
                u.context().get_transcript = -> link

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
                else if err.reason is u.EXTERNAL_CANCEL
                    u.uncancel_fiber()
                    u.reply 'Cancelled (via the cancel cmd): ' + cmd
                else
                    u.reply 'Sorry, I hit an unexpected error trying to handle ' + cmd + ': ' + err.stack ? err
                    if context.user_id
                        current_user = bbobjects.instance('User', context.user_id)
                    if not current_user?.is_in_group(constants.ADMIN)
                        name = current_user?.name() ? '<no name, user_id: ' + context.user_id + '>'
                        u.report 'User ' + name + ' hit an unexpected error trying to run ' + cmd + ': ' + err.stack ? err

    graceful_shutdown: (no_restart) ->
        if no_restart
            u.announce 'A request to shut down bubblebot has been received.  Will shut down once everything else is stopped.  Will NOT automatically restart!'
        else
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
                if no_restart
                    msg = 'Shutting down bubblebot now!'
                    code = 0
                else
                    msg = 'Restarting bubblebot now!'
                    code = 1
                if u.current_user()
                    u.reply msg
                u.announce msg
                process.exit(code)
            else
                u.pause(500)



#Given a message typed in by a user, parses it as a bot command
parse_command = (msg) ->
    args = []

    #Remove *s since they can show up in copy-pastes
    msg = msg.replace(/\*/g, '')

    #Removes `s since they can show up in copy-pastes
    msg = msg.replace(/`/g, '')

    #Replace educated quotes with straight quotes
    msg = msg.replace(/“/g, '"').replace(/”/g, '"').replace(/‘/g, "'").replace(/’/g, "'")

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
                command_object = @[k + '_cmd']
                if typeof(command_object) is 'function'
                    command_object = command_object()

                #if we specify raw, we assume the function should be immediately called with
                #this, and the return result is a command or a command tree
                if command_object is 'raw'
                    cmd = v.call(this)
                else
                    cmd = bbserver.build_command u.extend {run: v.bind(this), target: this}, command_object
                @add k, cmd

    get_commands: -> @subcommands

    #Adds a subcommand
    add: (name, command) ->
        @subcommands[name] = command

    #Lists all available subcommands
    #
    #We return commands first and trees second.  We return commands that anyone
    #can run first.
    list: ->
        trees = []
        open_cmds = []
        cmds = []
        for k, v of @get_commands()
            if v instanceof CommandTree
                trees.push k
            else if v.groups is constants.BASIC
                open_cmds.push k
            else
                cmds.push k
        return [].concat open_cmds, cmds, trees

    #Gets the subcommand, returning null if not found
    get_command: (command) ->
        res = @get_commands()[command] ? null
        return res

    #Executes a command.  Previous args is the path through the outer tree to this tree,
    #and args are the forward navigation: args[0] should be a subcommand of this tree.
    execute: (prev_args, args) ->
        if args.length is 0
            prompt = 'You entered ' + prev_args.join(' ') + ', which is a partial command.\nPlease enter remaining arguments (or "cancel" to abort).\nOptions are:\n\n'
            options_table = []
            for name in @list()
                options_table.push [name, @get_command(name).help_string(true)]
            prompt += u.make_table options_table
            msg = u.ask prompt
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
        u.reply "I'm sorry, I don't know what #{prev_args.concat(first).join(' ')} means.  To see available commands, say *#{help}*"

    help_string: (short) ->
        help = @help ? ''
        if typeof(help) is 'function'
            help = help.apply this
        return help

    get_help: (prev) ->
        if prev is ''
            header = 'The following commands are available:\n\n'
        else
            header = "\n*#{prev}*\n\n#{@help_string()}\n\n*#{prev}* has the following sub-commands:\n\n"

        table = []
        for name in @list()
            command = @get_command(name)
            full = prev + ' ' + name
            table.push [full, command.help_string(true)]

        return header + u.make_table(table)

MAX_DEPTH = 4

#Renders JSON in a format designed to be viewed by a human over slack
bbserver.pretty_print = (obj) ->
    res = pretty_print(obj, 0)
    #if it has new lines, wrap it in a quote block, otherwise just return it
    if res.indexOf('\n') is -1
        return res
    else
        return '```' + res + '```'

#Tests if the object is simple; if so, returns a string, if not, returns null
pp_simple = (obj) ->
    if not obj?
        return 'null'
    if typeof(obj) in ['string', 'number', 'boolean']
        return String(obj)
    if obj instanceof Date
        return u.print_date obj

    return null

#Recursive helper function for bbserver.pretty_print
#
#If the response is multi-line, returns it indented to the specified level.
#If one line, just returns it.
pretty_print = (obj, indent) ->
    indent_string = (new Array(indent * 4)).join ' '

    #Handle the simple cases of things we can just display as is
    simple = pp_simple obj
    if simple?
        return simple

    #If we've defined a pretty print function on the object, use that
    if typeof(obj.pretty_print) is 'function'
        return obj.pretty_print(indent) ? 'null'

    if indent is MAX_DEPTH
        return '{..}'

    if Array.isArray obj
        #if everything in the array is simple, just list it
        all_simple = true
        for entry in obj
            if not pp_simple(entry)?
                all_simple = false
                break

        if all_simple
            return (pp_simple(entry) for entry in obj).join(', ')

        #otherwise, we're going to treat it as an object with numeric keys
        keys = [0...obj.length]
    else
        keys = Object.keys(obj)


    res = []
    for key in keys
        value = pretty_print(obj[key], indent + 1)
        #if it's one line, print it key: value
        if value.indexOf('\n') is -1
            res.push indent_string + key + ': ' + value
        #otherwise, print it key: on one line, and value on the next
        else
            res.push indent_string + key + ':\n' + value
    return res.join '\n'



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
                u.reply options.reply
                return

            if typeof(options.reply) is 'function'
                return u.reply options.reply.call options.target, res
                return

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
        if val in options
            result = val
        else
            result = do_cast param, u.ask feedback + "we're expecting one of: #{options.join(', ')}  " + prompt

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
            processed_args.push args[@params?.length ? 0..]

        #If we have non-command line questions defined, evaluate those and add those in
        if typeof(@questions) is 'function'
            next = @questions
            while next
                #Call the question-getter function bound to whatever the target of the command is,
                #and passing through all the args we have so far
                next = next.call @target, processed_args...
                if next?
                    processed_args.push do_cast next, u.ask next.help + (if next.type is 'list' then '  Options: ' + next.options().join(', ') else '')

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

        @run processed_args...

    #Checks to see if you have the right to run this command.  Returns a message if you
    #aren't, or nll if you are
    check_privilege: (processed_args) ->
        #figure out what groups are allowed to call this command
        groups = @groups

        #If groups is a function, call it
        if typeof(groups) is 'function'
            groups = groups.apply @target, processed_args

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

    help_string: (short) ->
        help = @help ? ''
        if typeof(help) is 'function'
            help = help()
        if short
            help = help.split('\n')[0]
        return help

    get_help: (prev) ->
        res = '\nUsage:\n\n*' + prev + '* ' + @display_args() + '\n\n' + @help_string()

        if @params?.length > 0 or @additional_params?
            res += '\n\n\n_Parameters_:\n\n'

        param_table = []
        for param in @params ? []
            if param.required
                default_info = 'required'
            else if param.default?
                default_info = 'optional, defaults to ' + param.default
            else
                default_info = 'optional'

            param_description = "(#{param.type ? 'string'}, #{default_info})"
            if param.help
                param_description += ': ' + param.help

            param_table.push [param.name, param_description]

        if @additional_params?
            param_description = '(list of strings)'
            if @additional_params.help
                param_description += ': ' + @additional_params.help
            param_table.push [@additional_params.name, param_description]

        return res + u.make_table(param_table)




class Help extends Command
    additional_params: {name: 'commands'}

    help: "Displays help for the given commands.\nWithout arguments, *help* will display the list of top-level commands.\n *help [my_command] [my_subcommand]...* will display more information about that particular subcommand."

    constructor: (@tree) ->

    run: (commands) ->
        targ = @tree
        for command, idx in commands
            targ = targ.get_command(command)
            if not targ?
                parent = commands[0...idx].join(' ')
                u.reply "We could not find the command *#{command}* under *#{parent}*.  Try *help #{parent}* to see what commands are available"
                return

        u.reply targ.get_help(commands.join(' '))
        return

    groups: constants.BASIC

class Hi extends Command
    help: 'Friendly salutation'

    run: ->
        u.reply 'Hi ' + u.current_user().name() + "!  I'm bubblebot.  Say *help* to me to learn more about what I can do!"

    groups: constants.BASIC

class New extends Command
    help: 'Creates a new environment'
    params: [
        {name: 'id', type: 'string', required: true, help:"The id of the new environment"}
        {name: 'template', type: 'string', required: true, help: "The environment template to use to build this environment.  Pass 'blank' to create an empty environment"}
        {name: 'type', type: 'list', required: true, help: 'What kind of environment this is', options: -> [bbobjects.PROD, bbobjects.QA, bbobjects.DEV]}
        {name: 'region', type: 'string', help: 'The AWS region to host this environment in.  Defaults to same as bubblebot.'}
        {name: 'vpc', type: 'string', help: 'The AWS VPC id to host this environment in.  Defaults to same as bubblebot.'}
    ]

    run: (id, template, type, region, vpc) ->
        if u.db().exists 'Environment', id
            u.reply 'An environment with id ' + id + ' already exists!'
            return
        if id is 'bubblebot'
            u.reply "Sorry, you cannot name an environment 'bubblebot'"
            return

        #fill in missing values from bubble bot environment
        bb_environment = bbobjects.bubblebot_environment()
        region ?= bb_environment.get_region()
        vpc ?= bb_environment.get_vpc()

        environment = bbobjects.instance 'Environment', id
        environment.create type, template, region, vpc

        u.reply 'Environment successfully created!'
        return

    groups: constants.BASIC

get_fiber_user = (fiber) ->
    if fiber.current_context.user_id
        return ' ' + bbobjects.instance('User', fiber.current_context.user_id).name()
    else
        return ''

get_fiber_display = (fiber) -> fiber.current_context?.original_message ? fiber.current_context?.name

get_full_fiber_display = (fiber) -> String(fiber._fiber_id) + ' ' + get_fiber_user(fiber) + ': ' + get_fiber_display(fiber)

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

        if all and anonymous > 0
            res.push 'in addition, there are ' + anonymous + ' anonymous fibers running'

        u.reply 'Currently running:\n' + res.join('\n')

    groups: constants.BASIC

#Command for listing recent loggers
class Logs extends Command
    help: 'Show recent logging streams'
    params: [
        {name: 'number', type: 'number', default: 5, help: 'The number of recent streams to show'}
    ]

    run: (number) ->
        server = u.context().server
        u.reply 'Master server logs: ' + server.get_server_log_stream().get_tail_url()
        res = ['Recent logs:']
        for {id, description, timestamp} in server.list_sub_loggers().reverse()[...number]
            logger = server.get_sub_logger(id)
            res.push u.print_date(new Date(timestamp)) + ' ' + description + ' ' + logger.get_tail_url()
        u.reply res.join('\n')

    groups: constants.BASIC

class Cancel extends Command
    help: 'Cancels running commands.\nWith no arguments, cancels all commands that you started.\nCan pass a command number to cancel a specific command.'
    params: [
        {name: 'command', type: 'number', help: 'The number of the specific command to cancel'}
    ]

    run: (command) ->
        #We don't want to cancel ourselves
        this_id = u.fiber_id()

        to_cancel = []
        for fiber in u.active_fibers
            if command
                if fiber._fiber_id is command and (fiber._fiber_id isnt this_id)
                    to_cancel.push fiber
            else
                if fiber.current_context?.user_id is u.current_user().id and (fiber._fiber_id isnt this_id)
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



class Shutdown extends Command
    constructor: (@server) ->

    help: 'Shuts bubblebot down.\nDefault is to do a graceful shutdown then restart it.'
    params: [
        {name: 'immediate', type: 'boolean', help: 'Does an immediate shutdown instead of a graceful shutdown'}
        {name: 'no restart', type: 'boolean', help: 'Tells supervisor not to restart bubblebot after exiting'}
    ]

    run: (immediate, no_restart) ->
        if immediate
            exit_code = if no_restart then 0 else 1
            msg = 'Doing an immediate shutdown with exit code ' + exit_code + ' in one second'
            u.reply msg
            u.announce msg
            setTimeout ->
                process.exit(exit_code)
            , 1000
        else
            u.reply 'Beginning a graceful shutdown...'
            @server.graceful_shutdown no_restart

    groups: constants.ADMIN

    dangerous: (immediate, no_restart) -> return immediate or no_restart



class Update extends Command
    constructor: (@server) ->

    help: 'Updates Bubblebot then restarts it'

    run: ->
        u.reply 'Updating...'

        #Clone our bubblebot installation to a fresh directory, and run npm install and npm test
        install_dir = 'bubblebot-' + Date.now()
        u.run_local('cd .. && git clone ' + config.get('remote_repo') + ' ' + install_dir)
        u.run_local("cd ../#{install_dir} && npm install", {timeout: 300000})
        u.run_local("cd ../#{install_dir} && npm test", {timeout: 300000})

        #Create a symbolic link pointing to the new directory, deleting the old one if it exits
        u.run_local('rm -rf ../bubblebot-old', {can_fail: true})
        u.run_local("mv $(readlink #{config.get('install_directory')}) ../bubblebot-old", {can_fail: true})
        u.run_local('unlink ' + config.get('install_directory'), {can_fail: true})
        u.run_local('ln -s ../' + install_dir + ' ' + config.get('install_directory'))

        u.reply 'Doing a graceful shutdown...'
        @server.graceful_shutdown()

    groups: constants.ADMIN




class Monitor extends Command
    constructor: (@server) ->

    help: 'Prints out monitoring information'
    params: [
        {name: 'show policies', type: 'boolean', help: 'If set, shows the monitoring policies instead of the current status'}
    ]

    run: (show_policies) ->
        if show_policies
            u.reply 'Policies:\n' + @server._monitor.policies()
        else
            u.reply @server._monitor.statuses()

    groups: constants.BASIC


class Sudo extends Command
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
        u.report 'Warning! ' + u.current_user() + ' just ran "sudo"'
        u.current_user().set 'sudo', Date.now()
        u.reply 'Okay, you now have temporary administrator privileges'

    groups: constants.TRUSTED


class Console extends Command
    help: 'Opens up an interactive console.'

    run: ->
        result = 'Console started, say "cancel" or "abort" to exit'
        while true
            input = u.ask result

            #Replace annoying characters
            input = input.replace(/“/g, '"').replace(/”/g, '"').replace(/‘/g, "'").replace(/’/g, "'")

            try
                result = eval(input)
                result = util.inspect(result)
            catch err
                result = err.stack

    groups: constants.ADMIN

#The initial command structure for the bot
class RootCommand extends CommandTree
    constructor: (@server) ->
        @commands = {}
        @commands.help = new Help(this)
        @commands.hi = new Hi()
        @commands.env = new EnvTree()
        @commands.new = new New()
        @commands.servers = new ServersTree()
        @commands.builds = new BuildsTree()
        @commands.ps = new PS()
        @commands.cancel = new Cancel()
        @commands.monitor = new Monitor(@server)
        @commands.users = new UsersTree()
        @commands.security_groups = new SecurityGroupsTree()
        @commands.logs = new Logs()
        @commands.update = new Update @server
        @commands.shutdown = new Shutdown @server
        @commands.console = new Console @server
        @commands.sudo = new Sudo()


    get_commands: ->
        #We put all the services in the default command namespace to save
        #typing.  If there's a name conflict, the command takes precedence
        services = {}
        for service in bbobjects.list_all('ServiceInstance')
            services[service.id] = service
        return u.extend {}, services, @commands


#A command tree that lets you navigate environments
class EnvTree extends CommandTree
    help: 'Shows all environments'

    get_commands: ->
        commands = {}
        for environment in bbobjects.list_environments()
            commands[environment.id.toLowerCase()] = environment
        return commands

#A command tree that lets you navigate servers
class ServersTree extends CommandTree
    help: 'Shows all servers'

    get_commands: ->
        commands = {}
        for instance in bbobjects.get_all_instances()
            commands[instance.id.toLowerCase()] = instance
        return commands

#A command tree that lets you navigate EC2Builds
class BuildsTree extends CommandTree
    help: 'Shows all builds'

    get_commands: ->
        commands = {}
        for instance in bbobjects.list_all 'EC2Build'
            commands[instance.id.toLowerCase()] = instance
        return commands

#A command tree that lets you navigate users
class UsersTree extends CommandTree
    help: 'Shows all users'

    get_commands: ->
        commands = {}
        for user in bbobjects.list_users()
            commands[user.name().toLowerCase()] = user
        return commands

class SecurityGroupsTree extends CommandTree
    help: 'Shows all user groups'

    get_commands: ->
        commands = {}

        #Make sure all the builtin ones exists in the database
        for groupname, description of bbobjects.BUILTIN_GROUP_DESCRIPTION
            group = bbobjects.instance('SecurityGroup', groupname)
            if not group.exists()
                group.create()

        for group in bbobjects.list_all 'SecurityGroup'
            commands[group.id.toLowerCase()] = group

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
util = require 'util'
config = require './config'