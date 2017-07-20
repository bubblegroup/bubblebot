github = exports


_gl = null

#Github does not allow accessing their API in parallel, so we have a lock that enforces
#only one request at a time talks to github.  
global_lock = ->
    _gl ?= u.Lock()
    return _gl

github.Repo = class Repo
    constructor: (@org, @project, @username, @access_token, @abbrev = 10) ->

    toString: -> 'Github:' + @org + '/' + @project

    #Returns either the canonical form, or null if not found
    resolve_commit: (commit) ->
        if not commit
            return null
        url = @commit_url commit
        res = @_request url
        if res.statusCode is 404
            return null
        return @extract(res, url).sha[..@abbrev]

    #Returns the full 40 character sha for a commit
    full_commit_sha: (commit) ->
        url = @commit_url commit
        res = @_request url
        if res.statusCode is 404
            return null
        return @extract(res, url).sha

    #Returns true if second can be fast-forwarded to first
    ahead_of: (first, second) ->
        res = @request @compare_url first, second
        return res.behind_by is 0

    #Given the raw github output of a commit, returns a human readable display
    display_commit: (commit) ->
        name = commit.author.name?.split(' ')[0]
        if not name
            name = commit.author.email
        return commit.sha[..@abbrev - 3] + ' - ' + name + ' - "' + commit.message[..80] + '"'

    #Returns a human-readable, newline seperated list of commits that first has but second doesn't
    show_new_commits: (first, second) ->
        res = @request @compare_url first, second
        return (@display_commit commit for commit in res.commits).join '\n'

    #Merges head into base, and returns the SHA.
    #Returns {success: bool, commit: <SHA>, message: <text>} where commit is present
    #on success, and message is present on failure
    merge: (base, head) ->
        #create a temporary branch to merge into
        tempname = 'merge-branch-' + Date.now()
        @create_branch tempname, base
        u.log 'Trying to merge ' + base + ' into ' + head
        url = @repo_url() + '/merges'
        res = @_request url, 'POST', {
            base: tempname
            head
            commit_message: 'Bubblebot automerge of ' + head + ' into ' + base
        }
        #successful merge
        if res.statusCode is 201
            commit = @extract(res, url).sha
            u.log 'merge successful: ' + commit
            return {success: true, commit}

        #base already contains head
        else if res.statusCode is 204
            u.log 'base already contains head, returning base: ' + base
            return {success: true, commit: base}

        #failed, return the message
        else
            u.log 'merge failed: ' + res.statusCode + ' ' + res.body
            message = res.statusCode + ' ' + res.body
            return {success: false, message}

    #Creates a new branch set to the given commit
    create_branch: (name, commit) ->
        @request @repo_url() + '/git/refs', 'POST', {
            ref: 'refs/heads/' + name
            sha: @full_commit_sha(commit) #github requires 40 characters for this
        }

    #Deletes the given branch
    delete_branch: (name) ->
        @request @repo_url() + '/git/refs/heads/' + name, 'DELETE'

    #Get the headers we use to make requests
    headers: ->
        headers = {Accept: 'application/vnd.github.v3+json'}
        if @username
            headers.Authorization = 'token ' + @access_token
            headers['User-Agent'] = @username
        return headers

    #The base url for the repository
    repo_url: -> 'https://api.github.com/repos/' + @org + '/' + @project

    #The url for a given commit
    commit_url: (commit) -> @repo_url() + '/commits/' + commit

    #the url for comparing two repos
    compare_url: (first, second) -> @repo_url() + '/compare/' + second + '...' + first

    #hits the url and returns the raw response.
    _request: (url, method, body) ->
        u.log 'Hitting github: ' + method + ' ' + url
        return global_lock().run =>
            u.log 'lock acquired'
            block = u.Block 'hitting github'
            options = {headers: @headers()}
            if method
                options.method = method
            if body
                options.body = JSON.stringify body
                options.headers['Content-Type'] = 'application/json'

            if (method ? 'GET').toLowerCase() is 'get'
                use_cache = true
                cached_data = github_cache.get url
                if cached_data?
                    options.headers['If-None-Match'] = cached_data.etag
            else
                use_cache = false

            request url, options, block.make_cb()
            res = block.wait()

            if res.statusCode is 304
                res = cached_data.res
            else if use_cache
                etag = res.headers['etag']
                if etag?
                    github_cache.set url, {etag, res}

            u.lock 'lock released'
            return res

    #Retrieves the body from the response, throwing an error if not retrievable
    extract: (res, url) ->
        if res.statusCode < 200 or res.statusCode > 299
            throw new Error 'error hitting ' + url + ': ' + res.statusCode + ': ' + res.body
        if not res.body
            return null
        try
            return JSON.parse res.body
        catch err
            throw new Error 'error hitting ' + url + ': could not parse body: ' + res.body

    #hits the url and returns the body, throwing an error if it's not a 200 response
    request: (url, method, body) -> @extract @_request(url, method, body), url

    #Generates a software package for cloning this repo to the given folder
    clone_software: (ref, destination) ->
        return (instance) =>
            instance.run "git clone -n git@github.com:#{@org}/#{@project}.git #{destination}", {timeout: 10*60*1000}
            if ref
                instance.run "cd #{destination} && git checkout #{ref}", {timeout: 5*60*1000}

    #READING A REPO

    #Given a commit, returns the SHA of the folder tree
    get_tree: (commit) ->
        commit = @full_commit_sha commit

        url = @repo_url() + '/git/commits/' + commit
        res = @_request url
        return @extract(res, url).tree.sha


    #Given an SHA of a tree, returns an array of it's sub-entries (blobs + more tree)
    list: (tree) ->
        url = @repo_url() + '/git/trees/' + tree
        res = @_request url
        return @extract(res, url).tree

    #Given a SHA of a blob, fetches the raw data.  If raw = true, returns the base64 encoded
    #string, otherwise we try to interpret it as utf8 text
    get_blob: (blob, raw) ->
        url = @repo_url() + '/git/blobs/' + blob
        res = @_request url
        data = @extract(res, url).content
        if raw
            return data
        else
            return (new Buffer data, 'base64').toString('utf8')


request = require 'request'
config = require './config'
u = require './utilities'
software = require './software'
bbobjects = require './bbobjects'

#Github rate limits, and since a lot of this information is fixed, cache it
github_cache = new bbobjects.Cache 24 * 60 * 60 * 1000