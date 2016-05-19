tasks = exports

tasks.builtin = {}

tasks.builtin.terminate_instance = ({id}) ->
    instance = bbobjects.instance 'EC2Instance', id
    instance.terminate()

bbobjects = require './bbobjects'
