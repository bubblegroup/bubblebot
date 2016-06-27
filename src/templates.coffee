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
    templates.verify iface, id
    return templates.templates[iface][id]

#Extend this to build environment templates
templates.Environment = class Environment
    initialize: (environment) ->

    on_startup: -> #no-op

#A blank environment...
templates.add 'Environment', 'blank', new Environment()


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
        version = codebase.ensure_version version

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

        #Make sure it passed the tests
        if not @ensure_tested instance, version
            return

        #Hook to add any custom logic for making sure the deployment is safe
        if @deploy_safe?
            if not @deploy_safe instance, version
                u.reply 'Aborting deployment'
                return

        #make sure that the version hasn't been updated in the interim
        while instance.version() and not codebase.ahead_of version, instance.version()
            #see if we can merge
            merged = codebase.merge version, instance.version()
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
                if not @ensure_tested instance, version
                    return

        #Okay, we have a tested version that is ahead of the current version, so deploy it and announce!
        instance.set 'version', version

        username = u.current_user()?.name() ? '<automated>'

        #update history...
        instance.add_history 'deploy', version, {username, deployment_message, rollback}

        #Notify re: the deployment
        u.announce username + ' deployed version ' + version + ' to ' + instance + '.  We are rolling out the new version now.  Deployment message: ' + deployment_message
        u.reply 'Your deploy was successful! Rolling out the new version now...'

        #Replace the existing servers with the new version
        u.retry 3, 30000, =>
            @replace instance

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
            u.announce (u.current_user()?.name() ? '<automated>') + ' is trying to deploy to ' + instance
            @run_tests version
            if not @is_tested version
                return false

        return true

    #Returns true if this version has passed all the tests for this service
    is_tested: (version) ->
        tests = @get_tests()
        for test in tests
            if not test.is_tested version
                return false
        return true

    #Runs any not-passed test for this service against this version
    run_tests: (version) ->
        tests = (test for test in @get_tests() when not test.is_tested version)
        u.reply 'Running the following tests: ' + tests.join(', ')
        for test in tests
            test.run version



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

        @codebase().migrate_to @rds_instance(), version

    servers: (instance) -> [@rds_instance(instance)]

    #Gets the rds instance
    rds_instance: (instance) ->
        id = instance.get 'rds_instance'
        if id
            return bbobjects.instance 'RDSInstance', id

    wait_for_available: (instance) -> @rds_instance(instance).wait_for_available()

    #Gets the parameters we use to create a new RDS instance
    get_params_for_creating_instance: (instance) ->
        permanent_options = @codebase().rds_options()
        sizing_options = @codebase().get_sizing this

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

        rds_instance = bbobjects.instance 'RDSInstance', @id + '_instance1'

        {permanent_options, sizing_options, credentials} = @get_params_for_creating_instance instance

        rds_instance.create instance, permanent_options, sizing_options, credentials

        instance.set 'rds_instance', rds_instance.id

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


#Base class for services that have a single box.  They take a template,
#an array of tests, and a switcher function that takes the service instance
#and returns the switcher that controls where traffic is routed
templates.SingleBoxService = class SingleBoxService extends templates.Service
    constructor: (@build_id, @test_ids, @switcher, @monitoring_policy) ->

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
            u.SyncRun =>
                server.build_context()
                @ensure_switcher_correct instance
            throw err


    on_startup: (instance) ->
        super()
        @ensure_version_deployed(instance)

        server = u.context().server

        ensure_switcher = =>
            u.SyncRun =>
                try
                    server.build_context()
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
                u.context().server.run_fiber "Replacing #{instance}", @replace.bind(this, instance)


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
        params: [{name: 'new_size', type: 'number', required: true}]
        help: 'Sets the size of the box for this service'
        reply: 'Size successfully set'
        groups: constants.BASIC
        dangerous: -> @environment().is_production()


#Base class for codebases
templates.Codebase = class Codebase
    debug_version: (version) -> return 'Not a valid version: ' + version

    #If this version is not valid, prompts the user for a valid one
    ensure_version: (version) ->
        canonical = @canonicalize version
        if not canonical
            #if there is no current user, abort
            if not u.current_user()
                u.expected_error @debug_version version
            msg = @debug_version(version) + '\nPlease enter a valid version (or type "cancel" to abort)'
            return @ensure_version u.ask msg
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
#as a dash-separated list of commits in the order that the repos are passed in to the constructor
templates.MultiGitCodebase = class MultiGitCodebase extends Codebase
    constructor: (@repos) ->

    canonicalize: (version) ->
        commits = version.split('-')
        results = []
        for repo, idx in @repos
            canonical = repo.resolve_commit commits[idx]?.trim()
            #if any commit can't be resolved, the overall version can't be resolved so return null
            if not canonical?
                return null
            results.push canonical

        return results.join '-'

    debug_version: (version) ->
        if String(version).indexOf('-') is '-1'
            format_string = ('[commit ' + i + 1 for repo, i in @repos).join('-')
            return 'Bad version: '  + version + '.  Format should be ' + format_string + ' (hyphen-seperated)'
        commits = version.split('-')
        for repo, idx in @repos
            canonical = repo.resolve_commit commits[idx]?.trim()
            if not canonical
                return 'Could not find commit ' + commits[idx] + ' in ' + String(repo)

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
            res = @repo.merge base[idx], head[idx]
            if not res.success
                return null
            results.push res.commit
        return results.join('-')

    pretty_print: (version) ->
        version = version.split('-')
        return (repo.display_commit version[idx] for repo, idx in @repos).join('\n')

#Returns [codebase_id (string), migration (number)]
extract_rds_version_pieces = (version) ->
    [codebase_id, migration] = String(version).split('/')
    migration = parseInt migration
    return [codebase_id, migration]

#Returns an RDSCodebase version
join_rds_version_pieces = (codebase_id, migration) -> codebase_id + '/' + String(migration)

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
    #Version should be [codebase id]/[migration #]
    canonicalize: (version) ->
        [codebase_id, migration] = String(version).split('/')
        if codebase_id isnt @get_id() or not String(parseInt(migration)) is migration
            return null
        return join_rds_version_pieces codebase_id, migration

    debug_version: (version) ->
        if String(version).indexOf('/') is -1
            return 'Version should be [codebase id]/[migration #]'
        [codebase_id, migration] = String(version).split('/')
        if codebase_id isnt @get_id()
            return 'Codebase id ' + codebase_id + ' does not match this codebase: ' + @get_id()
        if String(parseInt(migration)) is migration
            return 'Bad migration: ' + migration + '.  Should be an integer.'
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


    #Prevents accidentally changing the data for this migration by persisting it to S3.
    #We do this after testing migrations to make sure that the tested version remains
    #the actual version.  If overwrite is true, we can replace a locked version.
    lock_migration_data: (version, overwrite) ->
        if not overwrite
            saved = bbobjects.get_s3_config 'RDSCodebase_' + version
            if saved?
                throw new Error 'we have already locked version ' + version

        [codebase_id, migration] = @_extract_pieces(version)
        bbobjects.put_s3_config 'RDSCodebase_' + version, @get_migrations()[migration]
        if @get_rollbacks()[migration]
            bbobjects.put_s3_config 'RDSCodebase_' + version + '_rollback', @get_rollbacks()[migration]

    #Gets the data for this migration.  If rollback is true, returns the rollback instead
    #of the migration
    get_migration_data: (version, rollback) ->
        #See if we have it saved in s3.
        saved = bbobjects.get_s3_config 'RDSCodebase_' + version + (if rollback then '_rollback' else '')
        if saved?
            return JSON.parse saved

        #Otherwise, get it from the migration array
        [codebase_id, migration] = @_extract_pieces(version)
        if rollback
            return @get_rollbacks()[migration]
        else
            return @get_migrations()[migration]

    #Returns the most up-to-date version of this codebase
    get_latest_version: -> join_rds_version_pieces @get_id(), @get_migrations().length - 1

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
        tests.push bbobjects.instance 'Test', 'RDS_migration_try_and_save'
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
    create_test_instance: (migration, sizing_options) ->
        migration ?= @get_migrations().length - 1
        sizing_options ?= @get_test_sizing_options()

        #Create a new instance with a random id
        environment = bbobjects.get_default_qa_environment()
        rds_instance = bbobjects.instance 'RDSInstance', 'test-' + u.gen_password()
        rds_instance.create environment, @rds_options(), sizing_options

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
            query = "INSERT INTO bubblebot.migrations (codebase_id, migration) VALUES ($1, $2) ON CONFLICT (codebase_id) DO UPDATE SET migration = $2"
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
            t.query 'CREATE TABLE migrations (codebase_id varchar(512), migration int, CONSTRAINT migrations_pk PRIMARY KEY (codebase_id))'


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
#
#Then, saves both the rollback and migration to S3
templates.add 'Test', 'RDS_migration_try_and_save', {
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
            no_rollback = not codebase.get_migration_data(version, true)
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

            #save both migration and rollback to S3
            codebase.lock_migration_data version

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
            'us-east-1': 'ami-f5f41398'
            'us-west-2': 'ami-d0f506b0'
            'us-west-1': 'ami-6e84fa0e'
            'eu-west-1': 'ami-b0ac25c3'
            'eu-central-1': 'ami-d3c022bc'
            'ap-southeast-1': 'ami-1ddc0b7e'
            'ap-northeast-2': 'ami-cf32faa1'
            'ap-northeast-1': 'ami-29160d47'
            'ap-southeast-2': 'ami-0c95b86f'
            'sa-east-1': 'ami-fb890097'
            'cn-north-1': 'ami-05a66c68'
            'us-gov-west-1': 'ami-e3ad1282'

        return BY_REGION[region]

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


class BlankCodebase extends templates.Codebase
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