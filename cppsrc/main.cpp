#include <napi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <atomic>
#include <chrono>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include "window.h"

using namespace std;
using namespace Napi;

namespace app {
void StartClientWrapped(const CallbackInfo &info);
}  // namespace app

void app::StartClientWrapped(const CallbackInfo &info) {
  Napi::Env env = info.Env();

  if (info.Length() < 1) {
    Napi::TypeError::New(env, "Wrong number of arguments")
        .ThrowAsJavaScriptException();
    return;
  }
  std::string cool = info[0].As<Napi::String>().ToString();
  std::cout << cool << std::endl;
  run_program(cool);
}

Object InitAll(Env env, Object exports) {
  exports.Set("start_client", Function::New(env, app::StartClientWrapped));
  return exports;
}

NODE_API_MODULE(cloudbox, InitAll)
