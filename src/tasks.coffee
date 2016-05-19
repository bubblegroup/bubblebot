tasks = exports

tasks.builtin = {}

#Destroys the given instance
tasks.builtin.terminate_instance = ({id}) ->
    instance = bbobjects.instance 'EC2Instance', id
    instance.terminate()

#Checks with the instance's owner to see if they still need the instance
tasks.builtin.follow_up_on_instance = ({id}) ->
    instance = bbobjects.instance 'EC2Instance', id
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
        u.context().schedule_once interval, 'follow_up_on_instance', {id}
    else
        u.message owner.id, "Okay, we are terminating the server now..."
        instance.terminate()


bbobjects = require './bbobjects'
bbserver = require './bbserver'