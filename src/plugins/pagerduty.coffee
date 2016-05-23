pagerduty = exports

pagerduty.name = -> 'pagerduty'

get_service_key = -> config.get 'plugins.pagerduty.integration_key'

URI = 'https://events.pagerduty.com/generic/2010-04-15/create_event.json'

send_to_pagerduty = (body) ->
    block = u.Block 'pagerduty api'
    headers =
        'Content-Type': 'application/json'
    request {method: 'POST', uri: URI, body: JSON.stringify(body), headers}, block.make_cb()
    res = block.wait()

    if not (200 <= res.statusCode <= 299)
        msg = 'Error reporting incident to pagerduty: ' + res.statusCode + ' ' + res.body
        u.report msg
        u.announce msg

pagerduty.report_down = (object, downtime) -> send_to_pagerduty {
    service_key: get_service_key()
    event_type: 'trigger'
    incident_key: object.type + '_' + object.id
    description: 'Bubblebot monitoring: Cannot reach ' + String(object) + ' after ' + u.format_time(downtime)
    details:
        object_type: object.type
        object_id: object.id
        downtime
}


pagerduty.report_up = (object, downtime) -> send_to_pagerduty {
    service_key: get_service_key()
    event_type: 'resolve'
    incident_key: object.type + '_' + object.id
    description: 'Bubblebot monitoring: ' + String(object) + ' recovered after ' + u.format_time(downtime)
    details:
        object_type: object.type
        object_id: object.id
        downtime
}


config = require './../config'
request = require 'request'
u = require './../utilities'