function run_fast() {
  const addon = require("./addons/fast/addon.node");
  addon.start_client("frames");
}

console.log("Starting client");
run_fast();
