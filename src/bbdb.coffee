bbdb = exports

databases = require './databases'

#Represents a connection to the database that powers bubble bot
bbdb.BBDatabase = class BBDatabase extends databases.Postgres
    #given a type, returns an array of all the ids of that type
    list_objects: (type) ->
        result = @query "SELECT id FROM bbobjects WHERE type = $1", type
        return (row.id for row in result.rows)

    #Given an object, returns the property with the given name
    get_property: (type, id, name) ->
        result = @query "SELECT properties->$3 as prop FROM bbobjects WHERE type = $1 AND id = $2", type, id, name
        return result.rows[0]?.prop

    #Given an object, returns all the properties for that object.
    get_properties: (type, id) ->
        result = @query "SELECT properties FROM bbobjects WHERE type = $1 AND id = $2", type, id
        return result.rows[0]?.properties

    #Given an object, sets the property with the given name.  Errors if the object does not exist
    set_property: (type, id, name, value) ->
        query = "UPDATE bbobjects SET properties = COALESCE(properties, '{}'::jsonb) || jsonb_build_object($3::text, $4::jsonb) WHERE type = $1 AND id = $2 RETURNING id"
        result = @query query, type, id, name, JSON.stringify(value)
        if result.rows.length isnt 1
            throw new Error 'set failed: modified ' + result.rows.length + ' rows'
        return null

    #Creates a new object, optionally with the given parent and initial properties
    create_object: (type, id, parent_type, parent_id, initial_properties) ->
        query = "INSERT INTO bbobjects (type, id, parent_type, parent_id, properties) VALUES ($1, $2, $3, $4, $5::jsonb)"
        @query query, type, id, parent_type, parent_id, JSON.stringify(initial_properties)
        return null

    #Deletes this object from the database
    delete_object: (type, id) ->
        query = "DELETE FROM bbobjects WHERE type = $1 and id = $2"
        @query query, type, id
        return null

    #Returns true if an object with this type and id exists
    exists: (type, id) ->
        query = "SELECT 1 FROM bbobjects WHERE type = $1 and id = $2"
        result = @query query, type, id
        return result.rows[0]?


    #Returns the immediate parent, or if parent_type is set, searches upwards til it
    #finds an ancestor of that type.
    #
    #Returns [parent_type, parent_id], or [null, null] if not found
    find_parent: (type, id, parent_type) ->
        #If parent_type is set, we need to do a recursive search
        if parent_type
            query = "WITH RECURSIVE parents(parent_type, parent_id) as (
                      VALUES ($1, $2)
                      UNION
                      SELECT bbobjects.parent_type, bbobjects.parent_id FROM bbobjects
                      INNER JOIN parents ON parents.parent_id = bbobjects.id AND parents.parent_type = bbobjects.type
                    ) SELECT * from parents WHERE parent_type = $3"
            result = @query query, type, id, parent_type


        #No parent type, so this is just a straightforward select
        else
            query = "SELECT parent_type, parent_id FROM bbobjects WHERE type = $1 and id = $2"
            result = @query query, type, id

        first = result.rows[0]
        return [first?.parent_type, first?.parent_id]

    #Lists all immediate children.  If child_type is set, filters by child type
    #
    #Returns [[child_type, child_id], [child_type, child_id]...]
    children: (type, id, child_type) ->
        if child_type
            query = "SELECT type, id FROM bbobjects WHERE parent_type = $1 AND parent_id = $2 AND type = $3"
            result = @query query, type, id, child_type
        else
            query = "SELECT type, id FROM bbobjects WHERE parent_type = $1 AND parent_id = $2"
            result = @query query, type, id

        return ([row.type, row.id] for row in result.rows)

    #Creates an entry in the history table
    add_history: (history_type, history_id, reference, properties) ->
        query = "INSERT INTO history (history_type, history_id, timestamp, reference, properties) VALUES ($1, $2, $3, $4, $5::jsonb)"
        @query query, history_type, history_id, Date.now(), reference, JSON.stringify(properties)
        return null

    #Returns the last n_entries from the given history
    recent_history: (history_type, history_id, n_entries = 10) ->
        query = "SELECT * FROM history WHERE history_type = $1 AND history_id = $2 ORDER BY timestamp DESC LIMIT $3"
        result = @query query, history_type, history_id, n_entries
        return result.rows

    #Finds entries for the given parameters
    find_entries: (history_type, history_id, reference) ->
        query = "SELECT * FROM history WHERE history_type = $1 AND history_id = $2 AND reference = $3"
        result = @query query, history_type, history_id, reference
        return result.rows

    #Deletes entries for the given parameters
    delete_entries: (history_type, history_id, reference) ->
        query = "DELETE FROM history WHERE history_type = $1 AND history_id = $2 AND reference = $3"
        @query query, history_type, history_id, reference
        return null


    #Scheduler support

    #Sets the given task to run at the given timestamp with the given properties
    schedule_task: (timestamp, task, properties) ->
        query = "INSERT INTO scheduler (timestamp, task, properties) VALUES ($1, $2, $3::jsonb)"
        @query query, timestamp, task, JSON.stringify(properties)
        return null

    #If there is a task with the same name already in the scheduler, update the properties.
    #Otherwise, insert a new task scheduled to run now.
    upsert_task: (task, properties) ->
        @transaction (t) =>
            #acquire a lock on the taskname so that if someone else is trying the same upsert
            #it will block til this finishes
            t.advisory_lock task

            #Update any current jobs...
            query = "UPDATE scheduler SET properties = $2::jsonb WHERE task = $1"
            result = t.query query, task, JSON.stringify(properties)
            #If there was at least one row selected, we are done...
            if result.rowCount > 0
                return

            #Insert a new task
            query = "INSERT INTO scheduler (timestamp, task, properties) VALUES ($1, $2, $3::jsonb)"
            t.query query, Date.now(), task, JSON.stringify(properties)

            return null

    #Returns tasks by taskname and count
    list_tasks: ->
        query = 'SELECT task, count(*) FROM scheduler GROUP BY task'
        result = @query query
        return result.rows

    #Deletes all tasks with the given taskname
    remove_by_taskname: (task) ->
        query = 'DELETE FROM scheduler WHERE task = $1'
        @query query, task
        return null

    #Retrieves the first task that a) is unclaimed and b) is ready to go.
    #
    #Marks the retrieved task as claimed.
    #
    #owner_id represents who we want to say is claiming the task.  Should pass in null
    #if unknown, and a new one will be generated.
    #
    #Return {owner_id, task_data}.  Task_data will be null if there is nothing
    get_next_task: (owner_id) ->
        #If we don't have an owner id, generate a new one
        if not owner_id
            result = @query 'INSERT INTO scheduler_owners (last_access) VALUES ($1) RETURNING owner_id', Date.now()
            owner_id = result.rows[0].owner_id

        #Otherwise, update the access time of our owner (re-creating it if it was deleted)
        else
            query = "INSERT INTO scheduler_owners (owner_id, last_access) VALUES ($1, $2) ON CONFLICT (owner_id) DO UPDATE SET last_access = $2"
            @query query, owner_id, Date.now()

        #Clean out owners that haven't claimed a task in the last minute
        query = 'DELETE FROM scheduler_owners WHERE last_access < $1'
        @query query, Date.now() - 60 * 1000

        return @transaction (t) =>
            #Lock the scheduler table
            t.query 'LOCK scheduler'

            #We want to find the first task that a) is unclaimed, b) has a timestamp < now,
            #set ourselves as the current owner, and return that task
            query = "
                UPDATE scheduler SET owner = $1 WHERE id in
                (SELECT id FROM scheduler
                LEFT JOIN scheduler_owners ON scheduler_owners.owner_id = scheduler.owner
                WHERE scheduler_owners.owner_id is null AND timestamp < $2 AND scheduler.owner != $1
                ORDER by timestamp LIMIT 1) RETURNING *
                "
            result = t.query query, owner_id, Date.now()

            return {owner_id, task_data: result.rows[0]}


    #Indicates that we finished a task and can remove it from the scheduler
    complete_task: (id) ->
        @query 'DELETE FROM scheduler WHERE id = $1', id
        return null

    #Indicate that for some reason we could not complete the task, so we need to release it
    release_task: (id) ->
        @query "UPDATE scheduler SET owner = null WHERE id = $1", id
        return null



bbobjects = require './bbobjects'
templates = require './templates'

class BBDBCodebase extends templates.RDSCodebase
    #We need to store our credentials in s3 instead of in the bubblebot database,
    #since we are the bubblebot database!
    use_s3_credentials: -> true

    rds_options: -> {
        Engine: 'postgres'
        EngineVersion: '9.5.2'
    }

    #BBDB doesn't have to be terribly fast or robust, but should not be publicly
    #accessible, and should have good backups
    get_sizing: -> {
        AllocatedStorage: 5
        DBInstanceClass: 'db.t2.micro'
        BackupRetentionPeriod: 30
        MultiAZ: false
        StorageType: 'standard'
        PubliclyAccessible: false
    }

    get_additional_tests: -> []

    get_migrations: -> [
        """
        CREATE TABLE bbobjects (
            type varchar(512),
            id varchar(512),
            parent_id varchar(512),
            parent_type varchar(512),
            properties jsonb,
            PRIMARY KEY (type, id)
        );
        CREATE INDEX ON bbobjects (parent_id, parent_type);

        CREATE TABLE history (
            history_type varchar(512),
            history_id varchar(512),
            timestamp bigint,
            reference varchar(512),
            properties jsonb
        );
        CREATE INDEX ON history (history_type, history_id, timestamp);
        CREATE INDEX ON history (history_type, history_id, reference);

        CREATE TABLE scheduler (
            id bigserial,            --uid of task instance
            timestamp bigint,        --when we should run it
            owner bigint,            --who claimed the task
            task varchar(512),       --name of the task
            properties jsonb,        --data to pass to the task
            PRIMARY KEY (id)
        );
        CREATE INDEX ON scheduler (timestamp);
        CREATE INDEX ON scheduler (task);

        CREATE TABLE scheduler_owners (
            owner_id bigserial,
            last_access bigint,
            PRIMARY KEY (owner_id)
        );
        """
    ]


    get_rollbacks: -> [
        """
        DROP TABLE bbobjects, history, scheduler, scheduler_owners;
        """
    ]

templates.add 'Codebase', 'BBDBCodebase', new BBDBCodebase()


class BBDBService extends templates.RDSService
    #We override the logic for fetching the actual instance, since we can't
    #rely on BBDB to find BBDB
    rds_instance: (instance) ->
        return bbobjects.get_bbdb_instance()

    get_monitoring_policy: -> {
        monitor: true
        frequency: 10000
        dependencies: []
        actions: {
            announce:
                action: 'announce'
                threshold: 2 * SECOND
                limit: MINUTE

            report:
                action: 'report'
                threshold: 5 * SECOND
                limit: MINUTE
        }
        endpoint: {
            protocol: 'postgres'
        }
    }

templates.add 'Service', 'BBDBService', new BBDBService 'BBDBCodebase'

