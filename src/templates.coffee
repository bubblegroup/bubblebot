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