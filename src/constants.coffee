constants = exports

#Special security groups
constants.ADMIN = 'admin'     #essentially, root access
constants.TRUSTED = 'trusted' #can escalate themselves to admin privileges (notifies admin)
constants.BASIC = 'basic'     #can perform unrestricted commands
constants.IGNORE = 'ignore'   #bot will ignore requests from this user

constants.BUBBLEBOT_ENV = 'bubblebot'