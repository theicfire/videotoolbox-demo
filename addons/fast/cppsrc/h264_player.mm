#include "h264_player.h"

#include <vector>
#include <memory>
#include <fstream>
#include <regex>

#include <stdio.h>
#include <sys/types.h>
#include <dirent.h>
#include <unistd.h>

#include <SDL2/SDL_syswm.h>

#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>

#include "decode_render.h"
#include "timer.h"

using namespace fast;

struct FrameEntry {
    int index;
    std::string name;
    std::vector<uint8_t> data;
};

struct InternalLoopContext {
    std::vector<FrameEntry> frames;
    size_t index;
    void *metalLayerPointer;
    bool quit;
    Timer t;
    SDL_Window *window;
};

@interface MetalView: NSView

@property (nonatomic) CAMetalLayer *metalLayer;

@end

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
    InternalLoopContext context;
    context.frames = load(path);
    if (context.frames.empty()) {
        return;
    }

    if (SDL_InitSubSystem(SDL_INIT_VIDEO)) {
        throw std::runtime_error("SDL::InitSubSystem");
    }

    context.window = SDL_CreateWindow(
        "VideoToolbox Decoder" /* title */,
        SDL_WINDOWPOS_CENTERED /* x */,
        SDL_WINDOWPOS_CENTERED /* y */,
        1920,
        1080,
        SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI
    );
    if (!context.window) {
        throw std::runtime_error("SDL::CreateWindow");
    }

    SDL_SysWMinfo info;
    if (!SDL_GetWindowWMInfo(context.window, &info)) {
        throw std::runtime_error("SDL::GetWindowWMInfo");
    }

    printf("Number of frames: %lu\n", context.frames.size());

    // this is out main pool with long lifetime
    @autoreleasepool {
        NSView *view = info.info.cocoa.window.contentView;

        MetalView *metalView = [MetalView new];
        metalView.translatesAutoresizingMaskIntoConstraints = NO;
        [view addSubview:metalView];

        [NSLayoutConstraint activateConstraints:@[
            [metalView.topAnchor constraintEqualToAnchor:view.topAnchor],
            [metalView.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
            [metalView.leftAnchor constraintEqualToAnchor:view.leftAnchor],
            [metalView.rightAnchor constraintEqualToAnchor:view.rightAnchor]
        ]];

        context.metalLayerPointer = (__bridge void *)metalView.metalLayer;
        decodeRender = std::make_unique<DecodeRender>(context.metalLayerPointer);

        context.index = 0;
        context.quit = false;
        // frames.size()
        playing = true;
        while (!context.quit) {
            // keep starting loop
            internal_loop(&context);
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

    SDL_DestroyWindow(context.window);
    SDL_Quit();
}

// IMPORTANT autorelease pool must be released after each restart, so we use this internal loop function
void MinimalPlayer::internal_loop(void *context) {
    InternalLoopContext *p = (InternalLoopContext *)context;
    // this is out short lifetime pool
    @autoreleasepool {
        while (!p->quit && p->index < p->frames.size()) {
            SDL_Event e;
            if (SDL_PollEvent(&e)) {
                handle_event(e);
            }
            if (!playing) {
              continue;
            }
            if (restarting || p->t.getElapsedMilliseconds() > 5000) {
              printf("Restarting\n");
              decodeRender = nullptr;
              printf("Done deleting\n");
              decodeRender = std::make_unique<DecodeRender>(p->metalLayerPointer);
              printf("Created new DecodeRender\n");
              p->index = 0;
              restarting = false;
              p->t.reset();
              // IMPORTANT return from loop and trigger autorelease pool to release
              break;
            }
            decodeRender->decode_render(p->frames[p->index++].data);
            if (p->index == 1) {
                SDL_SetWindowSize(p->window, decodeRender->get_width(), decodeRender->get_height());
                SDL_SetWindowPosition(p->window, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);
            }
        }
    };
}

@implementation MetalView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.metalLayer = [CAMetalLayer layer];
        self.metalLayer.device = MTLCreateSystemDefaultDevice();
        self.metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;

        self.layer = self.metalLayer;
        self.wantsLayer = YES;
    }
    return self;
}

@end
