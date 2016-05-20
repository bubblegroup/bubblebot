bbserver = exports

bbserver.Server = class Server
    constructor: ->
        @root_command = new RootCommand()
        @db = new bbdb.BBDatabase()
        @_monitor = new monitoring.Monitor(this)

        @_registered_tasks = {}


    #should listen on port 8081 for commands such as shutdown
    start: ->
        server = http.createServer (req, res) =>
            res.write 'hi!!'
            res.end()

        server.listen 8080

        server2 = http.createServer (req, res) =>
            if req.url is '/shutdown'
                u.log 'Shutting down!'
                res.end bbserver.SHUTDOWN_ACK
                process.exit(1)
            else
                res.end 'unrecognized command'

        server2.listen 8081

        @slack_client = new slack.SlackClient(this)
        @slack_client.on 'new_conversation', @new_conversation.bind(this)

        log_stream = bbojbects.bubblebot_environment().get_log_stream('bubblebot', 'bubblebot_server')

        #Create the default log environment for the server
        logger = u.create_logger {
            log: log_stream.log.bind(log_stream)
            reply: @slack_client.reply.bind(@slack_client)
            message: @slack_client.message.bind(@slack_client)
            ask: (msg, override_user_id) => @slack_client.ask override_user_id ? u.context().user_id ? throw new Error 'no current user!', msg
            confirm: (msg, override_user_id) => @slack_client.confirm override_user_id ? u.context().user_id ? throw new Error 'no current user!', msg
            announce: @slack_client.announce.bind(@slack_client)
            report: @slack_client.report.bind(@slack_client)
        }

        u.set_default_logger logger

        u.announce 'Bubblebot is running!  Send me a PM for me info (say "hi" or "help")!  My system logs are here: ' + log_stream.get_tail_url() +

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

        #Tell the environments to start themselves up
        u.SyncRun =>
            @build_context()
            for environment in bbobjects.list_environments()
                @startup()

    #Returns the list of admins.  Defaults to the owner of the slack channel.
    #TODO: allow this to be modified and saved in the db.
    get_admins: -> [@slack_client.get_slack_owner()]

    #Loads pre-built tasks
    load_tasks: ->
        for k, v of tasks.builtin
            @register_task k, v

    monitor: (object) -> @_monitor object

    #registers a handler for a given task name
    register_task: (task, fn) ->
        @_registered_tasks[task] = fn

    #Schedules a task to run at a future time
    schedule_once: (timeout, task, data) ->
        if not @_registered_tasks[task]
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
            #exponential backoff if we are having trouble retrieving tasks
            task_engine_backoff = 5000
            while true
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
            u.log 'Beginning task run: ' + JSON.stringify(task_data)
            #Recurring tasks have the task name and data stored as sub-properties
            if task_data.properties.is_recurring_task
                task_fn = task_data.properties.task
                data = task_data.properties.data

            else
                task_fn = task_data.task
                data = task_data.properties

            if not @_registered_tasks[task_fn]
                throw new Error 'no task named ' + task_fn

            @build_context()
            @_registered_tasks[task_fn] data
            u.log 'Task completed successfully: ' + JSON.stringify(task_data)

        catch err
            #If the user cancels this task, or times out replying, reschedule it in 12 hours
            if err.reason in [u.CANCEL, u.USER_TIMEOUT]
                u.log 'User cancelled task, rescheduling: ' + JSON.stringify(task_data)
                @schedule_once task_data.task, task_data.properties, 12 * 60 * 60 * 1000
            else
                u.report 'Unexpected error running task ' + JSON.stringify(task_data) + '.  Error was: ' + (err.stack ? err)
        finally
            #We always want to make sure scheduled tasks get rescheduled
            if task_data.properties.is_recurring_task
                try
                    @schedule_once task_data.task, task_data.properties, task_data.properties.interval
                catch err
                    #if we can't reschedule it, we should not mark it as complete
                    u.db().release_task task_data.id
                    throw err

            #Mark the task as complete.
            u.db().complete_task task_data.id


    #Adds things to the current context.
    build_context: ->
        context = u.context()
        context.server = this
        context.schedule_once = @schedule_once.bind(this)
        context.db = @db

    #Called by our slack client
    new_conversation: (user_id, msg) ->
        u.ensure_fiber =>
            context = u.context()
            @build_context()
            context.user_id = user_id
            context.orginal_message = msg
            context.current_user = -> bbobjects.instance 'User', user_id

            try
                args = parse_command msg
                u.context().parsed_message = args
                @root_command.execute [], args
            catch err
                cmd = context.parsed_message ? context.orginal_message

                if err.reason is u.CANCEL
                    u.reply 'Cancelled: ' + cmd
                else if err.reason is u.USER_TIMEOUT
                    u.reply 'Timed out waiting for your reply: ' + cmd
                else
                    u.reply 'Sorry, I hit an unexpected error trying to handle ' + cmd + ': ' + err.stack ? err
                    if context.user_id not in @get_admins()
                        u.report 'User ' + @get_user_info(context.user_id).name + ' hit an unexpected error trying to run ' + cmd + ': ' + err.stack ? err



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
#  -Or overriding the get_subcommands method altogether
#
bbserver.CommandTree = class CommandTree
    constructor: (@subcommands) ->
        @subcommands ?= {}

        #Go through and look for functions that we want to expose as commands
        for k, v of this
            if typeof(v) is 'function' and @[k + '_cmd']?
               cmd = bbserver.build_command u.extend {run: v.bind(this), target: this}, @[k + '_cmd']
               @add k, cmd

    get_subcommands: -> @subcommands

    #Adds a subcommand
    add: (name, command) ->
        @subcommands[name] = command

    #Lists all available subcommands
    list: -> (k for k, v of @get_subcommands())

    #Gets the subcommand, returning null if not found
    get: (command) -> @get_subcommands()[command] ? null

    #Executes a command.  Previous args is the path through the outer tree to this tree,
    #and args are the forward navigation: args[0] should be a subcommand of this tree.
    execute: (prev_args, args) ->
        if args.length is 0
            msg = 'You entered ' + prev_args.join(' ') + ', which is a partial command... please enter remaining arguments (or "cancel" to abort). Options are: ' + (k for k, v of @get_subcommands()).join ', '
            args = parse_command msg

        first = args[0]
        subcommand = @get_subcommands()[first.toLowerCase()]

        if subcommand
            return subcommand.execute prev_args.concat(first), args[1..]

        if prev_args.length is 0
            help = 'help'
        else
            help = 'help ' + prev_args.join(' ')
        u.reply "I'm sorry, I don't know what #{prev_args.concat(first).join(' ')} means.  To see available commands, say '#{help}'"

    #Since this is a tree, we don't show the args, we show a "see 'help ' for more info" message
    display_args: (prev) -> "     (see 'help #{prev}' for more info)"

    get_help: (prev) ->
        res = []
        if prev is ''
            res.push 'The following commands are available:'
        else
            res.push "The command '#{prev} has the following sub-commands:\n'

        for name, command of @get_subcommands()
            full = prev + ' ' + name
            res.push full + ' ' + command.display_args(full)

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
#and optionally help_text, params and additional_params, which are passed
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
            if typeof options.reply is 'string'
                u.reply options.reply
            else
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
        if isNaN res
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
            processed_args.push args[@params?.length ? 0..]

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

        @run processed_args

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
        res = 'Usage:\n\n' + prev + ' ' + @display_args() + '\n\n' + (@help_text ? '')
        res += '\n'
        for param in @params
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
            res += '\n    #{additional_params.name} (list of strings)'
            if additional_params.help
                res += ': ' + additional_params.help
        return res




class Help extends Command
    additional_params: {name: 'commands'}

    help_text: "Displays help for the given command.  'help' by itself will display the
    list of top-level commands, 'help my_command my_subcommand' will display more information
    about that particular subcommand"

    constructor: (@tree) ->

    run: (commands) ->
        targ = @tree
        for command, idx in commands
            targ = @tree.get(command)
            if not targ?
                parent = commands[0...idx].join(' ')
                u.reply "We could not find the command '#{command}' under '#{parent}'.  Try 'help #{parent} to see what commands are available'
                return

        u.reply targ.get_help(commands.join(' '))
        return

class New extends Command
    help_text: 'Creates a new environment'
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



#The initial command structure for the bot
class RootCommand extends CommandTree
    constructor: ->
        @commands = {}
        @commands.help = new Help(@root_command)
        @commands.env = new EnvTree()
        @commands.new = new New()


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
            commands[id] = environment
        return commands




bbserver.SHUTDOWN_ACK = 'graceful shutdown command received'


http = require 'http'
u = require './utilities'
slack = require './slack'
bbdb = require './bbdb'
bbobjects = require './bbojbects'
tasks = require './tasks'
monitoring = require './monitoring'