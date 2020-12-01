function run_fast() {
  const addon = require("./addons/fast/addon.node");
  addon.benchmark_fec();
}

console.log("Starting client");
run_fast();
