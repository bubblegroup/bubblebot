tasks = exports

constants = require './constants'

#Define built in schedules that we initialize on server start
tasks.schedules =
    audit_all_instances:
        interval: 20 * 60 * 1000
        type: 'Environment'
        id: constants.BUBBLEBOT_ENV
        method: 'audit_instances'
        params: [false, true, true]

    audit_all_instances_and_report:
        interval: 24 * 60 * 60 * 1000
        type: 'Environment'
        id: constants.BUBBLEBOT_ENV
        method: 'audit_instances'
        params: [false, false, true]

bbobjects = require './bbobjects'
bbserver = require './bbserver'
u = require './utilities'
config = require './config'