github = exports

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
        try
            url = @repo_url() + '/merges'
            res = @_request url, 'POST', {
                base: tempname
                head
                commit_message: 'Bubblebot automerge of ' + head + ' into ' + base
            }
            #successful merge
            if res.status is 201
                return {success: true, commit: @extract(res, url).sha}

            #base already contains head
            else if res.status is 204
                return {success: true, commit: base}

            #failed, return the message
            else
                message = JSON.parse(res.body).message
                return {success: false, message}

        finally
            @delete_branch tempname


    #Creates a new branch set to the given commit
    create_branch: (name, commit) ->
        @request @repo_url() + '/git/refs', 'POST', {
            ref: 'refs/heads/' + name
            sha: commit
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
        block = u.Block 'hitting github'
        options = {headers: @headers()}
        if method
            options.method = method
        if body
            options.body = JSON.stringify body
            options.headers['Content-Type'] = 'application/json'
        request url, options, block.make_cb()
        return block.wait()

    #Retrieves the body from the response, throwing an error if not retrievable
    extract: (res, url) ->
        if res.statusCode < 200 or res.statusCode > 299
            throw new Error 'error hitting ' + url + ': ' + res.statusCode + ': ' + res.body
        try
            return JSON.parse res.body
        catch err
            throw new Error 'error hitting ' + url + ': could not parse body: ' + res.body

    #hits the url and returns the body, throwing an error if it's not a 200 response
    request: (url, method, body) -> @extract @_request(url, method, body), url

    #Generates a software package for cloning this repo to the given folder
    clone_software: (ref, destination) ->
        return (instance) =>
            instance.run "git clone -n git@github.com:#{@org}/#{@project}.git #{destination}"
            if ref
                instance.run "cd #{destination} && git checkout #{ref}"



github_access_token = 'bb3ea1e6f7777a2f07f2efe1846e34dcdb5b8fbc'

github_get = (url, msg404) ->
    block = u.Block()
    request 'h' + url, {
        headers:
            Authorization: 'token ' + github_access_token
            Accept: 'application/vnd.github.v3+json'
            'User-Agent': 'jphaas'
    }, (err, res) ->
        if err
            block.fail err
        else
            block.success res
    res = block.wait()
    if res.statusCode is 404 and msg404
        throw new Error msg404
    if res.statusCode < 200 or res.statusCode > 299
        throw new Error 'github statusCode ' + res.statusCode + ': ' + JSON.stringify res
    return JSON.parse res.body



request = require 'request'
config = require './config'
u = require './utilities'
software = require './software'