templates = exports

#For each type of template, we define the functions we use to determine whether
#this is an instance of the template.  We use this for templates.verify and templates.list
interfaces =
    Environment: ['initialize']
    Service: ['codebase', 'get_tests', 'deploy']
    Codebase: ['canonicalize', 'ahead_of', 'ahead_of_msg', 'merge']
    Test: ['run']
    EC2Build: ['codebase', 'verify', 'software', 'ami_software', 'termination_delay', 'default_size', 'get_replacement_interval']


#For each interface, create an object for registering things that implement that interface
templates.templates = {}
for i_name, _ of interfaces
    templates.templates[i_name] = {}

#Given the name of a template interface, and the id of a template, confirms that this
#is a valid template id or throws an error
templates.verify = (interface, id) ->
    if not templates[interface]
        throw new Error 'could not find interface ' + interface
    if not templates[interface][id]
        throw new Error 'could not find ' + interface + ' with id ' + id
    for fn in interfaces[interface]
        if typeof(templates[id][fn]) isnt 'function'
            throw new Error 'id ' + id + ' is not a valid ' + interface + ' (missing ' + fn + ')'

#Adds the given template
templates.add = (interface, id, template) ->
    templates.templates[interface][id] = template
    templates.verify interface, id

#List the ids of all the registered templates that match this interface
templates.list = (interface) ->
    return (id for id, template of templates.templates[interface] ? throw new Error 'could not find interface ' + interface)

#Retrieves a template
templates.get = (interface, id) ->
    templates.verify interface, id
    return templates.templates[interface][id]

#Extend this to build environment templates
templates.Environment = class Environment
    initialize: (environment) ->

#A blank environment...
templates.add 'Enivronment', 'blank', new Environment()


#Extend this to build service templates
#
#Children should define the following:
# codebase() returns a codebase template
# get_tests() returns an array of tests
# replace: (instance) -> should replace the actual boxes with new boxes
# endpoint: -> should return the endpoint
#
templates.Service = class Service
    deploy: (instance, version, rollback) ->
        codebase = @codebase()

        #Get the canonical version
        canonical = codebase.canonicalize version
        if not canonical
            u.reply 'Could not resolve version ' + version
            return
        version = canonical

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

        deployment_message = @get_deployment_message instance, version

        #Make sure it passed the tests
        if not @ensure_tested instance, version
            return

        #Hook to add any custom logic for making sure the deployment is safe
        if @deploy_safe?
            if not @deploy_safe instance, version
                u.reply 'Aborting deployment'
                return

        #make sure that the version hasn't been updated in the interim
        while not codebase.ahead_of version, instance.version()
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
                u.reply "Your version was no longer ahead of the production version -- someone else probably deployed in the interim.  We were able to automatically merge it and will continue trying to deploy: ' + merged
                #Make sure the new version passes the tests
                if not @ensure_tested instance, version
                    return

        #Okay, we have a tested version that is ahead of the current version, so deploy it and announce!
        instance.set 'version', version

        #update history...
        instance.add_history 'deploy', version, {username: u.current_user().name(), deployment_message, rollback}

        #Notify re: the deployment
        u.announce u.current_user().name() ' deployed version ' + version + ' to ' + instance + '.  We are rolling out the new version now.  Deployment message: ' + deployment_message
        u.reply 'Your deploy was successful! Rolling out the new version now...'

        #Replace the existing servers with the new version
        @replace instance

        #Let the user know we are finished
        u.reply 'We are finished rolling out the new version. Consider creating an announcement: http://forum.bubble.is/new-topic?title=[New%20Feature]&category=Announcements'


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
            if @codebase().ahead_of instance.version(), saved.version
                saved = null

            #if the version we are deploying is not ahead of its version, it means
            #it is probably for another branch, so we should ignore it
            else if not @codebase().ahead_of version, saved.version
                saved = null


        get_message = ->
            if saved
                message = u.ask 'Please enter a message to describe this deployment, or type "go" to use the last message (' + saved + ')'
                if message.toLowerCase().trim() is 'go'
                    message = saved
            else
                message = u.ask 'Please enter a message to describe this deployment'

            if message.length is < 4
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
            u.announce u.current_user().name() + ' is trying to deploy to ' + instance
            @run_tests version
            if not @is_tested version
                return false

        return true

    #Returns true if this version has passed all the tests for this service
    is_tested: (version) ->
        for test in @get_tests()
            if not test.is_tested version
                return false
        return true

    #Runs any not-passed test for this service against this version
    run_tests: (version) ->
        tests = (test for test in @get_tests() when not test.is_tested version)
        u.reply 'Running the following tests: ' + tests.join(', ')
        for test in tests
            test.run version

#Represents a service that's an RDS-managed database
templates.RDSService = class RDSService extends Service
    constructor: (@_codebase) ->

    #We don't actually replace database boxes since that's generally a bad idea,
    #but when we call replace we make sure they have an RDS instance are up to date with the latest version
    replace: (instance) ->
        version = instance.version()
        if not version?
            return

        if not @rds_instance(instance)
            @create_rds_instance(instance)

        @_codebase.migrate_to @rds_instance(), version

    #Gets the rds instance
    rds_instance: (instance) ->
        id = instance.get 'rds_instance'
        if id
            return bbobjects.instance 'RDSInstance', id

    #Creates a new RDS instance for this service
    create_rds_instance: (instance) ->
        if instance.get 'rds_instance'
            throw new Error 'already have an instance'

        rds_instance = bbobjects.instance 'RDSInstance', @id + '_instance1'
        permanent_options = @_codebase.rds_options()
        sizing_options = @_codebase.get_sizing this

        #Most of the time we want to let the instance generate and store its own credentials,
        #but for special cases like BBDB we want to store the credentials in S3
        if @_codebase.use_s3_credentials()
            MasterUsername = u.gen_password()
            MasterUserPassword = u.gen_password()
            credentials = {MasterUsername, MasterUserPassword}

            #Save the credentials to s3 for future access
            bbobjects.put_s3_config @_get_credentials_key(instance), JSON.stringify(credentials)
        else
            credentials = null

        rds_instance.create this, permanent_options, sizing_options, credentials

        instance.set 'rds_instance', rds_instance.id

    #S3 key we use to store credentials
    _get_credentials_key: (instance) -> 'RDSService_' + instance.id + '_credentials'

    codebase: -> @_codebase

    endpoint: (instance) ->
        rds_instance = @rds_instance(instance)
        if not rds_instance
            return null

        if @_codebase.use_s3_credentials()
            credentials = JSON.parse bbobjects.get_s3_config @_get_credentials_key(instance)
        else
            credentials = null
        return rds_instance.endpoint(credentials)

    #Before deploying, we want to confirm that the migration is reversibe.
    deploy_safe: (instance, version) ->
        if not @_codebase.confirm_reversible @rds_instance(instance), version
            return false

        return true


    get_tests: -> @_codebase.get_tests()


#Base class for services that have a single box.  They take a template,
#an array of tests, and a switcher function that takes the service instance
#and returns the switcher that controls where traffic is routed
templates.SingleBoxService = class SingleBoxService
    constructor: (@build_id, @tests, @switcher) ->
        super()

    #Retrieve the ec2build object for this service
    ec2build: -> bbobjects.instance 'EC2Build', @build_id

    codebase: -> @ec2build().codebase()

    get_tests: -> @tests

    endpoint: (instance) -> @switcher(instance).endpoint()

    replace: (instance) ->
        build = @ec2build()
        size = @get_size(instance)
        switcher = @switcher(instance)

        #Create the new server
        u.announce 'Building a replacement server for ' + instance
        new_ec2instance = build.build instance, size, String(instance)

        #See if there is an old server
        old_ec2instance = switcher.get_instance()

        #Perform the switch
        switcher.switch new_ec2instance
        try
            #Notify the new box that it is active
            build.make_active new_ec2instance
        catch err
            u.report 'Switched service ' + instance + ' to point to ' + new_ec2instance.id + ', but make_active failed!'
            u.report 'Error was: ' + err.stack ? err
            u.report 'Reverting to old instance (' + old_ec2instance.id + ') and terminating new instance'
            switcher.switch old_ec2instance
            new_ec2instance.terminate()
            return

        #Begin the graceful shutdown process for the old instance, if there is one
        if old_ec2instance
            build.graceful_shutdown old_ec2instance
        u.announce new_ec2instance + ' is now the active server for ' + instance

    #Gets the size of the box for this service
    get_size: (instance) ->
        size = instance.get 'size'
        size ?= @ec2build().default_size(instance)
        return size

    get_size_cmd:
        help: 'Gets the size of the box for this service'
        reply: true
        groups: bbobjects.BASIC

    #Sets the size of the box for this service
    set_size: (instance, new_size) ->
        valid_sizes = @ec2build().valid_sizes(instance)
        if size not in valid_sizes
            u.reply 'Cannot set size ' + new_size + ': should be one of ' + valid_sizes.join(', ')
            return
        instance.set 'size', new_size

    set_size_cmd:
        params: [{name: 'new_size', type: 'number', required: true}]
        help: 'Sets the size of the box for this service'
        reply: 'Size successfully set'
        groups: bbobjects.BASIC
        dangerous: -> @environment().is_production()


#Implements the codebase interface using git.  Should pass in a git repo as in github.coffee
templates.GitCodebase = class GitCodebase
    constructor: (@repo) ->

    canonicalize: (version) -> return @repo.resolve_commit version

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
#as a space-separated list of commits in the order that the repos are passed in to the constructor
templates.MultiGitCodebase = class MultiGitCodebase
    constructor: (@repos) ->

    canonicalize: (version) ->
        commits = version.split(' ')
        results = []
        for repo, idx in @repos
            canonical = rep.resolve_commit commits[idx]?.trim()
            #if any commit can't be resolved, the overall version can't be resolved so return null
            if not canonical?
                return null
            results.push canonical

        return results.join ' '

    #True if each version is ahead of each other version
    ahead_of: (first, second) ->
        first = first.split(' ')
        second = second.split(' ')
        for repo, idx in @repos
            f = first[idx]
            s = second[idx]
            if not repo.ahead_of f, s
                return false
        return true

    ahead_of_msg: (first, second) ->
        first = first.split(' ')
        second = second.split(' ')
        for repo, idx in @repos
            f = first[idx]
            s = second[idx]
            if not repo.ahead_of f, s
                return 'Commit ' + f + ' is not ahead of commit ' + s + ' in repo ' + repo
        throw new Error 'is ahead of! ' + first + ' -- ' + second

    merge: (base, head) ->
        base = base.split(' ')
        head = head.split(' ')
        results = []
        for repo, idx in @repos
            res = @repo.merge base[idx], head[idx]
            if not res.success
                return null
            results.push res.commit
        return results.join(' ')

    pretty_print: (version) ->
        version = version.split(' ')
        return (repo.display_commit version[idx] for repo, idx in @repos).join('\n')


#Represents a set of schema migrations for an RDS managed database
templates.RDSCodebase = class RDSCodebase
    constructor: (@migrations, @rollbacks, @additional_tests) ->

    #Version should be [codebase id]/[migration #]
    canonicalize: (version) ->
        [codebase_id, migration] = String(version).split('/')
        if codebase_id isnt @get_id() or not String(parseInt(migration)) is migration
            return null
        return codebase_id + '/' + migration

    #returns [codebase_id (string), migration (number)], and throws an error
    #if codebase_id is wrong
    _extract_pieces: (version) ->
        [codebase_id, migration] = String(version).split('/')
        if codebase_id isnt @get_id()
            throw new Error 'codebase mismatch: is ' + codebase_id + ', should be ' + @get_id()
        migration = parseInt migration
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

    #Gets the data for this migration
    get_migration: (version, rollback) ->
        #See if we have it saved in s3.
        saved = bbobjects.get_s3_config 'RDSCodebase_' + version + (if rollback then '_rollback' else '')
        if saved?
            return JSON.parse saved

        #Otherwise, get it from the migration array
        [codebase_id, migration] = @_extract_pieces(version)
        if rollback
            return @rollbacks[migration]
        else
            return @migrations[migration]

    #Returns the most up-to-date version of this codebase
    get_latest_version: -> @get_id() + '/' + String(@migrations.length - 1)

    #Returns true if upgrading the given rds_instance to the given version is reversible.
    #If not reversible, will ask the user to confirm that it is okay to migrate anyway.
    confirm_reversible: (rds_instance, version) ->
        [codebase_id, new_migration] = @_extract_pieces(version)

        current_migration = @get_installed_migration rds_instance, codebase_id
        if new_migration is current_migration
            return true

        #See if this is a forward migration
        if new_migration > current_migration
            start = current_migration + 1
            end = new_migration
            #See if it is reversible
            reversible = true
            for migration in [start..end]
                if not @rollbacks[migration]
                    reversible = false

            if reversible
                return true

            msg = "This migration is NOT reversible... we do not have rollbacks defined for every migration we are applying (#{start} to #{end}).  Are you sure you want to continue?"
            return u.confirm msg

        #If it's a rollback, confirm true (we should have already confirmed that doing
        #a rollback is okay)
        else
            return true


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
            throw new error 'We do not currently support database of type ' + engine
        return migration_managers[engine]

    #Applies the given migration # to the rds instance
    apply_migration: (rds_instance, codebase_id, migration) ->

    #Applies the given rollback # to the rds instance
    apply_rollback: (rds_instance, codebase_id, migration) ->

    get_tests: ->
        tests = [].concat (@additional_tests ? [])
        #Test to make sure the rollback works, if it exists
        tests.push bbobjects.instance 'Test', 'RDS_migration_test_rollback'
        #The final test is always trying it to see if it runs without errors, and if so
        #saving it to S3 so that it's locked down
        tests.push bbobjects.instance 'Test', 'RDS_migration_try_and_save'

    rds_options: ->

    get_sizing: (service) ->

    use_s3_credentials: ->


migration_managers = {}
migration_managers.postgres = class PostgresMigrator
    #Given a codebase id, returns the number of the current migration (or -1 if we have
    #never applied one)
    get_migration: (codebase_id) ->

    #Makes sure we have the right migr
    ensure_migration_table_exists: ->
        SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'name';



#Tries this migration against a test database to make sure the schema compiles, then
#saves it to s3.
templates.add 'Test', 'RDS_migration_try_and_save', {
    run: (version) -> throw new Error 'not yet implemented'
        #MAKE SURE I SAVE BOTH THE MIGRATION AND THE ROLLBACK
}

#Test to make sure the rollback works, if it exists
templates.add 'Test', 'RDS_migration_test_rollback', {
    run: (version) -> throw new Error 'not yet implemented'
}


#Base class for building tests.  Tests should have a globally-unique id that we use
#to store results in the database
#
#children should define run(version) -> which executes the test and returns true / false
#based on success or failure status
templates.Test = class Test
    constructor: (@id) ->


#Base class for creating EC2Build templates
#
#Children should define:
#
#codebase: -> returns the codebase object for this build
#verify: (ec2instance) -> verifies that the build is complete (ie, if stuff should be running, that it's running)
#software: -> returns the software that gets run on top of the AMI
#ami_software: -> returns the software that gets run to create the AMI
#termination_delay: -> how long to wait before terminating an instance after a graceful shutdown
#default_size: (instance) -> see function of same name on bbobjects.EC2Build

#
class templates.EC2Build = class EC2Build
    #The size of the box we use to build the AMI on
    ami_build_size: -> 't2.nano'

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



bbobjects = require './bbobjects'