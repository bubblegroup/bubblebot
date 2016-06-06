tasks = exports

#Define built in schedules that we initialize on server start
tasks.schedules =
    audit_all_instances:
        interval: 60 * 60 * 1000
        task: 'audit_instances'
        data: {auto_delete_mode: true}
    audit_all_instances_and_report:
        interval: 24 * 60 * 60 * 1000
        task: 'audit_instances'


#Define builtin tasks
tasks.builtin = {}

#Destroys the given instance
tasks.builtin.terminate_instance = ({id}) ->
    instance = bbobjects.instance 'EC2Instance', id
    instance.terminate()

#Checks with the instance's owner to see if they still need the instance
tasks.builtin.follow_up_on_instance = ({id}) ->
    instance = bbobjects.instance 'EC2Instance', id
    #If it has already been deleted, return
    if not instance.exists()
        return

    owner = instance.owner()
    if not owner
        u.report 'Following up on destroying an ec2 instance without an owner: ' + id
        return

    still_need = bbserver.do_cast 'boolean', u.ask('Hey, do you still need the server you created called ' + instance.get('name') + '?  If not, we will delete it for you', owner.id)
    if still_need
        params = {
            type: 'number'
            validate: bbobjects.validate_destroy_hours
        }
        hours = bbserver.do_cast params, u.ask("Great, we will keep it for now.  How many more hours do you think you need it around for?", owner.id)
        interval = hours * 60 * 60 * 1000
        instance.set 'expiration_time', Date.now() + (interval * 2)
        u.context().schedule_once interval, 'follow_up_on_instance', {id}
    else
        u.message owner.id, "Okay, we are terminating the server now..."
        instance.terminate()


#Goes through every instance and deletes ones that look unowned / dead
tasks.builtin.audit_instances = (data) ->
    {auto_delete_mode} = data ? {}

    #if we are in autodelete mode, we want to do this hourly, if we are in report
    #mode we want to do it daily.  we abort if the mode doesn't match our autodelete setting
    autodelete = if config.get('audit_instances_autodelete', false) then true else false
    auto_delete_mode ?= false
    if autodelete isnt auto_delete_mode
        return

    all_instances = bbobjects.get_all_instances()

    to_delete = []

    for instance in all_instances
        #if it is newer than 10 minutes, skip it
        if Date.now() - instance.launch_time() < 10 * 60 * 1000
            continue

        #if it is not saved in the database, this is a good candidate for deletion...
        if not instance.exists()
            if not instance.bubblebot_role()
                to_delete.push {instance, reason: 'instance not in database'}

        #otherwise, see if we know why it should exist
        else
            #make sure the parent exists
            parent = instance.parent()
            if not parent?.exists()
                to_delete.push {instance, reason: 'parent does not exist'}

            if parent.should_delete?(instance)
                to_delete.push {instance, reason: 'parent says we should delete this'}

    #If autodelete is set, actually do the delete, otherwise just announce.
    msg = (String(instance) + ': ' + reason for {instance, reason} in to_delete).join('\n')

    if autodelete
        u.announce 'Automatically cleaning up unused instances:\n\n' + msg
        for {instance, reason} in to_delete
            instance.terminate()
    else
        u.report "There are some instances that look like they should be deleted.
        To autodelete them, set bubblebot configuration setting audit_instances_autodelete to true.  They are:\n\n" + msg

#Generic task for calling a method on an object
tasks.builtin.call_object_method = ({object_type, object_id, method, properties}) ->
    bbobjects.instance(object_type, object_id)[method] properties


bbobjects = require './bbobjects'
bbserver = require './bbserver'
u = require './utilities'
config = require './config'