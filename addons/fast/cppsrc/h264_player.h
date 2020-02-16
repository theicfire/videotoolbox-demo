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

 public:
  void play(const std::string& path);
  void handle_event(SDL_Event &event);
};
}  // namespace fast
