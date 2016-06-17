//Recommended to set this for easier debugging
Error.stackTraceLimit = Infinity;

console.log('run.js: requiring bubblebot');

bubblebot = require('bubblebot');

console.log('run.js: initializing configuration');

//This should be the primary entrypoint for bubblebot customization
index = require('./lib/index')

//Loads configuration from configuration.json.
//Alternately, can pass an object with configuration values to use instead.
bubblebot.initialize_configuration(function (){
    console.log('run.js: creating server');

    //Create the bubblebot server
    server = new bubblebot.Server()

    console.log('run.js: starting server');

    //Do any customization here
    index.initialize(server)

    //Start the server
    server.start()

    console.log('run.js: server started');
});
