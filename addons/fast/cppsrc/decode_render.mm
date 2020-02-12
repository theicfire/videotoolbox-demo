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
    dispatch_semaphore_t semaphore;
    CMMemoryPoolRef memoryPool;
    VTDecompressionSessionRef decompressionSession;
    RenderingPipeline *pipeline;
    CMVideoFormatDescriptionRef formatDescription;
    CMVideoDimensions videoDimensions;
    PlayerStatistics statistics;
    CALayer *connectionErrorLayer;

    Context() : memoryPool(NULL), decompressionSession(NULL) {
        // Deconstructor requires semaphore to be at least the starting value. So we make the starting value 0.
        // Otherwise, we get EXC_BAD_INSTRUCTION
        semaphore = dispatch_semaphore_create(0);
        dispatch_semaphore_signal(semaphore);
    }

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

DecodeRender::DecodeRender(SDL_Window* window) : m_context(new Context()) {
    SDL_SetHint(SDL_HINT_RENDER_DRIVER, "metal");
    SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);
    CAMetalLayer *metalLayer = (__bridge CAMetalLayer *)SDL_RenderGetMetalLayer(renderer);

    // TODO why we destroy renderer here?
    SDL_DestroyRenderer(renderer);

    NSError *error;
    m_context->pipeline = [[RenderingPipeline alloc] initWithLayer:metalLayer error:&error];
    if (m_context->pipeline == nil) {
        throw std::runtime_error(error.localizedDescription.UTF8String);
    }

    m_context->pipeline.completedHandler = ^{
        dispatch_semaphore_signal(m_context->semaphore);
    };

    NSString *fileName = [NSString stringWithFormat:@"poor_connection%dx.bmp", (int)metalLayer.contentsScale];
    NSImage *connectionErrorImage = [[NSImage alloc] initWithContentsOfFile:fileName];
    if (connectionErrorImage == nil) {
        printf("Error: failed to load image: %s\n", fileName.UTF8String);
        return;
    }

    m_context->connectionErrorLayer = [CALayer layer];
    m_context->connectionErrorLayer.frame = metalLayer.bounds;
    m_context->connectionErrorLayer.contentsScale = metalLayer.contentsScale;
    m_context->connectionErrorLayer.contentsGravity = kCAGravityBottomRight;
    m_context->connectionErrorLayer.contents = connectionErrorImage;

    [metalLayer addSublayer:m_context->connectionErrorLayer];    
}

DecodeRender::~DecodeRender() {
    if (m_context) {
        delete m_context;
    }
}

void DecodeRender::decode_render(std::vector<uint8_t>& frame) {
    if (frame.size() == 0) {
        return;
    }

    dispatch_semaphore_wait(m_context->semaphore, DISPATCH_TIME_FOREVER);

    bool multiple_nalu = first_frame;
    if (first_frame) {
        m_context->setup(frame);
        first_frame = false;
    }

    CMSampleBufferRef sampleBuffer = m_context->create(frame, multiple_nalu);
    if (sampleBuffer == NULL) {
        dispatch_semaphore_signal(m_context->semaphore);
        return;
    }

    m_context->statistics.startFrame();
    m_context->statistics.startDecoding();

    VTDecodeFrameFlags flags = 0;
    VTDecodeInfoFlags flagOut;
    VTDecompressionSessionDecodeFrame(m_context->decompressionSession, sampleBuffer, flags, NULL, &flagOut);
    CFRelease(sampleBuffer);
}

void DecodeRender::render_blank() {
    dispatch_semaphore_wait(m_context->semaphore, DISPATCH_TIME_FOREVER);

    if (![m_context->pipeline render:NULL]) {
        dispatch_semaphore_signal(m_context->semaphore);
    }
}

int DecodeRender::get_width() {
    return m_context->videoDimensions.width;
}

int DecodeRender::get_height() {
    return m_context->videoDimensions.height;
}

void DecodeRender::setConnectionErrorVisible(bool visible) {
    m_context->connectionErrorLayer.hidden = visible ? NO : YES;
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
        if (!webrtc::H264AnnexBBufferToCMSampleBufferSingleNALU(frame.data(), frame.size(), formatDescription, &sampleBuffer)) {
            printf("ERROR: webrtc::H264AnnexBBufferToCMSampleBuffer\n");
        }
    }
    return sampleBuffer;
}

void DecodeRender::Context::render(CVImageBufferRef imageBuffer) {
    statistics.endDecoding();

    statistics.startRendering();
    if (![pipeline render:imageBuffer]) {
        dispatch_semaphore_signal(semaphore);
    }
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
    DecodeRender::Context *context = (DecodeRender::Context *)decompressionOutputRefCon;

    if (status != noErr) {
        NSLog(@"Error decompressing frame at time: %.3f error: %d infoFlags: %u",
              (float)presentationTimeStamp.value / presentationTimeStamp.timescale,
              (int)status,
              (unsigned int)infoFlags);
        dispatch_semaphore_signal(context->semaphore);
        return;
    }

    if (imageBuffer == NULL) {
        dispatch_semaphore_signal(context->semaphore);
        return;
    }

    @autoreleasepool {
        context->render(imageBuffer);
    };
}



