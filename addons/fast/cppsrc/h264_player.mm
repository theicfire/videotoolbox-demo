#include "h264_player.h"

#include <vector>
#include <memory>
#include <fstream>
#include <regex>

#include <stdio.h>
#include <sys/types.h>
#include <dirent.h>
#include <unistd.h>

#import "decode_render.h"

using namespace custom;

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
    const auto& frames = load(path);
    if (frames.empty()) {
        return;
    }

    printf("Number of frames: %lu\n", frames.size());
    // use first frame to initialize decoder session
    std::unique_ptr<DecodeRender> decodeRender = std::make_unique<DecodeRender>(frames[0].data);

    size_t index = 0;
    bool quit = false;
    while (!quit && index < frames.size()) {
        decodeRender->sdl_loop();
        decodeRender->decode_render(frames[index++].data);
        // manual sync
        usleep(25000);
    }
    for (const auto& e : decodeRender->getFrameStatistics()) {
      printf("#%d: Decode took %f ms, render took %f ms\n", e.index,
             e.decodingTime, e.renderingTime);
    }
}
