$(document).ready ->
    input = $ '#input'
    output = $ '#output'

    uri_pieces = (piece for piece in document.location.href.split('/') when piece)
    session_id = uri_pieces[uri_pieces.length - 1]

    #For supporting up-arrow and down-arrow
    prev_commands = []
    command_pointer = 0
    saved_res = ''

    #On enter, clear the input and send the contents to the server
    input.on 'keydown', (evt) ->
        if evt.which is 13
            message = input.val()
            input.val ''

            prev_commands.push message
            command_pointer = prev_commands.length

            $.ajax {
                method: 'post'
                url: "/session/#{session_id}/write"
                data: {message}

                error: (jqXHR, textStatus, err) ->
                    res = '\nError sending to server: ' + textStatus
                    if err
                        res += ' ' + (err.stack ? err.message)
                    write_to_output res
            }
            return false

        else if evt.which is 38 #up arrow
            if command_pointer is prev_commands.length
                saved_res = input.val()
            command_pointer--
            if command_pointer < 0
                command_pointer = 0
            input.val prev_commands[command_pointer]
            return false

        else if evt.which is 40 #down arrow
            command_pointer++
            if command_pointer > prev_commands.length
                command_pointer = prev_commands.length
                return
            if command_pointer is prev_commands.length
                input.val saved_res
            else
                input.val prev_commands[command_pointer]
            return false


    #Writes the given message to our output log
    write_to_output = (message) ->
        at_bottom = output[0].scrollHeight - output.scrollTop() <= output.height() + 10 #the plus 10 is buffer for if it is almost at bottom

        content = output.val()
        content += message
        output.val content

        if at_bottom
            output.scrollTop output[0].scrollHeight - output.height()



    #Watch the server for new output
    timeout = 1
    long_poll = ->
        $.ajax {
            method: 'post'
            url: "/session/#{session_id}/get_latest"
            dataType: 'text'
            timeout: 60 * 60 * 1000 #hold it open for a long time
            success: (message) ->
                write_to_output message
                long_poll()
            error: (jqXHR, textStatus, err) ->
                res = '\nError polling server: ' + textStatus
                if err
                    res += ' ' + (err.stack ? err.message)
                console.log res

                #On failure, do an exponential back-off (capped at 30 seconds)
                timeout = Math.min(timeout * 2, 30*1000)
                setTimeout long_poll, timeout
        }

    long_poll()

    input.focus()
