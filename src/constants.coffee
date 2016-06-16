constants = exports

#Special security groups
constants.ADMIN = 'admin'     #essentially, root access
constants.TRUSTED = 'trusted' #can escalate themselves to admin privileges (notifies admin)
constants.BASIC = 'basic'     #can perform unrestricted commands
constants.IGNORE = 'ignore'   #bot will ignore requests from this user

#The bubblebot environment
constants.BUBBLEBOT_ENV = 'bubblebot'


#Box statuses
constants.BUILDING = 'building'
constants.BUILD_FAILED = 'build failed'
constants.TEST_FAILED = 'test_failed'
constants.BUILD_COMPLETE = 'build complete'
constants.ACTIVE = 'active'
constants.FINISHED = 'finished'
constants.TERMINATING = 'terminating'