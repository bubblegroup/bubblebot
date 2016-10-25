#bug_report plugin backed by sentry

sentry = exports

sentry.report = (msg) ->
    dsn = config.get 'plugins.sentry.dsn'

    client = new raven.Client dsn, {
        stackFunction: (err) -> err.stack
        name: 'bubblebot'
    }

    tags = config.get 'plugins.sentry.tags'

    client.captureMessage msg, {tags}

#https://github.com/getsentry/raven-node -- for some reason the Sentry client is called raven
raven = require 'raven'
