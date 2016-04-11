//Recommended to set this for easier debugging
Error.stackTraceLimit = Infinity;

bubblebot = require('bubblebot');

//Loads configuration from configuration.json.
//Alternately, can pass an object with configuration values to use instead.
bubblebot.initialize_configuration();

//Create the bubblebot server
server = new bubblebot.Server()

//Do any customization here

//Start the server
server.start()