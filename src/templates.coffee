templates = exports

constants = require './constants'

#For each type of template, we define the functions we use to determine whether
#this is an instance of the template.  We use this for templates.verify and templates.list
interfaces =
    Environment: ['initialize']
    Service: ['codebase', 'get_tests', 'deploy', 'get_monitoring_policy']
    Codebase: ['canonicalize', 'ahead_of', 'ahead_of_msg', 'merge', 'debug_version']
    Test: ['run', 'codebase']
    EC2Build: ['codebase', 'verify', 'software', 'ami_software', 'termination_delay', 'default_size', 'get_replacement_interval', 'restart']


#For each interface, create an object for registering things that implement that interface
templates.templates = {}
for i_name, _ of interfaces
    templates.templates[i_name] = {}

#Given the name of a template interface, and the id of a template, confirms that this
#is a valid template id or throws an error
templates.verify = (iface, id) ->
    if not templates.templates[iface]
        throw new Error 'could not find interface ' + iface
    if not templates.templates[iface][id]
        throw new Error 'could not find ' + iface + ' with id ' + id
    for fn in interfaces[iface]
        if typeof(templates.templates[iface][id][fn]) isnt 'function'
            throw new Error 'id ' + id + ' is not a valid ' + iface + ' (missing ' + fn + ')'

#Adds the given template
templates.add = (iface, id, template) ->
    templates.templates[iface][id] = template
    templates.verify iface, id

#List the ids of all the registered templates that match this interface
templates.list = (iface) ->
    return (id for id, template of templates.templates[iface] ? throw new Error 'could not find interface ' + iface)

#Retrieves a template
templates.get = (iface, id) ->
    return templates.templates[iface][id]

#Extend this to build environment templates
templates.Environment = class Environment
    initialize: (environment) ->

    on_startup: -> #no-op

    describe_keys: (instance) -> {}

#A blank environment...
templates.add 'Environment', 'blank', new Environment()


#Code for allowing one deploy to interrupt another
deployment_interrupts = {}
INTERRUPT_REASON = 'another deploy interrupted'


#Extend this to build service templates
#
#Children should define the following:
# codebase() returns a codebase template
# get_tests() returns an array of tests
# replace: (instance) -> should replace the actual boxes with new boxes
# endpoint: -> should return the endpoint
#
templates.Service = class Service
    #Deploys a new version to this service.  Instance is the service instance, version
    #is the version to deploy, rollback should be true if this is a rollback.
    #
    #Deployment message allows hard-coded one; if absent (which it usually should be),
    #prompts the user for one
    deploy: (instance, version, rollback, deployment_message) ->
        u.log 'Running deploy on ' + instance.id + ' ' + version + ' ' + (rollback ? false) + ' ' + (deployment_message ? '')
        u.log 'Current version: ' + instance.version()
        codebase = @codebase()

        #Get the canonical version
        version = codebase.ensure_version version, instance.version()

        #Don't redeploy the version that is already deployed
        if instance.version() is version
            u.reply 'Version ' + instance.version() + ' is already live.  Consider the "replace" command if you want to replace the current servers'
            return

        #make sure this version is ahead of the current version
        if not @version_ahead(instance, version, rollback)
            msg = @codebase().ahead_of_msg version, instance.version()
            u.reply msg + ' .  To deploy anyway, run the deploy command again with the rollback parameter set to true (see help for details)'
            return

        #If rollback is true, confirm
        if rollback
            if not u.confirm 'You are doing a deploy with rollback set to true.  This means that we may be deploying an old version of the code!  Are you sure you want to do that?'
                u.reply 'Okay, aborting deploy'
                return false

        deployment_message ?= @get_deployment_message instance, version

        #Allows us to be interrupted by another deploy
        ensure_tested = =>
            #Let services optionally override requiring the tests to pass
            if instance.get 'service_always_skip_tests'
                u.reply 'We have disabled running the test suit on ' + instance
                
                return true
        
        
            my_fiber_id = u.fiber_id()
            deployment_interrupts[my_fiber_id] = {instance_id: instance.id, version, fiber: u.fiber()}
            try
                return @ensure_tested instance, version
            catch err
                #If we get interrupted by another deployment, and we are now no longer ahead of the prodcution
                #version, we can continue
                if err.reason isnt INTERRUPT_REASON
                    throw err
                else
                    u.uncancel_fiber()
                    if codebase.ahead_of version, instance.version()
                        throw new Error 'We got a deployment interrupt message, but we are ahead of the production version.  This should not happen.  Our version: ' + version + ', and service version: ' + instance.version()
                    return true
            finally
                delete deployment_interrupts[my_fiber_id]

        #Make sure it passes the tests
        if not ensure_tested()
            return

        #make sure that the version hasn't been updated in the interim
        if not rollback
            while instance.version() and not codebase.ahead_of(version, instance.version())
                #see if we can merge
                merged = codebase.canonicalize codebase.merge(version, instance.version())
                if not merged
                    u.reply "Your version is no longer ahead of the production version (#{instance.version()}) -- someone else probably deployed in the interim.  We tried to automatically merge it but were unable to, so we are aborting."
                    return
                else if merged is version
                    u.reply 'Someone already deployed this same version in the interim, so we are aborting'
                    return
                else
                    version = merged
                    u.reply "Your version was no longer ahead of the production version -- someone else probably deployed in the interim.  We were able to automatically merge it and will continue trying to deploy: " + merged
                    #Make sure the new version passes the tests
                    if not ensure_tested()
                        u.log 'Tests did not pass so aborting deploy'
                        return

        #Hook to add any custom logic for making sure the deployment is safe
        if @deploy_safe?
            if not @deploy_safe instance, version
                u.reply 'Aborting deployment'
                return

        #Okay, we have a tested version that is ahead of the current version, so deploy it and announce!
        instance.set 'version', version

        username = u.current_user()?.name() ? '<automated>'

        #update history...
        instance.add_history 'deploy', version, {username, deployment_message, rollback}

        #Notify re: the deployment
        u.announce 'Deployment to ' + instance + ': ' + username + ' deployed version ' + version + '.  We are rolling out the new version now.\nDeployment message: *' + deployment_message + '*' + (if rollback then '\nThis is a rollback!!' else '')
        u.reply 'Your deploy was successful! Rolling out the new version now...'

        #If this is not a rollback deploy, interrupt and have people follow the leader
        if not rollback

            #Interrupt anyone trying to deploy to the same service who isn't ahead of us
            for fiber_id, data of deployment_interrupts
                if data.instance_id is instance.id and not codebase.ahead_of(data.version, version)
                    u.cancel_fiber data.fiber, INTERRUPT_REASON

            #In case this is a leader, have all services do a quick check...
            if deployment_message isnt constants.LEADER_DEPLOY_MESSAGE
                u.log 'Calling check_leader on all service instances...'
                for service_instance in bbobjects.list_all('ServiceInstance')
                    do (service_instance) ->
                        u.log 'Checking leader for ' + service_instance
                        u.sub_fiber ->
                            u.run_silently ->
                                service_instance.check_leader()

        #Replace the existing servers with the new version
        u.retry 3, 30000, =>
            try
                instance.replace()
            catch err
                u.log 'Error trying to replace:\n' + err.stack
                throw err

        #Let the user know we are finished
        u.reply 'We are finished rolling out the new version'
        @on_deploy_finished?(instance, version, deployment_message)

    on_startup: -> #no op

    #Returns true if version is ahead of the currently deployed version (or rollback is true)
    version_ahead: (instance, version, rollback) ->
        current_version = instance.version()
        if not current_version
            return true
        if rollback
            return true
        return @codebase().ahead_of version, current_version

    #Queries the user for a deployment message
    get_deployment_message: (instance, version) ->
        messages = u.current_user().get('deployment_messages') ? {}

        #see if we have one for this service...
        saved = messages[instance.id]
        if saved
            #if it was for the same version, that's perfect
            if saved.version is version
                return saved.message

            #if the current version is ahead of its version, it means we succeeded in
            #deploying it already, so we should ignore it
            if instance.version() and @codebase().ahead_of instance.version(), saved.version
                saved = null

            #if the version we are deploying is not ahead of its version, it means
            #it is probably for another branch, so we should ignore it
            else if not @codebase().ahead_of version, saved.version
                saved = null


        get_message = ->
            if saved
                message = u.ask 'Please enter a message to describe this deployment, or type "go" to use the last message (' + saved.message + ')'
                if message.toLowerCase().trim() is 'go'
                    message = saved.message
            else
                message = u.ask 'Please enter a message to describe this deployment'

            if message.length < 4
                u.reply 'You typed a really short message... was it a typo?  Please try again...'
                return get_message()
            return message

        message = get_message()

        #add it to the saved messages for this user, and delete ones older than 24 hours
        messages[instance.id] = {version, message, timestamp: Date.now()}
        new_messages = {}
        for k, v of messages
            if v.timestamp > Date.now() - 24 * 60 * 60 * 1000
                new_messages[k] = v
        u.current_user().set 'deployment_messages', new_messages

        return message


    #Returns true if the version has passed all the test for this service.  If it has not,
    #tries to run the tests.
    ensure_tested: (instance, version) ->
        if not @is_tested version
            u.reply 'Version ' + version + ' has not been tested, running tests now...'
            @run_tests version
            if not @is_tested version
                u.log 'Ensure tested returning false because version ' + version + ' is not tested'
                return false

        return true

    #Returns true if this version has passed all the tests for this service
    is_tested: (version) ->
        #Allow the codebase to override the testing logic
        codebase = @codebase()
        if typeof(codebase.is_tested) is 'function'
            u.log 'Using codebase is_tested function'
            return codebase.is_tested version

        tests = @get_tests()
        for test in tests
            if not test.is_tested version
                u.log 'is_tested: returning false because test ' + test.id + ' says that version ' + version + ' is not tested'
                return false
        return true

    #Runs any not-passed test for this service against this version
    run_tests: (version) ->
        #Allow the codebase to override the testing logic
        codebase = @codebase()
        if typeof(codebase.run_tests) is 'function'
            return codebase.run_tests version

        tests = (test for test in @get_tests() when not test.is_tested version)
        u.reply 'Running the following tests: ' + tests.join(', ')
        for test in tests
            if not test.run version
                return



#Represents a service that is not managed by Bubblebot (but might be monitored by
#bubblebot)
#
#Children should define get_monitoring_policy and optionally endpoint
templates.ExternalService = class ExternalService extends Service
    codebase: -> new BlankCodebase()

    get_tests: -> []

    replace: -> #no-op

    deploy: (instance) -> instance.set 'version', 'blank'

    endpoint: -> 'external service'


#Represents a service that's an RDS-managed database
#
#Can instantiate directly, passing codebase id (which should be an RDSCodebase)
#and monitoring_policy which should be a (service_instance) -> policy function
#We automatically add the endpoint info to the policy function
templates.RDSService = class RDSService extends Service
    constructor: (@codebase_id, @monitoring_policy) ->

    codebase: -> templates.get 'Codebase', @codebase_id

    get_monitoring_policy: (service_instance) ->
        rdsinstance = @rds_instance service_instance
        if not rdsinstance
            return {monitor: false}

        policy = @monitoring_policy service_instance
        policy.monitor ?= true
        policy.frequency ?= 2000
        policy.endpoint ?= {
            protocol: 'postgres'
        }
        return policy


    #We don't actually replace database boxes since that's generally a bad idea,
    #but when we call replace we make sure they have an RDS instance are up to date with the latest version
    replace: (instance) ->
        version = instance.version()
        if not version?
            return

        if not @rds_instance(instance)
            @create_rds_instance(instance)

        @codebase().migrate_to @rds_instance(instance), version

    servers: (instance) -> [@rds_instance(instance)]

    #Gets the rds instance
    rds_instance: (instance) ->
        id = instance.get 'rds_instance'
        if id
            return bbobjects.instance 'RDSInstance', id

    wait_for_available: (instance) -> @rds_instance(instance).wait_for_available()

    get_sizing_params: (instance) ->
        sizing_options = @codebase().get_sizing instance
        #Overwrite the sizing with anything set on the service
        if instance.get('size')
            sizing_options.DBInstanceClass = instance.get('size')
        if instance.get('storage')
            sizing_options.AllocatedStorage = instance.get('storage')
        if instance.get('multi_az')
            sizing_options.MultiAZ = instance.get('multi_az')

        return sizing_options

    #Gets the parameters we use to create a new RDS instance
    #
    #NOTE: This will re-generate S3-stored credentials!
    get_params_for_creating_instance: (instance) ->
        permanent_options = @codebase().rds_options()

        sizing_options = @get_sizing_params instance

        #Most of the time we want to let the instance generate and store its own credentials,
        #but for special cases like BBDB we want to store the credentials in S3
        if @codebase().use_s3_credentials()
            MasterUsername = 'bubblebot'
            MasterUserPassword = u.gen_password()
            credentials = {MasterUsername, MasterUserPassword}

            #Save the credentials to s3 for future access
            bbobjects.put_s3_config @_get_credentials_key(instance), JSON.stringify(credentials)
        else
            credentials = null

        return {permanent_options, sizing_options, credentials}

    #Creates a new RDS instance for this service
    create_rds_instance: (instance) ->
        if instance.get 'rds_instance'
            throw new Error 'already have an instance'

        rds_instance = bbobjects.instance 'RDSInstance', instance.id + '-inst1'

        {permanent_options, sizing_options, credentials} = @get_params_for_creating_instance instance

        rds_instance.create instance, permanent_options, sizing_options, credentials

        instance.set 'rds_instance', rds_instance.id

    #Resizes this rds instance to match whatever the specified parameters are
    resize: (instance) ->
        rds_instance = @rds_instance(instance)
        config = rds_instance.get_configuration(true)

        new_sizing = @get_sizing_params instance

        changes = {}

        keys = ['AllocatedStorage', 'DBInstanceClass', 'BackupRetentionPeriod', 'MultiAZ', 'StorageType', 'Iops', 'outside_world_accessible']
        for key in keys
            current_state = config[key] ? '[unknown]'
            suggested_state = new_sizing[key]
            if u.confirm 'Change ' + key + '?  Currently, it is ' + current_state + ', and if we were re-creating this db, we would set it to ' + suggested_state
                type = if key in ['AllocatedStorage', 'BackupRetentionPeriod', 'Iops'] then 'number' else 'string'
                changes[key] = bbserver.do_cast type, u.ask 'Please enter new value for ' + key

        if not u.confirm 'Okay, we will make the following changes: ' + JSON.stringify(changes, null, 4) + '\nShall we proceed?'
            u.reply 'Okay, aborting'
            return

        unsafe_okay = u.confirm 'Are you okay with making changes that could cause downtime?'

        if instance.is_production() and unsafe_okay
            if not u.confirm 'This is a production instance.  You just said you were okay with downtime. Are you sure you know what you are doing?'
                u.reply 'Okay, aborting'
                return

        u.reply 'Initiating resize...'
        rds_instance.resize changes, unsafe_okay
        u.reply 'Resize complete'

    resize_cmd: ->
        sublogger: true
        help: 'Modifies an existing RDS instance'
        dangerous: (instance) -> instance.is_production()
        groups: (instance) -> if instance.is_production() then constants.ADMIN else constants.BASIC


    #Imports a given rds instance to be this services instance
    import: (instance, instance_id, MasterUsername, MasterUserPassword) ->
        if instance.get 'rds_instance'
            throw new Error 'already have an instance'

        rds_instance = bbobjects.instance 'RDSInstance', instance_id

        #Test the credentials
        try
            db_tester = new databases.Postgres {endpoint: -> rds_instance.endpoint {MasterUsername, MasterUserPassword}}
            db_tester.query 'SELECT 1'
        catch err
            u.reply 'Could not connect to DB with the given credentials:\n' + err.stack
            return

        rds_instance.create instance, null, null, null, 'just_write'

        rds_instance.set 'MasterUsername', MasterUsername
        rds_instance.set 'MasterUserPassword', MasterUserPassword

        instance.set 'rds_instance', rds_instance.id


    import_cmd:
        help: 'Imports a given rds instance to be this services instance'
        params: [
            {name: 'instance_id', required: true, help: 'The instance to import'}
            {name: 'username', required: true, help: 'The master username for this database'}
            {name: 'password', required: true, help: 'The master password for this database'}
        ]
        reply: 'Import successful'

    #S3 key we use to store credentials
    _get_credentials_key: (instance) -> 'RDSService_' + instance.id + '_credentials'

    get_s3_saved_credentials: (instance) -> JSON.parse bbobjects.get_s3_config @_get_credentials_key(instance)

    endpoint: (instance) ->
        rds_instance = @rds_instance(instance)
        if not rds_instance
            return null

        if @codebase().use_s3_credentials()
            credentials = @get_s3_saved_credentials instance
        else
            credentials = null
        return rds_instance.endpoint(credentials)

    #Before deploying, we want to confirm that the migration is reversibe.
    deploy_safe: (instance, version) ->
        if not @codebase().confirm_reversible @rds_instance(instance), version
            return false

        return true


    get_tests: -> @codebase().get_tests()

    #Performs a one-time upgrade operation that requires replacing the database.
    #
    #Codebase is responsible for defining the upgrade, and the replication function:
    #
    #-Should have a function with the same name as the upgrade, that takes (rds_instance, for_real)
    # The for-real parameter is so that we can do any additional testing against the upgraded database
    # that we wouldn't want to do for the actual migration
    #
    #-Should have a function prepare_for_replication(rds_instance) that we call on the current instance
    # before doing a clone.  prepare_for_replication should return an abort function that we can call if
    # something fails
    #
    #-Should have a function replicate(from_rds_instance, to_rds_instance, ready_cb) that does the replication,
    # and calls ready_cb(end_replication_cb) when it is sufficiently up to date to do the transfer.  end_replication_cb
    # is called by upgrade once replication should be (gracefully) shut off.
    #
    #-Should have a function get_upgrade_services(service_instance) that returns a list of services that need to be replaced on upgrade
    #
    upgrade: (instance, name, for_real) ->
        if for_real and instance.is_production()
            if not u.confirm 'Just to double-check, do you really want to run ' + name + ' on ' + instance + '?'
                u.reply 'Okay, aborting'
                return

        #Ensure that all the functions are defined
        codebase = @codebase()

        upgrade_fn = codebase[name]
        if typeof(upgrade_fn) isnt 'function'
            u.reply 'Could not find a function on the codebase named ' + name
            return

        prepare_for_replication = codebase.prepare_for_replication
        if typeof(prepare_for_replication) isnt 'function'
            u.reply 'Could not find a function on the codebase named prepare_for_replication'
            return

        replicate = codebase.replicate
        if typeof(replicate) isnt 'function'
            u.reply 'Could not find a function on the codebase named replicate'
            return

        get_upgrade_services = codebase.get_upgrade_services
        if typeof(get_upgrade_services) isnt 'function'
            u.reply 'Could not find a function on the codebase named get_upgrade_services'
            return

        current_rds_instance = @rds_instance(instance)

        #Pick a new id
        if for_real
            counter = (instance.get('rds_instance_counter') ? 1) + 1
            instance.set 'rds_instance_counter', counter
            new_id = instance.id + '-inst' + String(counter)
        else
            new_id = instance.id + '-test' + u.gen_password(5)

        u.reply 'Preparing for replication on ' + current_rds_instance
        abort = prepare_for_replication current_rds_instance
        if typeof(abort) isnt 'function'
            u.reply 'Warning: no abort function returned by prepare_for_replication; please abort manually if necessary'
            abort = null

        try
            #Create a clone
            u.reply 'Creating the clone: ' + new_id
            my_config = current_rds_instance.get_configuration(true)
            MultiAZ = my_config.MultiAZ
            DBInstanceClass = my_config.DBInstanceClass
            StorageType = my_config.StorageType

            Iops = my_config.Iops
            permanent_options = {cloned_from: current_rds_instance.id}
            outside_world_accessible = current_rds_instance.get 'outside_world_accessible'

            #We turn these off until the upgrade is complete
            old_MultiAZ = MultiAZ
            MultiAZ = false
            old_BackupRetentionPeriod = my_config.BackupRetentionPeriod
            #We have to set this afterwards -- can't be set in in the initial call

            sizing_options = {DBInstanceClass, MultiAZ, StorageType, outside_world_accessible, Iops}

            new_rds_instance = bbobjects.instance 'RDSInstance', new_id
            new_rds_instance.create instance, permanent_options, sizing_options

            u.reply 'Clone created, disabling backups'

            new_rds_instance.resize {BackupRetentionPeriod: 0}, true, 200

            u.reply 'Backups disabled, running upgrade functions'

            upgrade_fn new_rds_instance, for_real, instance

            u.reply 'Upgrade function complete, restoring BackupRetentionPeriod and MultiAZ'

            new_rds_instance.resize {BackupRetentionPeriod: old_BackupRetentionPeriod, MultiAZ: old_MultiAZ}, true, 2000

            u.reply 'Restoring BackupRetentionPeriod and MultiAZ complete, beginning replication..'

            replicate current_rds_instance, new_rds_instance, (end_replication_cb) =>
                u.sub_fiber =>
                    try
                        #Do the switch-over
                        if for_real
                            u.reply "Replication is up to date, so replacing #{current_rds_instance.id} with #{new_rds_instance.id}"
                            services = get_upgrade_services(instance)

                            #Do the switch in the database
                            instance.set 'rds_instance', new_rds_instance.id

                            u.reply 'Switched rds instances, now replacing ' + services.join(', ')

                            waiting_on = []
                            for svc in services
                                if svc
                                    waiting_on.push u.sub_fiber =>
                                        svc.replace()
                                        return null

                            #Wait for all the replaces to finish...
                            wait() for wait in waiting_on

                            u.reply "Okay, switch over is complete.  Gracefully terminating replication.  Please manually delete #{current_rds_instance.id} once replication finishes"

                            end_replication_cb()


                        #Not real, so just leave it running for a bit
                        else
                            services = get_upgrade_services(instance)

                            u.reply "Replication is up to date, but this is a test run.  If this was for real, we would switch the instances, then call replace on the following services: #{services.join(', ')}.  Leaving replication running for a minute..."
                            u.pause 60 * 1000
                            u.reply 'Okay, telling the process to stop replication, and calling abort() on the original'
                            end_replication_cb()

                            #Make sure don't call it in the error handler
                            if abort?
                                x = abort
                                abort = null
                                x()
                    catch err
                        u.reply 'Error on the switchover thread: ' + err.stack
                        u.reply 'Not automatically handling this: manually fix, please'

        catch err
            u.reply 'Error, so aborting replication...'
            abort?()

            throw err





    upgrade_cmd:
        help: 'Runs an upgrade function on the RDS instance by copying it, running the function, then replicating it and switching over'
        groups: constants.ADMIN
        dangerous: (instance) -> instance.is_production()
        params: [
            {name: 'name', required: true, help: 'The name of the upgrade to perform'}
            {name: 'for real', required: true, type: 'boolean', help: 'If for real, actually does the replacement operation, otherwise just creates and tests the replica'}
        ]
        sublogger: true


    #Copies this rds service to a new environment.  We create a physical clone of the database
    copy_to: (service, parent) ->
        new_service = parent.get_service service.template_id(), true

        u.log 'New rds service: ' + new_service.id

        rds_instance = @rds_instance service

        my_config = rds_instance.get_configuration(true)
        MultiAZ = my_config.MultiAZ
        DBInstanceClass = my_config.DBInstanceClass
        StorageType = my_config.StorageType
        Iops = my_config.Iops
        permanent_options = {cloned_from: rds_instance.id}
        outside_world_accessible = rds_instance.get 'outside_world_accessible'
        sizing_options = {DBInstanceClass, MultiAZ, StorageType, outside_world_accessible, Iops}

        copy_rds_instance = bbobjects.instance 'RDSInstance', new_service.id + '-inst1'
        u.log 'Beginning creation of database copy: ' + copy_rds_instance.id
        copy_rds_instance.create new_service, permanent_options, sizing_options

        u.log 'Copying complete.  Setting it as the database...'

        new_service.set 'rds_instance', copy_rds_instance.id

        u.log 'Setting the version...'

        new_service.set 'version', service.version()



#Represents a service that's a database managed by some other service
#
#Can instantiate directly:
#
#get_endpoint(service_instance) -- function that retrieves the database endpoint
#
#codebase id -- this should either be an RDSCodebase or one that implementes
#the migrate_to functions.
#
#monitoring_policy which should be a (service_instance) -> policy function
#We automatically add the endpoint info to the policy function
#
templates.DBService = class DBService extends Service
    constructor: (@get_endpoint, @codebase_id, @monitoring_policy) ->

    codebase: -> templates.get 'Codebase', @codebase_id

    get_monitoring_policy: (service_instance) ->
        endpoint = @get_endpoint(service_instance)
        if not endpoint
            return {monitor: false}

        policy = @monitoring_policy service_instance
        policy.monitor ?= true
        policy.frequency ?= 2000
        policy.endpoint ?= {
            protocol: 'postgres'
        }
        return policy

    #We don't actually replace database boxes since that's generally a bad idea,
    #but when we call replace we make sure it is up to date with the latest version
    replace: (instance) ->
        version = instance.version()
        if not version?
            return

        @codebase().migrate_to @get_fake_box(instance), version

    #Returns a fake RDS instance that we can pass to things that support it.  This is a
    #hack to work around the fact that I built RDS support before generic database support.
    #At some point, should refactor so that we go in the other direction
    get_fake_box: (instance) => return {
        endpoint: => @endpoint instance

        #We need this so that migration manager will work.  We currently only support postgres
        get_configuration: -> {
            Engine: 'postgres'
        }
    }


    #We don't manage the underlying box, so this returns null
    servers: (instance) -> []


    endpoint: (instance) -> @get_endpoint instance

    #Before deploying, we want to confirm that the migration is reversibe.
    deploy_safe: (instance, version) ->
        if not @codebase().confirm_reversible @get_fake_box(instance), version
            return false

        return true

    get_tests: -> @codebase().get_tests()



#Implements the switcher interface for having the endpoint change on deploys
null_switcher = (service_instance) ->
    return {
        #Return the public dns of the active instance
        endpoint: -> @get_instance()?.get_public_dns()

        #Switch is a no-op, since nothing needs to be updated
        switch: -> null

        #We just return whatever instance the service says should be active
        get_instance: -> service_instance.template().get_active_instance(service_instance)

    }


#Base class for services that have a single box.  They take a template,
#an array of tests, and a switcher function that takes the service instance
#and returns the switcher that controls where traffic is routed
#
#If switcher is null, we don't keep the endpoint constant -- instead, we just
#replace the box
templates.SingleBoxService = class SingleBoxService extends templates.Service
    constructor: (@build_id, @test_ids, @switcher, @monitoring_policy, quick_deploy) ->
        @switcher ?= null_switcher
        
        #If we pass in a quick deploy function, set it up so it gets passed the version
        #and the ec2instance
        if quick_deploy
            @quick_deploy = (instance, version) ->
                ec2instance = @get_active_instance(instance)
                quick_deploy ec2instance, version
                #normally this gets set on building a new server, so we have to update it here
                ec2instance.set 'software_version', version
                

    #Retrieve the ec2build object for this service
    ec2build: -> bbobjects.instance 'EC2Build', @build_id

    ec2build_cmd: 'raw'

    codebase: -> @ec2build().codebase()

    get_monitoring_policy: (instance) ->
        ec2instance = @get_active_instance(instance)
        if not @monitoring_policy
            throw new Error 'service ' + instance + ' does not have a monitoring policy'
        policy = @monitoring_policy instance
        if not policy
            throw new Error 'service ' + instance + ' monitoring policy returned null'
        policy.endpoint ?= {}
        policy.endpoint.host = ec2instance?.get_address()
        return policy

    get_tests: -> (bbobjects.instance 'Test', id for id in @test_ids)

    endpoint: (instance) -> @switcher(instance).endpoint()

    #Returns the ec2 instance that is currently live
    get_active_instance: (instance) ->
        id = instance.get('active_instance')
        if not id
            return null
        return bbobjects.instance('EC2Instance', id)

    set_active_instance: (instance, ec2instance) ->
        #ensure bbdb is reachable before attempting the switch
        instance.get 'active_instance'

        try
            @switcher(instance).switch ec2instance
            instance.set 'active_instance', ec2instance.id
        catch err
            server = u.context().server
            u.SyncRun 'ensure_switcher_correct', =>
                server.build_context()
                @ensure_switcher_correct instance
            throw err


    on_startup: (instance) ->
        super()
        @ensure_version_deployed(instance)

        server = u.context().server

        ensure_switcher = =>
            u.SyncRun 'ensure_switcher', =>
                try
                    server.build_context()

                    #Handle the case of the instance being deleted while this is running
                    if not instance.exists()
                        return

                    @ensure_switcher_correct(instance)
                catch err
                    u.report 'Error in ensure_switcher_correct:\n' + err.stack
                setTimeout ensure_switcher, 5 * 60 * 1000

        ensure_switcher()


    ensure_switcher_correct: (instance, attempts = 0) ->
        switcher_instance = @switcher(instance).get_instance()
        db_instance = @get_active_instance(instance)
        if db_instance and db_instance.id isnt switcher_instance?.id
            if attempts > 2
                u.report 'SWITCHER STILL BROKEN AFTER 3 RETRIES, GIVING UP FOR NOW'
                return

            else
                u.report 'Switcher mismatch for ' + instance + '; in database: ' + db_instance + ' and in switcher: ' + switcher_instance + '.  Attempting to fix..'
                @switcher(instance).switch db_instance
                u.report 'Tried to fix switcher, confirming...'
                u.pause 2000
                @ensure_switcher_correct instance, attempts + 1

        #If we reported a problem, report that we fixed the problem
        else if attempts > 0
            u.report 'Switcher fixed'


    ensure_switcher_correct_cmd:
        help: 'Ensures that this services switcher is pointing at the correct box'
        reply: 'Okay, ensured that it is correct'
        groups: constants.BASIC

    #Ensures that the version we've set is actually what's deployed
    ensure_version_deployed: (instance) ->
        #make sure that our instance matches our version
        version = instance.version()
        if version
            active_version = @get_active_instance(instance)?.get('software_version')
            if active_version isnt version
                u.announce "#{instance} has a version mismatch: should be #{version} but is #{active_version}.  About to replace it..."
                u.context().server.run_fiber "Replacing #{instance}", instance.replace.bind(instance)


    servers: (instance) -> [@get_active_instance(instance)]

    replace: (instance) ->
        build = @ec2build()
        size = @get_size(instance)

        #Create the new server
        u.announce 'Building a replacement server for ' + instance
        current_version = instance.version()
        new_ec2instance = build.build instance, size, String(instance), current_version

        #If someone deployed a new version in the interim, abort this
        if current_version isnt instance.version()
            return

        #See if there is an old server
        old_ec2instance = @get_active_instance(instance)

        #Make sure that the instance is ready to be put into production
        build.pre_make_active new_ec2instance, instance

        #Perform the switch
        @set_active_instance instance, new_ec2instance
        try
            #Notify the new box that it is active
            build.make_active new_ec2instance
        catch err
            u.report 'Switched service ' + instance + ' to point to ' + new_ec2instance.id + ', but make_active failed!'
            u.report 'Error was: ' + err.stack ? err
            u.report 'Reverting to old instance (' + old_ec2instance.id + ') and terminating new instance'
            @set_active_instance instance, old_ec2instance
            new_ec2instance.terminate()
            return

        #Begin the graceful shutdown process for the old instance, if there is one
        if old_ec2instance
            build.graceful_shutdown old_ec2instance
        u.announce new_ec2instance + ' is now the active server for ' + instance

        #Double-check to make sure we are still in a consistent state
        @ensure_version_deployed(instance)

    #Gets the size of the box for this service
    get_size: (instance) ->
        size = instance.get 'size'
        size ?= @ec2build().default_size(instance)
        return size

    get_size_cmd: ->
        help: 'Gets the size of the box for this service'
        reply: true
        groups: constants.BASIC

    #Sets the size of the box for this service
    set_size: (instance, new_size) ->
        valid_sizes = @ec2build().valid_sizes(instance)
        if new_size not in valid_sizes
            u.reply 'Cannot set size ' + new_size + ': should be one of ' + valid_sizes.join(', ')
            return
        instance.set 'size', new_size

    set_size_cmd: ->
        params: [{name: 'new_size', type: 'string', required: true}]
        help: 'Sets the size of the box for this service'
        reply: 'Size successfully set'
        groups: constants.BASIC
        dangerous: (instance) -> instance.is_production()

#Base class for codebases
templates.Codebase = class Codebase
    debug_version: (version, default_version) -> return 'Not a valid version: ' + version

    #If this version is not valid, prompts the user for a valid one
    ensure_version: (version, default_version) ->
        canonical = @canonicalize version, default_version
        if not canonical
            #if there is no current user, abort
            if not u.current_user()
                u.expected_error @debug_version version, default_version
            msg = @debug_version(version, default_version) + '\nPlease enter a valid version (or type "cancel" to abort)'
            return @ensure_version u.ask(msg), default_version
        else
            return canonical


#Implements the codebase interface using git.  Should pass in a git repo as in github.coffee
templates.GitCodebase = class GitCodebase extends Codebase
    constructor: (@repo) ->

    canonicalize: (version) -> return @repo.resolve_commit version

    debug_version: (version) -> return 'Could not find commit ' + version + ' in ' + @repo

    ahead_of: (first, second) -> return @repo.ahead_of first, second

    ahead_of_msg: (first, second) ->
        if not @repo.ahead_of first, second
            return 'Commit ' + first + ' is not ahead of ' + second
        throw new Error 'it is ahead of! ' + first + ', ' + second

    merge: (base, head) ->
        res = @repo.merge base, head
        if res.success
            return res.commit
        else
            return null

    pretty_print: (version) -> @repo.display_commit version

#Implements the codebase interface using multiple git repositories.  A version is defined
#as a dash-separated list of commits in the order that the repos are passed in to the constructor.
#
#You can omit a commit like so when calling canonicalize: commit1 or -commit2 instead of commit1-commit2,
#assuming that canonicalize is called with a default version that is used to fill in the blanks.
templates.MultiGitCodebase = class MultiGitCodebase extends Codebase
    constructor: (@repos, @get_default_version) ->

    canonicalize: (version, default_version) ->
        commits = version.split('-')
        results = []
        for repo, idx in @repos
            commit = commits[idx]?.trim()
            if not commit and default_version
                commit = default_version.split('-')[idx]
            canonical = repo.resolve_commit commit
            #if any commit can't be resolved, the overall version can't be resolved so return null
            if not canonical?
                return null
            results.push canonical

        return results.join '-'

    debug_version: (version, default_version) ->
        if String(version).indexOf('-') is '-1'
            format_string = ('[commit ' + i + 1 for repo, i in @repos).join('-')
            return 'Bad version: '  + version + '.  Format should be ' + format_string + ' (hyphen-seperated)'
        commits = version.split('-')
        for repo, idx in @repos
            commit = commits[idx]?.trim()
            if not commit and default_version
                used_default = true
                commit = default_version.split('-')[idx]
            else
                used_default = false
            if not commit
                return 'No commit given for ' + String(repo) + ', and we do not have a default version in this context'
            canonical = repo.resolve_commit commit
            if not canonical
                return 'Could not find commit ' + commit + ' in ' + String(repo) + ' (this was from the default version: ' + default_version + ')'

        throw new Error 'debug_version could not figure out what was wrong with ' + version

    #True if each version is ahead of each other version
    ahead_of: (first, second) ->
        first = first.split('-')
        second = second.split('-')
        for repo, idx in @repos
            f = first[idx]
            s = second[idx]
            if not repo.ahead_of f, s
                return false
        return true

    ahead_of_msg: (first, second) ->
        first = first.split('-')
        second = second.split('-')
        for repo, idx in @repos
            f = first[idx]
            s = second[idx]
            if not repo.ahead_of f, s
                return 'Commit ' + f + ' is not ahead of commit ' + s + ' in repo ' + repo
        throw new Error 'is ahead of! ' + first + ' -- ' + second

    merge: (base, head) ->
        base = base.split('-')
        head = head.split('-')
        results = []
        for repo, idx in @repos
            res = repo.merge base[idx], head[idx]
            if not res.success
                return null
            results.push res.commit
        return results.join('-')

    pretty_print: (version) ->
        version = version.split('-')
        return (repo.display_commit version[idx] for repo, idx in @repos).join('\n')

#Returns [codebase_id (string), migration (number), digest (string)]
extract_rds_version_pieces = (version) ->
    [codebase_id, migration, digest] = String(version).split('/')
    migration = parseInt migration
    return [codebase_id, migration, digest]

#Returns an RDSCodebase version
join_rds_version_pieces = (codebase_id, migration, digest) -> codebase_id + '/' + String(migration) + '/' + (digest ? 'x')

#Represents a set of schema migrations for an RDS managed database
#
#Children should implement:
#  rds_options
#  get_sizing
#  get_migrations
#  get_rollbacks
#  get_additional_tests
#
templates.RDSCodebase = class RDSCodebase extends Codebase
    #Version should be [codebase id]/[migration #]/digest
    canonicalize: (version) ->
        [codebase_id, migration, digest] = extract_rds_version_pieces version
        if codebase_id isnt @get_id()
            return null
        if not @get_migration_data(version)
            return null
        digest = @get_migration_digest version
        return join_rds_version_pieces codebase_id, migration, digest

    debug_version: (version) ->
        if String(version).indexOf('/') is -1
            return 'Version should be [codebase id]/[migration #]'
        [codebase_id, migration, digest] = extract_rds_version_pieces version
        if codebase_id isnt @get_id()
            return 'Codebase id ' + codebase_id + ' does not match this codebase: ' + @get_id()
        if String(parseInt(migration)) is migration
            return 'Bad migration: ' + migration + '.  Should be an integer.'
        if not @get_migration_data(version)
            return 'Could not find migration ' + migration
        throw new Error 'could not figure out what is wrong with version ' + version

    #returns [codebase_id (string), migration (number)], and throws an error
    #if codebase_id is wrong
    _extract_pieces: (version) ->
        [codebase_id, migration] = extract_rds_version_pieces version
        if codebase_id isnt @get_id()
            throw new Error 'codebase mismatch: is ' + codebase_id + ', should be ' + @get_id()
        return [codebase_id, migration]

    #Retrieves the id of this codebase.  We need to search the templates to find it..
    get_id: ->
        for id in templates.list('Codebase')
            if templates.templates['Codebase'][id] is this
                return id
        throw new Error 'could not find this codebase... make sure you call templates.add on it'

    ahead_of: (first, second) ->
        [codebase_id1, migration1] = @_extract_pieces(first)
        [codebase_id2, migration2] = @_extract_pieces(second)

        #make sure they are the same codebase...
        if codebase_id1 isnt codebase_id2
            return false

        #make first is >= second
        if migration1 < migration2
            return false

        return true

    ahead_of_msg: (first, second) ->
        [codebase_id1, migration1] = @_extract_pieces(first)
        [codebase_id2, migration2] = @_extract_pieces(second)

        #make sure they are the same codebase...
        if codebase_id1 isnt codebase_id2
            return "These two versions represent different codebases! #{codebase_id1} vs #{codebase_id2}."

        #make first is >= second
        if migration1 < migration2
            return "Migration #{migration1} is not >= #{migration2}"

        throw new Error "it is ahead of"

    #The only merge we allow is fast-forward merges
    merge: (base, head) ->
        if @ahead_of head, base
            return head
        return null

    pretty_print: (version) ->
        [codebase_id, migration] = @_extract_pieces(version)
        description = @get_migration(version).description
        return "#{codebase_id} migration #{migration}: #{description}"

    #Returns the digest for the given migration.  This is so that if migration data changes,
    #the version will have a different hash component, forcing us to re-run tests
    get_migration_digest: (version) ->
        hash = crypto.createHash('sha256')
        #add the forward migration
        hash.update @get_migration_data(version) ? ''
        #and add the rollback
        hash.update @get_migration_data(version, true) ? ''
        return hash.digest 'hex'

    #Gets the data for this migration.  If rollback is true, returns the rollback instead
    #of the migration
    get_migration_data: (version, rollback) ->
        #Otherwise, get it from the migration array
        [codebase_id, migration] = @_extract_pieces(version)
        if rollback
            return @get_rollbacks()[migration]
        else
            return @get_migrations()[migration]

    #Returns true if this version has a rollback defined
    has_rollback: (version) -> @get_migration_data(version, true)

    #Returns the most up-to-date version of this codebase
    get_latest_version: ->
        version = join_rds_version_pieces @get_id(), @get_migrations().length - 1
        return @canonicalize version

    #Returns true if upgrading the given rds_instance to the given version is reversible.
    #If not reversible, will ask the user to confirm that it is okay to migrate anyway.
    #
    #If we are doing a rollback, but we can't, will warn the user and abort
    confirm_reversible: (rds_instance, version) ->
        [codebase_id, new_migration] = @_extract_pieces(version)

        current_migration = @get_installed_migration rds_instance, codebase_id
        if new_migration is current_migration
            return true

        #If this is a rollback, check to see if we can actually roll it back
        if new_migration < current_migration
            start = current_migration
            end = new_migration + 1
            for migration in [start..end]
                if not @get_rollbacks()[migration]
                    u.reply 'Cannot roll back to version ' + version + ' because migration # ' + migration + ' is not reversible'
                    return false
            return true

        #If we have never applied this to this DB instance before, no need to confirm,
        #because this is the initial creation of the DB instance, so it doesn't
        #matter if it is not reversible
        if current_migration is -1
            return true

        start = current_migration + 1
        end = new_migration
        #See if it is reversible
        reversible = true
        for migration in [start..end]
            #If we have a migration without a rollback, this is not reversible.
            if not @get_rollbacks()[migration] and migration > 0
                reversible = false

        if reversible
            return true

        msg = "This migration is NOT reversible... we do not have rollbacks defined for every migration we are applying (#{start} to #{end}).  Are you sure you want to continue?"
        return u.confirm msg


    #Performs the migration on the given instance.
    migrate_to: (rds_instance, version) ->
        [codebase_id, new_migration] = @_extract_pieces(version)

        current_migration = @get_installed_migration rds_instance, codebase_id

        #If it's already correct, no need to do anything
        if new_migration is current_migration
            return

        #See if this is a forward migration
        if new_migration > current_migration
            start = current_migration + 1
            end = new_migration
            for migration in [start..end]
                @apply_migration rds_instance, codebase_id, migration

        #Otherwise, it is a rollback
        else
            start = current_migration
            end = new_migration + 1
            for migration in [start..end]
                @apply_rollback rds_instance, codebase_id, migration

    #Returns the number of the currently installed migration for this codebase
    get_installed_migration: (rds_instance, codebase_id) ->
        if not rds_instance?
            return -1
        migration_manager = @get_migration_manager(rds_instance)
        return migration_manager.get_migration(codebase_id)

    #Given an RDS instance, gets the migration table object
    get_migration_manager: (rds_instance) ->
        engine = rds_instance.get_configuration().Engine
        if not migration_managers[engine]
            throw new Error 'We do not currently support database of type ' + engine
        return new migration_managers[engine] rds_instance

    #Applies the given migration # to the rds instance
    apply_migration: (rds_instance, codebase_id, migration) ->
        migration_data = @get_migration_data join_rds_version_pieces(codebase_id, migration)

        @get_migration_manager(rds_instance).apply codebase_id, migration, migration_data

    #Applies the given rollback # to the rds instance
    apply_rollback: (rds_instance, codebase_id, migration) ->
        rollback_data = @get_migration_data join_rds_version_pieces(codebase_id, migration), true
        if not rollback_data
            throw new Error 'Cannot apply rollback ' + migration + ': not reversible'

        @get_migration_manager(rds_instance).rollback codebase_id, migration, rollback_data


    get_tests: ->
        tests = [].concat @get_additional_tests()
        #The final test is always trying it to see if it runs without errors, and if so
        #saving it to S3 so that it's locked down
        tests.push bbobjects.instance 'Test', 'RDS_migration_try'
        return tests

    #This should generally be false.  If true, we will store the credentials in S3 instead
    #of in the bubblebot database.
    use_s3_credentials: -> false

    #Creates a fresh RDS instance for running tests against.  If migration is null,
    #installs the latest migration... if a specific number, installs through that
    #migration (-1 means don't run any).
    #
    #If sizing_options is null, creates the smallest possible instance... can pass in sizing
    #to create larger instances for tests that depend on instance size
    #
    #If cloned_from, clones the test instance from the given id, rather than
    #creating it from scratch.  (This will use the cloned database's engine / engine version,
    #storage amount, and backup retention period)
    create_test_instance: (migration, sizing_options, cloned_from) ->
        migration ?= @get_migrations().length - 1
        sizing_options ?= @get_test_sizing_options()

        #Create a new instance with a random id
        environment = bbobjects.get_default_qa_environment()
        rds_instance = bbobjects.instance 'RDSInstance', 'test-' + u.gen_password()
        rds_options = @rds_options()
        if cloned_from
            rds_options.cloned_from = cloned_from
        rds_instance.create environment, rds_options, sizing_options

        #Migrate the instance to the given migration
        @migrate_to rds_instance, join_rds_version_pieces @get_id(), migration

        return rds_instance

    #Returns the default sizing options for test instances: ie, as cheap as possible
    #(and publicly accessible to make debugging easier)
    get_test_sizing_options: -> {
        AllocatedStorage: 5
        DBInstanceClass: 'db.t2.micro'
        BackupRetentionPeriod: 0
        MultiAZ: false
        StorageType: 'standard'
        PubliclyAccessible: true
    }

    #Returns a string that represents the state of the database's schema.  Used for
    #things like confirming that a rollback returned the database to the same
    #state as before
    capture_schema: (rds_instance) -> @get_migration_manager(rds_instance).capture_schema()

    #Compares two schema created by capture schema: returns null if they are equivalent,
    #or a string error message if not.
    compare_schema: (rds_instance, s1, s2) -> @get_migration_manager(rds_instance).compare_schema(s1, s2)


#Represents an RDSCodebase where the migrations are stored in an external git repository.
#
#We expect inheritors to define @repo(), @commit() and @folder_path() functions.  @repo() should return
#an object with the same interface as github.Repo, and @folder_path() should return an array
#of folder names within the repository to a folder that has 0.sql, 1.sql, 0_rollback.sql, 1_rollback.sql, etc.
#@commit() should return the commit / branch to use, which should probably be the latest deployed version,
#master, or similar.
#
#We support a simple templating language for including one file within another.  Lines that
#start with "--INCLUDE filename" will be replaced with that filename
#
#Inheritors should also define the following (same as RDSCodebase inheritors):
#  rds_options
#  get_sizing
#  get_additional_tests
templates.GithubRDSCodebase = class GithubRDSCodebase extends templates.RDSCodebase
    #Retrieves the contents of the github folder that contains our migrations.
    #
    #Returns a {filename: blob_sha} mapping.
    list_folder: ->
        repo = @repo()
        commit = @commit()
        path = @folder_path()

        tree = repo.get_tree commit
        for piece in path
            found = false
            for entry in repo.list tree
                if entry.path is piece
                    if entry.type isnt 'tree'
                        throw new Error 'Expected a folder but got a ' + entry.type + ' for ' + piece + ' in ' + path.join('/')
                    found = tree
                    tree = entry.sha
                    break
            if not found
                throw new Error 'Could not find component ' + piece + ' in ' + path.join('/')

        res = {}
        for entry in repo.list tree
            if entry.type is 'blob'
                res[entry.path] = entry.sha
        return res


    #Used by RDSCodebase to get the array of migrations
    get_migrations: ->
        contents = @list_folder()

        num = @_get_max_migrations contents

        return (@_build_migration contents, String(i) + '.sql' for i in [0...num])

    #Used by RDSCodebase to get the array of rollbacks
    get_rollbacks: ->
        contents = @list_folder()

        num = @_get_max_migrations contents

        return (@_build_migration contents, String(i) + '_rollback.sql' for i in [0...num])

    #Given the contents of our folder and a filename, builds a migration from that filename
    _build_migration: (contents, filename) ->
        repo = @repo()

        #Implement an include templating language
        INCLUDE = '--INCLUDE'

        process_line = (line) ->
            if line[0...INCLUDE.length] is INCLUDE
                filename = line[INCLUDE.length..].trim()
                file = process_file filename
                if not file?
                    return 'ERROR COULD NOT PROCESS INCLUDE ' + filename
                else
                    return file
            else
                return line

        process_file = (filename) ->
            sha = contents[filename]
            if not sha
                return null
            return (process_line line for line in repo.get_blob(sha).split('\n')).join('\n')

        return process_file filename

    #Find number of migrations we have
    _get_max_migrations: (contents) ->
        num = 0
        while contents[String(num) + '.sql']
            num++
        return num


#Represents multiple independent database codebases, managed in github, and run on the same
#database.
#
#Versions look like "codebase1_version-codebase2_version"
#
#Constructor takes a an array of GithubRDSCodebases
templates.GithubMultiRDSCodebase = class GithubMultiRDSCodebase extends Codebase
    constructor: (@codebases) ->

    canonicalize: (version) ->
        if not version?
            return null
        versions = version.split('-')
        res = []
        for codebase, idx in @codebases
            canon = codebase.canonicalize versions[idx]
            if not canon?
                return null
            res.push canon
        return res.join('-')

    debug_version: (version) ->
        versions = version.split('-')
        if versions.length isnt @codebases.length
            return 'Need to provide ' + @codebases.length + ' versions, seperated by dashes'

        for codebase, idx in @codebases
            canon = codebase.canonicalize versions[idx]
            if not canon?
                return codebase.debug_version versions[idx]

        throw new Error 'GithubMultiRDSCodebase: could not figure out what is wrong with version ' + version


    ahead_of: (first, second) ->
        first_versions = first.split('-')
        second_versions = second.split('-')

        for codebase, idx in @codebases
            if not codebase.ahead_of first_versions[idx], second_versions[idx]
                return false

        return true

    ahead_of_msg: (first, second) ->
        first_versions = first.split('-')
        second_versions = second.split('-')

        for codebase, idx in @codebases
            if not codebase.ahead_of first_versions[idx], second_versions[idx]
                return codebase.ahead_of_msg first_versions[idx], second_versions[idx]

        throw new Error 'GithubMultiRDSCodebase: is ahead of'

    #The only merge we allow is fast-forward merges
    merge: (base, head) ->
        if @ahead_of head, base
            return head
        return null

    pretty_print: (version) ->
        versions = version.split('-')
        return (codebase.pretty_print versions[idx] for codebase, idx in @codebases).join(', ')

    #Returns the most up-to-date version of this codebase
    get_latest_version: ->
        return (codebase.get_latest_version() for codebase in @codebases).join('-')

    #Returns true if upgrading the given rds_instance to the given version is reversible.
    #If not reversible, will ask the user to confirm that it is okay to migrate anyway.
    #
    #If we are doing a rollback, but we can't, will warn the user and abort
    confirm_reversible: (rds_instance, version) ->
        versions = version.split('-')

        for codebase, idx in @codebases
            if not codebase.confirm_reversible rds_instance, versions[idx]
                return false

        return true

    #Performs the migration on the given instance.
    migrate_to: (rds_instance, version) ->
        versions = version.split('-')

        for codebase, idx in @codebases
            codebase.migrate_to rds_instance, versions[idx]

    #We don't return any tests.  Instead, we override the is_tested and run_tests
    #methods
    get_tests: -> []

    #A version is tested if all its sub-versions are tested
    is_tested: (version) ->
        versions = version.split('-')

        for codebase, idx in @codebases
            tests = codebase.get_tests()
            for test in tests
                if not test.is_tested versions[idx]
                    return false

        return true

    #Runs any not-passed test for this service against this version
    run_tests: (version) ->
        versions = version.split('-')

        for codebase, idx in @codebases
            tests = (test for test in codebase.get_tests() when not test.is_tested versions[idx])
            for test in tests
                if not test.run versions[idx]
                    return

    #This should generally be false.  If true, we will store the credentials in S3 instead
    #of in the bubblebot database.
    use_s3_credentials: -> false




databases = require './databases'

migration_managers = {}
migration_managers.postgres = class PostgresMigrator extends databases.Postgres
    #Given a codebase id, returns the number of the current migration (or -1 if we have
    #never applied one)
    get_migration: (codebase_id) ->
        @ensure_migration_table_exists()
        return @_get_migration this, codebase_id

    #Helper for get_migration -- trans should either be this class to call without transaction,
    #or a transaction to call with it
    _get_migration: (trans, codebase_id) ->
        result = trans.query "SELECT migration FROM bubblebot.migrations WHERE codebase_id = $1", codebase_id
        return result.rows[0]?.migration ? -1

    #Runs the given migration data, updating the migration table to be the given migration.
    #
    #Will throw an error if the current migration number is not migration - 1
    apply: (codebase_id, migration, migration_data) ->
        if not migration_data
            throw new Error 'missing migration data: ' + codebase_id + ' ' + migration + ' ' + migration_data

        @ensure_migration_table_exists()

        @transaction (t) =>
            #Acquire an exclusive lock on the migrations table
            t.query "LOCK TABLE bubblebot.migrations"

            #check that we are ready to run it
            current = @_get_migration t, codebase_id
            if current isnt migration - 1
                throw new Error "trying to apply migration #{migration} but we are at #{current}"

            #Run the migration
            u.log 'Applying migration ' + codebase_id + ' ' + migration + ':\n' + migration_data
            t.query migration_data

            #Update the migration table

            #Can't do an upsert b/c we need to support postgres 9.4
            #query = "INSERT INTO bubblebot.migrations (codebase_id, migration) VALUES ($1, $2) ON CONFLICT (codebase_id) DO UPDATE SET migration = $2"

            query = "SELECT 1 FROM bubblebot.migrations WHERE codebase_id = $1"
            res = t.query query, codebase_id
            if res.rows.length > 0
                query = "UPDATE bubblebot.migrations SET migration = $2 WHERE codebase_id = $1"
            else
                query = "INSERT INTO bubblebot.migrations (codebase_id, migration) VALUES ($1, $2)"

            u.log 'Updating migration table:\n' + query
            t.query query, codebase_id, migration
            u.log 'Migration successful'


    #Runs the given rollback, updating the migration table to be migration - 1.  Throws
    #an error if the current migration number is not migration.
    rollback: (codebase_id, migration, rollback_data) ->
        if not rollback_data
            throw new Error 'missing rollback data: ' + codebase_id + ' ' + migration + ' ' + rollback_data


        @ensure_migration_table_exists()

        @transaction (t) =>
            #Acquire an exclusive lock on the migrations table
            t.query "LOCK TABLE bubblebot.migrations"

            #check that we are ready to run it
            current = @_get_migration t, codebase_id
            if current isnt migration
                throw new Error "trying to roll back migration #{migration} but we are at #{current}"

            #Run the migration
            u.log 'Applying rollback ' + codebase_id + ' ' + migration + ':\n' + rollback_data
            t.query rollback_data

            #Update the migration table
            query = "UPDATE bubblebot.migrations SET migration = $2 WHERE codebase_id = $1"
            t.query query, codebase_id, migration - 1

    #Checks to see if the migration schema / table exists in the database, and creates them
    #if they don't.
    ensure_migration_table_exists: ->
        #If it exists, we are done
        exists_query = "SELECT 1 FROM information_schema.tables WHERE table_schema = 'bubblebot' AND table_name = 'migrations'"
        result = @query exists_query
        if result.rows[0]
            return

        #Otherwise, create it in a transaction
        @transaction (t) =>
            #Do a lock to make sure no one else is doing this...
            t.query 'select pg_advisory_xact_lock(62343)'

            #Retry the exists query in case it got created in the meantime
            result = t.query exists_query
            if result.rows[0]
                return

            #Create the schema if it does not exist
            t.query 'CREATE SCHEMA IF NOT EXISTS bubblebot'

            #Create the table
            t.query 'CREATE TABLE bubblebot.migrations (codebase_id varchar(512), migration int, CONSTRAINT migrations_pk PRIMARY KEY (codebase_id))'


    #Returns a string that represents the state of the database's schema.  Used for
    #things like confirming that a rollback returned the database to the same
    #state as before
    capture_schema: ->
        return @pg_dump '-s'

    #Compares two schema created by capture schema: returns null if they are equivalent,
    #or a string error message if not.
    compare_schema: (s1, s2) ->
        errors = []
        first = {}
        second = {}
        first[line] = true for line in s1.split('\n')
        second[line] = true for line in s2.split('\n')
        for line, _ of second
            if not first[line]
                errors.push 'missing from first: ' + line
        for line, _ of first
            if not second[line]
                errors.push 'missing from second: ' + line
        if errors.length is 0
            return null
        return errors.join('\n')


#Tries this migration against a test database to make sure it works.  Tries the rollback
#and confirms it leaves the database in a consistent state.
templates.add 'Test', 'RDS_migration_try', {
    codebase: -> null

    run: (version) ->
        [codebase_id, migration] = extract_rds_version_pieces version
        codebase = templates.get 'Codebase', codebase_id
        try
            #Create a test instance initialized to one below the migration we are testing
            rds_instance = codebase.create_test_instance(migration - 1)

            #Capture the current state of the schema to compare the rollback
            pre_schema = codebase.capture_schema rds_instance
            u.log 'Schema before migration:\n' + pre_schema
            pre_version = join_rds_version_pieces codebase_id, codebase.get_installed_migration(rds_instance, codebase_id)

            #Apply the migration
            codebase.migrate_to rds_instance, version

            #Make sure the schema changed as a result of the migration (otherwise the
            #schema capturing is probably incomplete and therefore not actually testing
            #the rollback properly).
            new_schema = codebase.capture_schema rds_instance
            comparison = codebase.compare_schema rds_instance, pre_schema, new_schema
            if not comparison?
                u.log 'The post-migration schema is the same as the pre-migration schema: ' + new_schema
                return false
            else
                u.log 'Comparison after migration:\n' + comparison

            #See if this migration has a rollback
            no_rollback = not codebase.has_rollback(version)

            if no_rollback
                if not u.confirm 'We are testing a migration with no rollback: ' + version + '.  Are you sure you want to test and save it?'
                    u.log 'aborting because no rollback'
                    return false

            else
                #Apply the rollback
                codebase.migrate_to rds_instance, pre_version

                #Make sure the schema is now the same as it was originally
                post_schema = codebase.capture_schema rds_instance
                comparison = codebase.compare_schema rds_instance, pre_schema, post_schema
                if comparison?
                    u.log 'The rollback did not restore the schema.  Differences:\n' + comparison
                    return false
                u.log 'post schema matches pre-schema... locking migration data'

            u.log 'migration data locked'
            return true

        finally
            rds_instance?.terminate()
}

#Base class for creating EC2Build templates
#
#Children should define:
#
#codebase: -> returns the codebase object for this build
#verify: (ec2instance) -> verifies that the build is complete (ie, if stuff should be running, that it's running)
#software: (version) -> returns the software that gets run on top of the AMI.
#ami_software: (lowest_version) -> returns the software that gets run to create the AMI
#termination_delay: -> how long to wait before terminating an instance after a graceful shutdown
#default_size: (instance) -> see function of same name on bbobjects.EC2Build

#
templates.EC2Build = class EC2Build
    #This can get called with either a build object or an ec2instance
    on_startup: (instance) ->
        switch instance.type
            when 'EC2Instance'
                @on_startup_ec2_instance instance
            when 'EC2Build'
                @on_startup_ec2_build instance
            else
                throw new Error 'unrecognized ' + instance.type

    on_startup_ec2_instance: -> #no-op

    on_startup_ec2_build: -> #no-op

    #The size of the box we use to build the AMI on
    ami_build_size: -> 't2.micro'

    #The AMI we use as a base for creating our more-specific AMI.
    #
    #Defaults to the 64-bit HVM (SSD) EBS-Backed Amazon Linux AMI for the given region
    #
    #Should update from http://aws.amazon.com/amazon-linux-ami/ periodically
    # (Does not seem to be a straightforward way of getting this chart from the API)
    base_ami: (region) ->
        BY_REGION =
            'us-east-1': 'ami-c58c1dd3'
            'us-east-2': 'ami-4191b524'
            'us-west-2': 'ami-4836a428'
            'us-west-1': 'ami-7a85a01a'
            'ca-central-1': 'ami-0bd66a6f'
            'eu-west-1': 'ami-01ccc867'
            'eu-west-2': 'ami-b6daced2'
            'eu-central-1': 'ami-b968bad6'
            'ap-southeast-1': 'ami-fc5ae39f'
            'ap-northeast-2': 'ami-9d15c7f3'
            'ap-northeast-1': 'ami-923d12f5'
            'ap-southeast-2': 'ami-162c2575'
            'ap-south-1': 'ami-52c7b43d'
            'sa-east-1': 'ami-37cfad5b'
            'cn-north-1': 'ami-3fe13752'
            'us-gov-west-1': 'ami-34e76355'

        ami = BY_REGION[region]
        if not ami?
            throw new Error 'we do not have an Amazon Linux AMI coded for region ' + region
        return ami

    #Informs the box that it is now active.  Defaults to no-op.
    make_active: (ec2instance) ->

    #Informs the box that it should begin a graceful shutdown.  Defaults to no-op.
    graceful_shutdown: (ec2instance) ->

    #Returns a list of valid sizes for this build.  Can optionally pass in an object
    #that we use to look at for more details (ie, whether or not it is production, etc.)
    #
    #This default implementation returns all the latest available sizes
    valid_sizes: (instance) -> [
        't2.nano'
        't2.micro'
        't2.small'
        't2.medium'
        't2.large'
        'm4.large'
        'm4.xlarge'
        'm4.2xlarge'
        'm4.4xlarge'
        'm4.10xlarge'
        'c4.large'
        'c4.xlarge'
        'c4.2xlarge'
        'c4.4xlarge'
        'c4.8xlarge'
        'x1.32xlarge'
        'r3.large'
        'r3.xlarge'
        'r3.2xlarge'
        'r3.4xlarge'
        'r3.8xlarge'
        'g2.2xlarge'
        'g2.8xlarge	'
    ]

    #How often to replace the AMIs for this build
    get_replacement_interval: -> 24 * 60 * 60 * 1000


templates.BlankCodebase = class BlankCodebase extends templates.Codebase
    canonicalize: -> 'blank'
    ahead_of: -> true
    ahead_of_msg: -> throw new Error 'nope'
    merge: -> 'blank'
    debug_version: -> throw new Error 'nope'


#Represents a server with no software installed on it
class BlankBuild extends templates.EC2Build
    codebase: -> new BlankCodebase()

    verify: (ec2instance) ->

    software: (version) -> (instance) ->

    restart: (ec2instance) ->

    ami_software: -> null

    termination_delay: -> 1

    default_size: (instance) -> 't2.nano'


templates.add 'EC2Build', 'blank', new BlankBuild()


bbobjects = require './bbobjects'
u = require './utilities'
config = require './config'
software = require './software'
crypto = require 'crypto'
bbserver = require './bbserver'