#Metrics plugin backed by Librato

librato = exports

get_agent_token = -> config.get 'plugins.librato.agent_token'

librato.get_server_metrics_software = ->
    pkg = new software.Software()
    token = get_agent_token()
    if not token
        throw new Error 'missing setting for Librato: plugins.librato.agent_token'

    pkg.run 'curl -s https://metrics-api.librato.com/agent_installer/' + token

    return pkg

config = require './../config'
software = require './../software'