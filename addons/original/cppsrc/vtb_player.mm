#include "vtb_player.h"

#include <exception>

#include <SDL2/SDL.h>

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#import "RenderingPipeline.h"

using namespace custom;

PlayerStatistics::PlayerStatistics() : m_index(0), m_currentFrame({0, 0, 0}) {
}

void PlayerStatistics::startFrame() {
    m_currentFrame = {m_index++, 0, 0};
}
void PlayerStatistics::endFrame() {
    m_frames.push_back(m_currentFrame);
}

void PlayerStatistics::startDecoding() {
    m_time = std::chrono::high_resolution_clock::now();
}
void PlayerStatistics::endDecoding() {
    const auto& delta = std::chrono::high_resolution_clock::now() - m_time;
    m_currentFrame.decodingTime = 1.0e-6 * std::chrono::duration_cast<std::chrono::microseconds>(delta).count();
}

void PlayerStatistics::startRendering() {
    m_time = std::chrono::high_resolution_clock::now();
}
void PlayerStatistics::endRendering() {
    const auto& delta = std::chrono::high_resolution_clock::now() - m_time;
    m_currentFrame.renderingTime = 1.0e-6 * std::chrono::duration_cast<std::chrono::microseconds>(delta).count();
}

std::vector<FrameStatistics> PlayerStatistics::getFrameStatistics() {
    return m_frames;
}

// PImpl helps to avoid having Cocoa/Objective C code in header
struct VTBPlayer::Context {
    AVAssetReader *reader;
    NSArray *videoTracks;
    CMVideoDimensions videoDimensions;
    VTDecompressionSessionRef decompressionSession;
    AVAssetReaderTrackOutput *videoTrackOutput;

    RenderingPipeline *pipeline;
    PlayerStatistics statistics;

    Context() : decompressionSession(NULL) {

    }

    ~Context() {
        if (decompressionSession) {
            VTDecompressionSessionInvalidate(decompressionSession);
            CFRelease(decompressionSession);
        }
    }

    void setup();
    bool processNextFrame();
    void render(CVImageBufferRef imageBuffer);

    static void didDecompress(
        void *decompressionOutputRefCon,
        void *sourceFrameRefCon,
        OSStatus status,
        VTDecodeInfoFlags infoFlags,
        CVImageBufferRef imageBuffer,
        CMTime presentationTimeStamp,
        CMTime presentationDuration
    );
};

VTBPlayer::VTBPlayer() : m_context(new Context()) {

}

VTBPlayer::~VTBPlayer() {
    if (m_context) {
        delete m_context;
    }
}

void VTBPlayer::play(const std::string& path) {
    open(path);

    SDL_SetHint(SDL_HINT_RENDER_DRIVER, "metal");
    if (SDL_InitSubSystem(SDL_INIT_VIDEO)) {
        throw std::runtime_error("SDL::InitSubSystem");
    }

    SDL_Window *window = SDL_CreateWindow(
        "VideoToolbox Decoder" /* title */,
        SDL_WINDOWPOS_CENTERED /* x */,
        SDL_WINDOWPOS_CENTERED /* y */,
        m_context->videoDimensions.width,
        m_context->videoDimensions.height,
        SDL_WINDOW_SHOWN
    );
    if (!window) {
        throw std::runtime_error("SDL::CreateWindow");
    }

    SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);
    CAMetalLayer *metalLayer = (__bridge CAMetalLayer *)SDL_RenderGetMetalLayer(renderer);

    // TODO why we destroy renderer here?
    SDL_DestroyRenderer(renderer);

    NSError *error;
    m_context->pipeline = [[RenderingPipeline alloc] initWithLayer:metalLayer error:&error];
    if (m_context->pipeline == nil) {
        throw std::runtime_error(error.localizedDescription.UTF8String);
    }

    bool quit = false;
    SDL_Event e;
    while (!quit) {
        while (SDL_PollEvent(&e) != 0) {
            switch (e.type) {
                case SDL_QUIT: 
                    quit = true;
                    break;
                default:
                    break;
            }
        }

        if (!m_context->processNextFrame()) {
            break;
        }

        // manual sync
        usleep(25000);
    }

    SDL_DestroyWindow(window);
    SDL_Quit();
}

std::vector<FrameStatistics> VTBPlayer::getFrameStatistics() {
    return m_context->statistics.getFrameStatistics();
}

void VTBPlayer::open(const std::string& path) {
    NSURL *url = [NSURL fileURLWithPath:[[NSString alloc] initWithUTF8String:path.c_str()]];
    NSDictionary *options = @{AVURLAssetPreferPreciseDurationAndTimingKey: @(YES)};
    AVAsset *asset = [[AVURLAsset alloc] initWithURL:url options:options];

    NSError *error = nil;
    m_context->reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error) {
        throw std::runtime_error(error.localizedDescription.UTF8String);
    }

    m_context->videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    m_context->setup();
}

bool VTBPlayer::Context::processNextFrame() {
    if (reader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sampleBuffer = [videoTrackOutput copyNextSampleBuffer];
        if (sampleBuffer) {
            statistics.startFrame();
            statistics.startDecoding();
            // use sync decoding
            VTDecodeFrameFlags flags = 0;
            VTDecodeInfoFlags flagOut;
            VTDecompressionSessionDecodeFrame(decompressionSession, sampleBuffer, flags, NULL, &flagOut);
            CFRelease(sampleBuffer);
            return true;
        }
    } else if (reader.status == AVAssetReaderStatusFailed) {
        // NSLog(@"Asset Reader failed with error: %@", self.assetReader.error);
    } else if (reader.status == AVAssetReaderStatusCompleted) {
        // NSLog(@"Reached the end of the video.");
    }

    return false;
}

void VTBPlayer::Context::setup() {
    AVAssetTrack *track = (AVAssetTrack *)videoTracks.firstObject;

    CMVideoFormatDescriptionRef formatDescription = (__bridge CMVideoFormatDescriptionRef)track.formatDescriptions.firstObject;
    videoDimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);

    NSDictionary *decoderSpecification = @{
        (NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @(YES)
    };

    NSDictionary *attributes = @{
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @(YES),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    VTDecompressionOutputCallbackRecord callBackRecord;
    callBackRecord.decompressionOutputCallback = didDecompress;
    callBackRecord.decompressionOutputRefCon = this;
    decompressionSession = NULL;
    VTDecompressionSessionCreate(kCFAllocatorDefault,
                                 formatDescription,
                                 (__bridge CFDictionaryRef)decoderSpecification,
                                 (__bridge CFDictionaryRef)attributes,
                                 &callBackRecord,
                                 &decompressionSession);

    videoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
    if ([reader canAddOutput:videoTrackOutput]) {
        [reader addOutput:videoTrackOutput];
    }

    BOOL didStart = [reader startReading];
    if (!didStart) {
        // TODO
    }
}

void VTBPlayer::Context::render(CVImageBufferRef imageBuffer) {
    statistics.endDecoding();

    statistics.startRendering();
    [pipeline render:imageBuffer];
    statistics.endRendering();

    statistics.endFrame();
}

/*
 This callback gets called everytime the decompresssion session decodes a frame
 */
void VTBPlayer::Context::didDecompress(void *decompressionOutputRefCon,
                                    void *sourceFrameRefCon,
                                    OSStatus status,
                                    VTDecodeInfoFlags infoFlags,
                                    CVImageBufferRef imageBuffer,
                                    CMTime presentationTimeStamp,
                                    CMTime presentationDuration) {
    if (status != noErr) {
        // NSLog(@"Error decompressing frame at time: %.3f error: %d infoFlags: %u",
        //       (float)presentationTimeStamp.value / presentationTimeStamp.timescale,
        //       (int)status,
        //       (unsigned int)infoFlags);
        return;
    }

    if (imageBuffer == NULL) {
        return;
    }

    if (!CMTIME_IS_VALID(presentationTimeStamp)) {
        // NSLog(@"Not a valid time for image buffer: %@", imageBuffer);
        return;
    }

    VTBPlayer::Context *context = (VTBPlayer::Context *)decompressionOutputRefCon;
    context->render(imageBuffer);
}
