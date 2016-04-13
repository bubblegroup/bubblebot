clouds = exports

clouds.AWSCloud = class AWSCloud
    get_bbserver: ->
        instances = @get_bb_environment().get_instances_by_tag(config.get('bubblebot_role_tag'), config.get('bubblebot_role_bbserver'))
        if instances.length > 0
            throw new Error 'Found more than one bubblebot server!  Should only be one server tagged ' + config.get('bubblebot_role_tag') + ' = ' + config.get('bubblebot_role_bbserver')
        return instances[0]

    #Returns the special bubblebot environment
    get_bb_environment: -> new BBEnvironment()

    create_bbserver: ->
        image_id = config.get('bubblebot_image_id')
        instance_type = config.get('bubblebot_instance_type')
        environment = @get_bb_environment()

        instance = environment.create_server image_id, instance_type, config.get('bubblebot_role_bbserver'), 'Bubble Bot'

        #Install node and supervisor
        command = 'node ' + config.get('install_directory') + config.get('run_file')
        software.supervisor(command).add(software.node('4.4.4')).install(instance)

        return instance



class Environment
    constructor: (@name) ->
        if @name is 'bubblebot'
            throw new Error 'bubblebot is a reserved name, you cannot name an environment that'

    get_name: -> @name

    get_instances_by_tag: (key, value) ->

    get_key_name: ->

    #creates a new ec2 server in this environment
    create_server: (image_id, instance_type, role, name) ->
        keypair = @get_keypair()
        security_group = @get_webserver_security_group()


class Instance
    run: (command, {can_fail}) ->

    upload_file: (path, remote_dir) ->

    write_file: (data, remote_path) ->

    post_authenticated: (url, body) ->








#Special hard-coded environment that we use to run the bubble bot
class BBEnvironment extends Environment
    constructor: ->

    get_name: -> 'bubblebot'

    get_region: -> config.get('bubblebot_region')




config = require './config'
software = require './software'