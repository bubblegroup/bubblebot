templates = exports



#Represents a series of migrations on a pg database
templates.PGDatabase = class PGDatabase
    #max: -> the number of the highest migration
    #get (num) -> get migration
    #get_dev: -> the migration we are currently testing, or null if none
    #get_rollback_dev: -> the rollback for the development migration
    #get_rollback: (num) -> gets the rollback for the given migration


#The schema for bubblebot
templates.BubblebotDatabase extends PGDatabase
    migrations: [
        "
        --install psql
        --check database default datatype for default schmea

        CREATE TABLE bbobjects (
            type varchar(512),
            id varchar(512),
            parent_id varchar(512),
            parent_type varchar(512),
            properties jsonb
        )

        CREATE TABLE history (
            history_type varchar(512),
            history_id varchar(512),
            timestamp bigint,
            reference varchar(512),
            properties jsonb
        )
        --Needs to be searchable by history_type / history_id / timestamp
        --Needs to be searchable by history_type / history_id / reference
        "
    ]

    rollbacks: [

    ]

    max: -> @migrations.length - 1

    get: (num) -> @migrations[num]

    get_dev: -> null

    get_rollback_dev: -> null

    get_rollback: (num) -> @rollbacks[num]


#Extend this to build environment templates
templates.Environment = class Environment
    initialize: (environment) ->


#Extend this to build service templates
#
#Children should define the following:
# codebase() returns a codebase template
# get_tests() returns an array of tests
# replace: (instance) -> should replace the actual boxes with new boxes
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

        #make sure that the version hasn't been updated in the interim
        while not codebase.ahead_of version, instance.version()
            #see if we can merge
            merged = codebase.merge version, instance.version()
            if not merged
                u.reply "Your version is no longer ahead of the production version (#{instance.version()}) -- someone else probably deployed in the interim.  We tried to automatically merge it but were unable to, so we are aborting."
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
        instance.add_history 'deploy', version

        #Notify re: the deployment
        u.announce u.current_user().name() ' deployed version ' + version + ' to ' + instance + '.  We are rolling out the new version now...'
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

#Implements the codebase interface using multiple git repositories.  A version is defined
#as a space-separated list of commits in the order that the repos are passed in to the constructor
template.MultiGitCodebase = class MultiGitCodebase
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
