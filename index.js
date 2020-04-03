function run_original() {
	const addon = require('./addons/original/addon.node');
	addon.start_client('hello.h264');
}

function run_fast() {
	const addon = require('./addons/fast/addon.node');
	addon.start_client('frames');
}

console.log('Starting client');
run_fast();
