#!/usr/bin/env node

bubblebot = require('..');

command = process.argv[2];

if (command === 'install') {
    bubblebot.install();
} else if (command === 'publish') {
    bubblebot.publish();
} else {
    bubblebot.print_help();
    process.exit()
}
