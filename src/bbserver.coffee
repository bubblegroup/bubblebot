bbserver = exports

bbserver.Server = class Server
    constructor: ->
        @root_command = new RootCommand()

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

        cloud = new clouds.AWSCloud()
        log_stream = cloud.get_bb_environment().get_log_stream('bubblebot', 'bubblebot_server')

        #Create the default log environment for the server
        logger = u.create_logger {
            log: log_stream.log.bind(log_stream)
            reply: -> throw new Error 'cannot reply: not in a conversation!'
            ask: -> throw new Error 'cannot ask: not in a conversation!'
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

    #Returns the list of admins.  Defaults to the owner of the slack channel.
    #TODO: allow this to be modified and saved in the db.
    get_admins: -> [@slack_client.get_slack_owner()]

    #Called by our slack client
    new_conversation: (user_id, msg) ->
        u.ensure_fiber =>
            context = u.get_context()
            context.user_id = user_id
            context.orginal_message = msg

            u.set_logger u.create_logger {
                log: log_stream.log.bind(log_stream)
                reply: @slack_client.reply.bind(@slack_client)
                ask: (msg, override_user_id) => @slack_client.ask override_user_id ? user_id, msg
                announce: @slack_client.announce.bind(@slack_client)
                report: @slack_client.report.bind(@slack_client)
            }
            try
                args = parse_command msg
                u.get_context().parsed_message = args
                @root_command.execute [], args
            catch err
                cmd = context.parsed_message ? context.orginal_message

                if err.reason = u.CANCEL
                    u.reply 'Cancelled: ' + cmd
                else if err.reason = u.USER_TIMEOUT
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



bbserver.CommandTree = class CommandTree
    constructor: (@subcommands) ->
        @subcommands = {}

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




bbserver.Command = class Command
    #See CommandTree::execute above
    execute: (prev_args, args) ->
        processed_args = []

        for param, idx in @params ? []
            if args[idx]?
                processed_args.push args[idx]
            else
                if param.default?
                    processed_args.push param.default
                else if param.required
                    if params.dont_ask
                        u.reply "Oops, we're missing some required information: " + param.name + '.  To run, say ' + prev_args.join(' ') + ' ' + @display_args()
                        return
                    else
                        processed_args.push u.ask "I need a bit more information.  What's the value for #{param.name}?"

        if @additional_params?
            processed_args.push args[@params?.length ? 0..]

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


#The initial command structure for the bot
class RootCommand extends CommandTree
    constructor: ->
        @commands = {}
        @commands.help = new Help(@root_command)
        @commands.env = new EnvTree()


    get_commands: ->
        return u.extend {}, @commands.env.get_commands(), @commands

#A command tree that lets you navigate environments
class EnvTree



bbserver.SHUTDOWN_ACK = 'graceful shutdown command received'


http = require 'http'
u = require './utilities'
slack = require './slack'
clouds = require './clouds'