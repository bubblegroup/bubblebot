#!/usr/bin/env node

command = process.argv[2];
child_process = require('child_process');
fs = require('fs');

run_command = function() {
    if (!bubblebot[command]) {
        bubblebot.print_help();
        process.exit()
    } else {
        bubblebot[command].apply(this, process.argv.slice(3));
    }
}

function exists(file) {
    try {
        fs.statSync(file);
        return true
    } catch (err) {
        return false;
    }
}

var not_installed;
if (exists(process.cwd() + '/node_modules/bubblebot')) {
    not_installed = false;
    bubblebot = require(process.cwd() + '/node_modules/bubblebot');
    try {
        child_process.execSync('npm install');
    } catch (err) {
        console.log(err.stack);
    }
    if (exists(process.cwd() + '/lib/index.js')) {
        require(process.cwd() + '/lib/index');
    }
} else {
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


