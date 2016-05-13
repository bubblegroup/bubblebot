clouds = exports

#Statuses
INITIALIZED = 'initialized'

clouds.AWSCloud = class AWSCloud
    get_bbserver: ->
        instances = @get_bb_environment().get_instances_by_tag(config.get('bubblebot_role_tag'), config.get('bubblebot_role_bbserver'))

        #Clean up any bubblebot server instances not tagged as initialized -- they represent
        #abortive attempts at creating the server
        good = []
        for instance in instances
            if instance.get_tags()[config.get('status_tag')] isnt INITIALIZED
                u.log 'found an uninitialized bubbblebot server.  Terminating it...'
                instance.terminate()
            else
                good.push instance

        if good.length > 1
            throw new Error 'Found more than one bubblebot server!  Should only be one server tagged ' + config.get('bubblebot_role_tag') + ' = ' + config.get('bubblebot_role_bbserver')
        return good[0]

    #Returns the special bubblebot environment
    get_bb_environment: -> new BBEnvironment(this)

    create_bbserver: ->
        image_id = config.get('bubblebot_image_id')
        instance_type = config.get('bubblebot_instance_type')
        environment = @get_bb_environment()

        instance = environment.create_server image_id, instance_type, config.get('bubblebot_role_bbserver'), 'Bubble Bot'
        u.log 'bubblebot server created, waiting for it to ready...'
        instance.wait_for_ssh()

        u.log 'bubblebot server ready, installing software...'

        #Install node and supervisor
        command = 'node ' + config.get('install_directory') + '/' + config.get('run_file')
        software.supervisor('bubblebot', command, config.get('install_directory')).add(software.node('4.4.3')).install(instance)

        environment.tag_resource(instance.id, config.get('status_tag'), INITIALIZED)

        u.log 'bubblebot server has base software installed'

        return instance

    create_rdb: -> throw new Error 'not ipmlemented'

    #Returns the database instance we use to run bubblebot, creating it if it does not exist
    get_bbdb: ->
        instances = @get_bb_environment().get_dbs_by_tag(config.get('bubblebot_role_tag'), config.get('bubblebot_role_bbdb'))

        if instances.length > 1
            throw new Error 'Found more than one bubblebot db!  Should only be one server tagged ' + config.get('bubblebot_role_tag') + ' = ' + config.get('bubblebot_role_bbdb')
        else if instances.length is 1
            return good[0]

        #Did not find one, so create a new one
        instance_type = config.get('bbbdb_instance_type')
        environment = @get_bb_environment()

        instance.environment.create_rdb instancye_type, config.get('bubblebot_role_bbdb'), 'Bubble Bot'

        return instance

