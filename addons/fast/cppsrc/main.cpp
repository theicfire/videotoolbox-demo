#include <atomic>
#include <chrono>
#include <iostream>
#include <memory>
#include <napi.h>
#include <sstream>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <thread>

#include "benchmark_fec.h"
#include "h264_player.h"

using namespace std;
using namespace Napi;

namespace app {
void StartClientWrapped(const CallbackInfo &info);
} // namespace app

void app::StartClientWrapped(const CallbackInfo &info) {
  Napi::Env env = info.Env();

  if (info.Length() < 1) {
    Napi::TypeError::New(env, "Wrong number of arguments")
        .ThrowAsJavaScriptException();
    return;
  }

  std::string filename = info[0].As<Napi::String>().ToString();
  printf("hello");
  benchmark_fec::run_benchmark();
}

Object InitAll(Env env, Object exports) {
  exports.Set("start_client", Function::New(env, app::StartClientWrapped));
  return exports;
}

NODE_API_MODULE(cloudbox, InitAll)
