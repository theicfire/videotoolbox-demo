#pragma once

#include <chrono>
#include <string>
#include <vector>

#include "decode_render.h"

namespace fast {
class MinimalPlayer {
 std::unique_ptr<DecodeRender> decodeRender = nullptr;
 bool playing = false;
 bool restarting = false;
 bool error_banner_visible = true;

 void setup_window_size();
 // TODO void pointer is not a perfect solution
 void internal_loop(void *context);

 public:
  void play(const std::string& path);
  void handle_event(SDL_Event &event);
};
}  // namespace fast
