#include "decode_render.h"

#include <exception>
#include <SDL2/SDL.h>

#include "nalu_rewriter.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#import "RenderingPipeline.h"

using namespace fast;

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
    m_currentFrame.decodingTime = 1.0e-3 * std::chrono::duration_cast<std::chrono::microseconds>(delta).count();
}

void PlayerStatistics::startRendering() {
    m_time = std::chrono::high_resolution_clock::now();
}
void PlayerStatistics::endRendering() {
    const auto& delta = std::chrono::high_resolution_clock::now() - m_time;
    m_currentFrame.renderingTime = 1.0e-3 * std::chrono::duration_cast<std::chrono::microseconds>(delta).count();
}

std::vector<FrameStatistics> PlayerStatistics::getFrameStatistics() const {
    return m_frames;
}


struct DecodeRender::Context {
    CMMemoryPoolRef memoryPool;
    VTDecompressionSessionRef decompressionSession;
    RenderingPipeline *pipeline;
    CMVideoFormatDescriptionRef formatDescription;
    CMVideoDimensions videoDimensions;

    PlayerStatistics statistics;

    Context() : memoryPool(NULL), decompressionSession(NULL) { }

    ~Context() {
        if (decompressionSession) {
            VTDecompressionSessionInvalidate(decompressionSession);
            CFRelease(decompressionSession);
        }

        if (memoryPool) {
            CMMemoryPoolInvalidate(memoryPool);
            CFRelease(memoryPool);
        }
    }

    void setup(std::vector<uint8_t>& frame);
    CMSampleBufferRef create(std::vector<uint8_t>& frame, bool multiple_nalu);
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

std::vector<FrameStatistics> DecodeRender::getFrameStatistics() const {
    return m_context->statistics.getFrameStatistics();
}

DecodeRender::DecodeRender(std::vector<uint8_t>& frame) : m_context(new Context()) {
    m_context->setup(frame);

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

    CGSize frameSize = CGSizeMake(m_context->videoDimensions.width, m_context->videoDimensions.height);
    NSError *error;
    m_context->pipeline = [[RenderingPipeline alloc] initWithLayer:metalLayer frameSize:frameSize error:&error];
    if (m_context->pipeline == nil) {
        throw std::runtime_error(error.localizedDescription.UTF8String);
    }
    decode_render_local(frame, true);
}

void DecodeRender::sdl_loop() {
    SDL_Event e;
    SDL_PollEvent(&e);
}

DecodeRender::~DecodeRender() {
    if (m_context) {
        delete m_context;
    }
    // TODO bring back
    // SDL_DestroyWindow(window);
    // SDL_Quit();
}

void DecodeRender::decode_render(std::vector<uint8_t>& frame) {
    if (frame.size() == 0) {
        return;
    }
    decode_render_local(frame, false);
}

void DecodeRender::decode_render_local(std::vector<uint8_t>& frame, bool multiple_nalu) {
    CMSampleBufferRef sampleBuffer = m_context->create(frame, multiple_nalu);
    if (sampleBuffer == NULL) {
        return;
    }

    m_context->statistics.startFrame();
    m_context->statistics.startDecoding();

    VTDecodeFrameFlags flags = 0;
    VTDecodeInfoFlags flagOut;
    VTDecompressionSessionDecodeFrame(m_context->decompressionSession, sampleBuffer, flags, NULL, &flagOut);
    CFRelease(sampleBuffer);
}

void DecodeRender::Context::setup(std::vector<uint8_t>& frame) {
    memoryPool = CMMemoryPoolCreate(NULL);

    formatDescription = webrtc::CreateVideoFormatDescription(frame.data(), frame.size());
    if (formatDescription == NULL) {
        throw std::runtime_error("webrtc::CreateVideoFormatDescription");
    }

    videoDimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);

    printf("Video width: %d, height: %d\n", videoDimensions.width, videoDimensions.height);

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

}

CMSampleBufferRef DecodeRender::Context::create(std::vector<uint8_t>& frame, bool multiple_nalu) {
    CMSampleBufferRef sampleBuffer = NULL;
    if (multiple_nalu) {
        if (!webrtc::H264AnnexBBufferToCMSampleBuffer(frame.data(), frame.size(), formatDescription, &sampleBuffer, memoryPool)) {
            printf("ERROR: webrtc::H264AnnexBBufferToCMSampleBuffer\n");
        }
    } else {
        // if (!webrtc::H264AnnexBBufferToCMSampleBuffer(frame.data(), frame.size(), formatDescription, &sampleBuffer, memoryPool)) {
        if (!webrtc::H264AnnexBBufferToCMSampleBufferSingleNALU(frame.data(), frame.size(), formatDescription, &sampleBuffer)) {
            printf("ERROR: webrtc::H264AnnexBBufferToCMSampleBufferSingleNALU\n");
        }
    }
    return sampleBuffer;
}

void DecodeRender::Context::render(CVImageBufferRef imageBuffer) {
    statistics.endDecoding();

    statistics.startRendering();
    [pipeline render:imageBuffer];
    statistics.endRendering();

    statistics.endFrame();
}

/*
 This callback gets called everytime the decompresssion session decodes a frame
 */
void DecodeRender::Context::didDecompress(void *decompressionOutputRefCon,
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

    DecodeRender::Context *context = (DecodeRender::Context *)decompressionOutputRefCon;
    context->render(imageBuffer);
}



