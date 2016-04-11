#!/usr/bin/env node

command = process.argv[2];
child_process = require('child_process');


run_command = function() {
    if (command === 'install') {
        bubblebot.install();
    } else if (command === 'publish') {
        bubblebot.publish();
    } else {
        bubblebot.print_help();
        process.exit()
    }
}



try {
    bubblebot = require(process.cwd() + '/node_modules/bubblebot');
    run_command();
} catch (err) {
    if (command === 'install') {
        child_process.exec('npm install --save bubblebot', {cwd: process.cwd()}, function(err, stdout, stderr) {
            if (err) {
                console.log(stdout);
                console.log(stderr);
                process.exit();
            } else {
                bubblebot = require(process.cwd() + '/node_modules/bubblebot');
                run_command();
            }
        });
    } else {
        console.log('Bubblebot is not installed in this directory.  To install, run "bubblebot install"');
        process.exit();
    }
}


