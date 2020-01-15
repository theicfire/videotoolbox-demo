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

void MinimalPlayer::play(const std::string& path) {
    std::vector<FrameEntry> frames = load(path);
    if (frames.empty()) {
        return;
    }

    if (SDL_InitSubSystem(SDL_INIT_VIDEO)) {
        throw std::runtime_error("SDL::InitSubSystem");
    }

    SDL_Window* window = SDL_CreateWindow(
        "VideoToolbox Decoder" /* title */,
        SDL_WINDOWPOS_CENTERED /* x */,
        SDL_WINDOWPOS_CENTERED /* y */,
        1920,
        1080,
        SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE
    );
    if (!window) {
        throw std::runtime_error("SDL::CreateWindow");
    }
    printf("Number of frames: %lu\n", frames.size());

    @autoreleasepool {
        std::unique_ptr<DecodeRender> decodeRender = std::make_unique<DecodeRender>(window);

        size_t index = 0;
        bool quit = false;
        while (!quit && index < frames.size()) {
            SDL_Event e;
            SDL_PollEvent(&e);
            decodeRender->decode_render(frames[index++].data);
            if (index == 1) {
                SDL_SetWindowSize(window, decodeRender->get_width(), decodeRender->get_height());
                SDL_SetWindowPosition(window, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);
            }
            // manual sync
            usleep(25000);
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
