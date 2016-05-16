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
        "
    ]

    rollbacks: [

    ]

    max: -> @migrations.length - 1

    get: (num) -> @migrations[num]

    get_dev: -> null

    get_rollback_dev: -> null

    get_rollback: (num) -> @rollbacks[num]