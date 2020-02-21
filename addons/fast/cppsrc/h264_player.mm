#include "h264_player.h"

#include <vector>
#include <memory>
#include <fstream>
#include <regex>

#include <stdio.h>
#include <sys/types.h>
#include <dirent.h>
#include <unistd.h>

#include "decode_render.h"
#include "timer.h"

using namespace fast;

struct FrameEntry {
    int index;
    std::string name;
    std::vector<uint8_t> data;
};

std::vector<FrameEntry> load(const std::string& path) {
    DIR *dp = opendir (path.c_str());
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

    std::sort(frames.begin(), frames.end(), [](const auto& a, const auto& b) {
        return a.index < b.index;
    });

    return frames;
}

void MinimalPlayer::handle_event(SDL_Event &event) {
  switch (event.type) {
    case SDL_KEYDOWN: {
        if (event.key.keysym.sym == 'h') {
            if (error_banner_visible) {
              printf("Hide error banner\n");
              decodeRender->setConnectionErrorVisible(false);
              error_banner_visible = false;
            } else {
              printf("Show error banner\n");
              decodeRender->setConnectionErrorVisible(true);
              error_banner_visible = true;
            }
        } else if (event.key.keysym.sym == 'p') {
            printf("Pause video\n");
            playing = !playing;
            if (!playing) {
                // IMPORTANT do this only once for pause
                decodeRender->render_blank();
            }
        } else if (event.key.keysym.sym == 'r') {
            playing = true;
            restarting = true;
        }
    }
  }
}

void MinimalPlayer::play(const std::string& path) {
    Timer t;
    std::vector<FrameEntry> frames = load(path);
    if (frames.empty()) {
        return;
    }

    if (SDL_InitSubSystem(SDL_INIT_VIDEO)) {
        throw std::runtime_error("SDL::InitSubSystem");
    }

    SDL_Window *window = SDL_CreateWindow(
        "VideoToolbox Decoder" /* title */,
        SDL_WINDOWPOS_CENTERED /* x */,
        SDL_WINDOWPOS_CENTERED /* y */,
        1920,
        1080,
        SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI
    );
    if (!window) {
        throw std::runtime_error("SDL::CreateWindow");
    }

    printf("Number of frames: %lu\n", frames.size());

    @autoreleasepool {
        decodeRender = std::make_unique<DecodeRender>(window);

        size_t index = 0;
        bool quit = false;
        // frames.size()
        playing = true;
        while (!quit && index < frames.size()) {
            SDL_Event e;
            if (SDL_PollEvent(&e)) {
                handle_event(e);
            }
            if (!playing) {
              continue;
            }
            if (restarting || t.getElapsedMilliseconds() > 5000) {
              printf("Restarting\n");
              decodeRender->reset();
              index = 0;
              restarting = false;
              t.reset();
            }
            Timer t2;
            decodeRender->decode_render(frames[index++].data);
            printf("t2 is %f\n", t2.getElapsedMilliseconds());
            usleep(20000);
            if (index == 1) {
                SDL_SetWindowSize(window, decodeRender->get_width(), decodeRender->get_height());
                SDL_SetWindowPosition(window, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);
            }
        }

        FILE* file = fopen("result.csv", "w");
        if (file != NULL) {
            fprintf(file, "frame,decoding,rendering\n");
            for (const auto& e : decodeRender->getFrameStatistics()) {
                fprintf(file, "%d,%f,%f\n", e.index, e.decodingTime, e.renderingTime);
            }
            fclose(file);
        }
    };

    SDL_DestroyWindow(window);
    SDL_Quit();
}
