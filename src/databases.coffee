databases = exports

databases.Postgres = class Postgres
    #rds_instance can be the rds_instance or an rds service: just needs to support endpoint
    constructor: (@rds_instance) ->

    #Gets the connection string for talking to this database
    get_connection_string: ->
        endpoint = @rds_instance.endpoint()
        if not endpoint?
            throw new Error 'endpoint not available!'

        {user, password, host, port, database} = endpoint
        conn_string = "postgres://#{user}:#{password}@#{host}:#{port}/#{database}"
        return conn_string

    #Returns [client, done]
    get_client: ->
        block = u.Block 'getting client'
        pg.connect @get_connection_string(), (err, client, done) ->
            if err
                block.fail err
            else
                block.success [client, done]
        client = block.wait()

        #This will happen if pg sends an error in between queries
        #Capture it and throw it if we try to use the client again
        client.on 'error', (err) ->
            client._had_error = err

        return client

    #Helper function for running queries
    _query: (client, cb, statement, args) ->
        if client._had_error
            throw client._had_error

        if args.length > 0
            client.query statement, args, cb
        else
            client.query statement, cb

    #Calls pg_dump and returns the result
    pg_dump: (options) ->
        {user, password, host, port, database} = @rds_instance.endpoint()
        command = "pg_dump -h #{host} -p #{port} -U #{user} -w #{options} #{database}"

        return u.run_local command, {env: {PGPASSWORD: password}}


    #Runs the query and returns the results
    query: (statement, args...) ->
        [client, done] = @get_client()
        try
            block = u.Block statement
            @_query client, block.make_cb(), statement, args
            return block.wait()
        finally
            done()

    #Runs the given function as a transaction
    #
    #Passes in an object with {rollback, query}
    #
    #Automatically commits on finish, automatically rolls back on uncaught errors
    transaction: (fn) ->
        [client, done] = @get_client()
        _should_commit = false
        _should_done = true
        _rolled_back = false

        t = {
            rollback: =>
                if _rolled_back
                    return

                _should_commit = false
                try
                    t.query 'ROLLBACK'
                catch err
                    _should_done = false
                    done err
                    throw err
                finally
                    _rolled_back = true

            query: (statement, args...) =>
                if _rolled_back
                    throw new Error 'already rolled back!'

                block = u.Block statement
                @_query client, block.make_cb(), statement, args
                return block.wait()

            #Convenience function for acquiring an advisory lock
            advisory_lock: (text) ->
                query = "SELECT pg_advisory_xact_lock(('x'||substr(md5($1),1,16))::bit(64)::bigint)"
                t.query query, text
        }
        try
            t.query 'BEGIN'
            _should_commit = true

            result = fn t

            if _should_commit
                t.query 'COMMIT'

            return result
        catch err
            t.rollback()
            throw err

        finally
            #if we haven't called done yet...
            if _should_done
                done()



pg = require 'pg'
u = require './utilities'