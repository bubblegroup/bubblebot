u = exports

#Creates a tarball out of the given directory and saves it to a temporary file.
#Returns the path to the temp file
u.create_tarball = (directory) ->
    tempfile = tmp.tmpNameSync()
    u.run_local "tar -cf #{tempfile} -C #{directory} ."
    return tempfile

u.run_local = (cmd, {can_fail}) ->
    child_process.execute


u.Block


child_process = require 'child_process'
tmp = require 'tmp'