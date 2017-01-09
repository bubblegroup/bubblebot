databases = exports

databases.Postgres = class Postgres
    #rds_instance can be the rds_instance or an rds service: just needs to support endpoint
    constructor: (@rds_instance) ->

    toString: -> 'Postgres: ' + @rds_instance.toString()

    #Gets the connection string for talking to this database
    get_connection_string: ->
        endpoint = @get_endpoint()
        {user, password, host, port, database} = endpoint
        conn_string = "postgres://#{user}:#{password}@#{host}:#{port}/#{database}"
        return conn_string
        
    #Gets the endpoint for talking to this database
    get_endpoint: -> 
        endpoint = @rds_instance.endpoint()
        if not endpoint?
            throw new Error 'endpoint not available!'
        return endpoint

    #Gets the connection string in the format that dblink expects
    #
    #If force_internal is true, forces the internal ip address by doing a dns lookup
    #of the hostname (TODO: not guaranteed to work correctly if this is not in the same
    #zone as bubblebot)
    get_dblink_connection_string: (force_internal) ->
        endpoint = @get_endpoint()
        {user, password, host, port, database} = endpoint
        
        if force_internal
            block = u.Block 'dns lookup'
            dns.resolve host, block.make_cb()
            host = block.wait()
        
        conn_string = "user=#{user} password=#{password} host=#{host} port=#{port} dbname=#{database}"
        return conn_string
    
    #Gets a connection pool for talking to this database    
    get_pool: ->
        endpoint = @get_endpoint()
        key = JSON.stringify endpoint
        
        if not conn_pool_cache().get key
            {user, password, host, port, database} = endpoint
        
            pool = new pg.Pool {
                user
                database
                password
                host
                port
                max: 5
                idleTimeoutMillis: 30000
            }
            pool.on 'error', (err) ->
                u.log 'Error from pg connection pool to ' + host + ': ' + String(err)
            conn_pool_cache().set key, pool
        
        return conn_pool_cache().get key
        

    #Returns [client, done]
    get_client: ->
        client = new pg.Client @get_connection_string()
        block = u.Block 'connecting'
        client.connect block.make_cb()

        #This will happen if pg sends an error in between queries
        #Capture it and throw it if we try to use the client again
        client.on 'error', (err) ->
            client._had_error = err

        done = -> client.end()

        return [client, done]

    #Returns [client, done], uses connection pool
    get_pooled_client: ->
        block = u.Block 'connecting'
        
        @get_pool().connect (err, client, done) ->
            if err
                done err
                block.fail err
            else
                block.success [client, done]
                
        [client, done] = block.wait()

        return [client, done]

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
        {user, password, host, port, database} = @get_endpoint()
        command = "pg_dump -h #{host} -p #{port} -U #{user} -w #{options} #{database}"

        return u.run_local command, {env: {PGPASSWORD: password}}


    #Runs the query and returns the results
    query: (statement, args...) ->
        [client, done] = @get_pooled_client()
        try
            block = u.Block statement
            @_query client, block.make_cb(), statement, args
            return block.wait()
        finally
            done()

    #Runs the given function with a single client (but not as a transaction)
    #
    #passes in an object with {query, set_timeout, advisory_lock}
    with_client: (fn) ->
        [client, done] = @get_client()
        try
            _my_timeout = null

            t = {
                set_timeout: (timeout) -> _my_timeout = timeout

                query: (statement, args...) =>
                    block = u.Block statement
                    @_query client, block.make_cb(), statement, args
                    return block.wait(_my_timeout)

                #Convenience function for acquiring an advisory lock
                advisory_lock: (text) ->
                    query = "SELECT pg_advisory_xact_lock(('x'||substr(md5($1),1,16))::bit(64)::bigint)"
                    t.query query, text
            }
            return fn t

        finally
            done()

    #Runs the given function as a transaction
    #
    #Passes in an object with {rollback, query, set_timeout, advisory_lock}
    #
    #Automatically commits on finish, automatically rolls back on uncaught errors
    transaction: (fn) ->
        [client, done] = @get_client()
        _should_commit = false
        _should_done = true
        _rolled_back = false

        _my_timeout = null

        t = {
            set_timeout: (timeout) -> _my_timeout = timeout

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
                return block.wait(_my_timeout)

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


#We cache pools based on connection strings
_cache = null
conn_pool_cache =  ->
    _cache ?= new bbobjects.Cache 24 * 60 * 60 * 1000
    return _cache

pg = require 'pg'
u = require './utilities'
bbobjects = require './bbobjects'
dns = require 'dns'