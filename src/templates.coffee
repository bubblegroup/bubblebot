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
#Children should define a codebase function that returns a codebase template
templates.Service = class Service
    deploy: (service, version) ->
        codebase = @codebase()







