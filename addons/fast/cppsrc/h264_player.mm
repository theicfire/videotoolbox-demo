#include "h264_player.h"
#include <SDL2/SDL_syswm.h>

#include <fstream>
#include <memory>
#include <regex>
#include <vector>

#include <dirent.h>
#include <stdio.h>
#include <sys/types.h>
#include <unistd.h>

#include "decode_render.h"
#include "timer.h"

#include <CoreGraphics/CoreGraphics.h>
#include <AppKit/AppKit.h>

SDL_SysWMinfo get_system_window_info(SDL_Window *sdl_window) {
  SDL_SysWMinfo info;

  // Need to set the version field before querying for window info or SDL will throw an error.
  // https://github.com/spurious/SDL-mirror/blob/release-2.0.9/src/video/cocoa/SDL_cocoawindow.m#L1818-L1826
  SDL_VERSION(&info.version);

  // https://wiki.libsdl.org/SDL_GetWindowWMInfo
  if (!SDL_GetWindowWMInfo(sdl_window, &info)) {
    throw std::runtime_error("Unable to get system window info from SDL");
  };

  return info;
}

using namespace fast;

struct FrameEntry {
  int index;
  std::string name;
  std::vector<uint8_t> data;
};

std::vector<FrameEntry> load(const std::string &path) {
  DIR *dp = opendir(path.c_str());
  if (dp == NULL) {
    return {};
  }

  const std::regex pattern(".+_au_([0-9]+)\\.h264");
  std::vector<FrameEntry> frames;
  while (struct dirent *ep = readdir(dp)) {
    if (ep->d_type != DT_REG) {
      continue;
    }

    std::string name(ep->d_name, ep->d_namlen);
    std::smatch m;
    if (std::regex_match(name, m, pattern)) {
      std::ifstream file(path + "/" + name, std::ios::binary | std::ios::ate);

      std::streamsize size = file.tellg();
      file.seekg(0, std::ios::beg);

      std::vector<uint8_t> buffer(size);
      if (file.read((char *)buffer.data(), size)) {
        frames.push_back({std::stoi(m[1].str()), name, buffer});
      }
    }
  }
  closedir(dp);

  std::sort(frames.begin(), frames.end(),
            [](const auto &a, const auto &b) { return a.index < b.index; });

  return frames;
}


void MinimalPlayer::play(const std::string &path) {
  Timer t;
  std::vector<FrameEntry> frames = load(path);
  if (frames.empty()) {
    return;
  }

  int err = SDL_InitSubSystem(SDL_INIT_VIDEO);
  if (err) {
    printf("SDL_Init failed: %s\n", SDL_GetError());
    throw std::runtime_error("SDL::InitSubSystem");
  }

  SDL_Window *window = SDL_CreateWindow(
      "VideoToolbox Decoder" /* title */, SDL_WINDOWPOS_CENTERED /* x */,
      SDL_WINDOWPOS_CENTERED /* y */, 1920, 1080,
      SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
  if (!window) {
    throw std::runtime_error("SDL::CreateWindow");
  }
  SDL_SysWMinfo info = get_system_window_info(window);
  NSWindow *nswindow = info.info.cocoa.window;

  printf("Created window with backing scale factor %f\n", nswindow.backingScaleFactor);
  @autoreleasepool {
    //decodeRender = std::make_unique<DecodeRender>(window);

    size_t index = 0;
    bool quit = false;
    // frames.size()
    playing = true;
    while (!quit && index < frames.size()) {
      SDL_Event e;
      if (SDL_PollEvent(&e)) { }
      printf("Created window with backing scale factor %f\n", nswindow.backingScaleFactor);
      usleep(50000);
      if (index == 1) {
        //SDL_SetWindowSize(window, decodeRender->get_width(),
                          //decodeRender->get_height());
        SDL_SetWindowPosition(window, SDL_WINDOWPOS_CENTERED,
                              SDL_WINDOWPOS_CENTERED);
      }
    }
  };

  SDL_DestroyWindow(window);
  SDL_Quit();
}
