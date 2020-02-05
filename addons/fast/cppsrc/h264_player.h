#pragma once

#include <chrono>
#include <string>
#include <vector>
#include <SDL2/SDL.h>
#include "decode_render.h"

namespace fast {
class MinimalPlayer {
 std::unique_ptr<DecodeRender> decodeRender = nullptr;
 public:
  void play(const std::string& path);
  void handle_event(SDL_Event &event);
};
}  // namespace fast
