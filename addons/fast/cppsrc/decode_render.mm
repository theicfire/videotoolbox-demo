#include <exception>

#include <SDL2/SDL.h>

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <stdexcept>

#import "RenderingPipeline.h"
#import "decode_render.h"


struct DecodeRender::Context {
    VTDecompressionSessionRef decompressionSession;
    RenderingPipeline *pipeline;
    CMVideoFormatDescriptionRef formatDescription;
    CMVideoDimensions videoDimensions;

    Context() : decompressionSession(NULL) {

    }

    ~Context() {
        if (decompressionSession) {
            VTDecompressionSessionInvalidate(decompressionSession);
            CFRelease(decompressionSession);
        }
    }

    void setup();
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

DecodeRender::DecodeRender(CMVideoFormatDescriptionRef formatDescription, CMVideoDimensions videoDimensions) : m_context(new Context()) {
    m_context->formatDescription = formatDescription;
    m_context->videoDimensions = videoDimensions;
    m_context->setup();
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
}

void DecodeRender::loop() {
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

void DecodeRender::decode_render(CMSampleBufferRef sampleBuffer) {
            VTDecodeFrameFlags flags = 0;
            VTDecodeInfoFlags flagOut;
            VTDecompressionSessionDecodeFrame(m_context->decompressionSession, sampleBuffer, flags, NULL, &flagOut);
            CFRelease(sampleBuffer);
}

void DecodeRender::Context::setup() {
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

void DecodeRender::Context::render(CVImageBufferRef imageBuffer) {
    [pipeline render:imageBuffer];
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

    if (!CMTIME_IS_VALID(presentationTimeStamp)) {
        // NSLog(@"Not a valid time for image buffer: %@", imageBuffer);
        return;
    }

    DecodeRender::Context *context = (DecodeRender::Context *)decompressionOutputRefCon;
    context->render(imageBuffer);
}
