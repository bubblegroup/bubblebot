#!/usr/bin/env node

command = process.argv[2];
child_process = require('child_process');


run_command = function() {
    if (!bubblebot[command]) {
        bubblebot.print_help();
        process.exit()
    } else {
        bubblebot[command].apply(this, process.argv.slice(3));
    }
}


var not_installed;
try {
    bubblebot = require(process.cwd() + '/node_modules/bubblebot');
    not_installed = false;
} catch (err) {
    not_installed = true;
}
if (not_installed) {
    if (command === 'install') {
        console.log('Adding bubblebot to package.json and installing: npm install --save bublebot');
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
} else {
    run_command();
}


