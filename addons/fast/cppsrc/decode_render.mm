#include "decode_render.h"

#include <exception>

#include <SDL2/SDL_syswm.h>

#include "nalu_rewriter.h"

#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <VideoToolbox/VideoToolbox.h>

#import "RenderingPipeline.h"

using namespace fast;

PlayerStatistics::PlayerStatistics() : m_index(0), m_currentFrame({0, 0, 0}) {}

void PlayerStatistics::startFrame() { m_currentFrame = {m_index++, 0, 0}; }
void PlayerStatistics::endFrame() { m_frames.push_back(m_currentFrame); }

void PlayerStatistics::startDecoding() {
  m_time = std::chrono::high_resolution_clock::now();
}
void PlayerStatistics::endDecoding() {
  const auto &delta = std::chrono::high_resolution_clock::now() - m_time;
  m_currentFrame.decodingTime =
      1.0e-3 *
      std::chrono::duration_cast<std::chrono::microseconds>(delta).count();
}

void PlayerStatistics::startRendering() {
  m_time = std::chrono::high_resolution_clock::now();
}
void PlayerStatistics::endRendering() {
  const auto &delta = std::chrono::high_resolution_clock::now() - m_time;
  m_currentFrame.renderingTime =
      1.0e-3 *
      std::chrono::duration_cast<std::chrono::microseconds>(delta).count();
}

std::vector<FrameStatistics> PlayerStatistics::getFrameStatistics() const {
  return m_frames;
}

struct DecodeRender::Context {
  dispatch_semaphore_t semaphore;
  dispatch_semaphore_t render_semaphore;
  CMMemoryPoolRef memoryPool;
  VTDecompressionSessionRef decompressionSession;
  CMVideoFormatDescriptionRef formatDescription;
  CMVideoDimensions videoDimensions;
  PlayerStatistics statistics;

  Context()
      : semaphore(NULL), memoryPool(NULL), decompressionSession(NULL),
        formatDescription(NULL) {
    semaphore = dispatch_semaphore_create(1);
    render_semaphore = dispatch_semaphore_create(1);
    memoryPool = CMMemoryPoolCreate(NULL);
  }

  ~Context() {
    // wait for the current rendering operation to be completed
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_wait(render_semaphore, DISPATCH_TIME_FOREVER);
    // semaphore must have initial value when dispose
    dispatch_semaphore_signal(semaphore);
    dispatch_semaphore_signal(render_semaphore);

    if (decompressionSession) {
      VTDecompressionSessionInvalidate(decompressionSession);
      CFRelease(decompressionSession);
    }

    if (formatDescription) {
      CFRelease(formatDescription);
    }

    if (memoryPool) {
      CMMemoryPoolInvalidate(memoryPool);
      CFRelease(memoryPool);
    }
  }

  void setup(std::vector<uint8_t> &frame);
  CMSampleBufferRef create(std::vector<uint8_t> &frame, bool multiple_nalu);
  void render(CVImageBufferRef imageBuffer);

  static void didDecompress(void *decompressionOutputRefCon,
                            void *sourceFrameRefCon, OSStatus status,
                            VTDecodeInfoFlags infoFlags,
                            CVImageBufferRef imageBuffer,
                            CMTime presentationTimeStamp,
                            CMTime presentationDuration);
};

std::vector<FrameStatistics> DecodeRender::getFrameStatistics() const {
  return m_context->statistics.getFrameStatistics();
}

DecodeRender::DecodeRender() : m_context(new Context()) {
  printf("Init DecodeRender\n");
}

DecodeRender::~DecodeRender() {
  if (m_context) {
    delete m_context;
  }
}

bool DecodeRender::decode_render(std::vector<uint8_t> &frame) {
  if (frame.size() == 0) {
    return true;
  }

  bool multiple_nalu = first_frame;
  if (first_frame) {
    m_context->setup(frame);
    first_frame = false;
  }

  NSLog(@"decode_render. Check for semaphore");
  if (dispatch_semaphore_wait(m_context->semaphore, DISPATCH_TIME_FOREVER) !=
      0) {
    NSLog(@"Failed to get semaphore in decode_render");
    dispatch_semaphore_signal(m_context->semaphore);
    return false;
  }

  CMSampleBufferRef sampleBuffer = m_context->create(frame, multiple_nalu);
  if (sampleBuffer == NULL) {
    NSLog(@"sampleBuffer is NULL");
    dispatch_semaphore_signal(m_context->semaphore);
    return false;
  }

  m_context->statistics.startFrame();
  m_context->statistics.startDecoding();

  VTDecodeFrameFlags flags = 0;
  // VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
  VTDecodeInfoFlags flagOut;
  NSLog(@"Call decompress with %p %p", m_context->decompressionSession,
        sampleBuffer);
  if (!m_context->decompressionSession) {
    NSLog(@"EEK, no decompressionSession");
  }
  OSStatus decode_ret = VTDecompressionSessionDecodeFrame(
      m_context->decompressionSession, sampleBuffer, flags, NULL, &flagOut);
  NSLog(@"Finish call to decompress. flagsOut: %d. Ret: %d", flagOut,
        decode_ret);
  CFRelease(sampleBuffer);

  if (dispatch_semaphore_wait(m_context->semaphore, DISPATCH_TIME_NOW) != 0) {
    NSLog(@"OH NO FAILURE to decode");
    // dispatch_semaphore_signal(m_context->semaphore);
    return false;
  }
  dispatch_semaphore_signal(m_context->semaphore);
  return true;
}

void DecodeRender::render_blank() {}

void DecodeRender::reset() {
  if (m_context == NULL) {
    return;
  }

  NSLog(@"Resetting. Waiting for semaphore");
  dispatch_semaphore_wait(m_context->semaphore, DISPATCH_TIME_FOREVER);

  if (m_context->decompressionSession) {
    NSLog(@"Resetting. Invalidate session");
    VTDecompressionSessionInvalidate(m_context->decompressionSession);
    CFRelease(m_context->decompressionSession);
    m_context->decompressionSession = NULL;
  }

  if (m_context->formatDescription) {
    CFRelease(m_context->formatDescription);
    m_context->formatDescription = NULL;
  }

  first_frame = true;

  NSLog(@"Resetting. Signal semaphore");
  dispatch_semaphore_signal(m_context->semaphore);
  NSLog(@"Resetting. Done");
}

int DecodeRender::get_width() { return m_context->videoDimensions.width; }

int DecodeRender::get_height() { return m_context->videoDimensions.height; }

void DecodeRender::setConnectionErrorVisible(bool visible) {}

void DecodeRender::Context::setup(std::vector<uint8_t> &frame) {
  formatDescription =
      webrtc::CreateVideoFormatDescription(frame.data(), frame.size());
  if (formatDescription == NULL) {
    throw std::runtime_error("webrtc::CreateVideoFormatDescription");
  }

  videoDimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);

  printf("Setup decompression with video width: %d, height: %d\n",
         videoDimensions.width, videoDimensions.height);

  NSDictionary *decoderSpecification = @{
    (NSString *)
    kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder : @(YES)
  };

  NSDictionary *attributes = @{
    (NSString *)kCVPixelBufferPixelFormatTypeKey :
        @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
    (NSString *)kCVPixelBufferMetalCompatibilityKey : @(YES),
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}
  };

  while (true) {
    VTDecompressionOutputCallbackRecord callBackRecord;
    callBackRecord.decompressionOutputCallback = didDecompress;
    callBackRecord.decompressionOutputRefCon = this;
    decompressionSession = NULL;
    NSLog(@"Call sessionCreate");
    OSStatus session_ret = VTDecompressionSessionCreate(
        kCFAllocatorDefault, formatDescription,
        (__bridge CFDictionaryRef)decoderSpecification,
        (__bridge CFDictionaryRef)attributes, &callBackRecord,
        &decompressionSession);
    NSLog(@"session_ret: %d. And now release... in 1s", session_ret);
    usleep(1000000);
    if (decompressionSession) {
      VTDecompressionSessionInvalidate(decompressionSession);
      CFRelease(decompressionSession);
    }
    usleep(1000000);
  }
}

CMSampleBufferRef DecodeRender::Context::create(std::vector<uint8_t> &frame,
                                                bool multiple_nalu) {
  CMSampleBufferRef sampleBuffer = NULL;
  if (multiple_nalu) {
    if (!webrtc::H264AnnexBBufferToCMSampleBuffer(frame.data(), frame.size(),
                                                  formatDescription,
                                                  &sampleBuffer, memoryPool)) {
      printf("ERROR: webrtc::H264AnnexBBufferToCMSampleBuffer\n");
    }
  } else {
    if (!webrtc::H264AnnexBBufferToCMSampleBufferSingleNALU(
            frame.data(), frame.size(), formatDescription, &sampleBuffer)) {
      printf("ERROR: webrtc::H264AnnexBBufferToCMSampleBuffer\n");
    }
  }
  return sampleBuffer;
}

void DecodeRender::Context::render(CVImageBufferRef imageBuffer) {}

/*
 This callback gets called everytime the decompresssion session decodes a frame
 */
void DecodeRender::Context::didDecompress(
    void *decompressionOutputRefCon, void *sourceFrameRefCon, OSStatus status,
    VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer,
    CMTime presentationTimeStamp, CMTime presentationDuration) {
  NSLog(@"Hit didDecompress");
  DecodeRender::Context *context =
      (DecodeRender::Context *)decompressionOutputRefCon;

  if (status != noErr) {
    NSLog(@"Error decompressing frame at time: %.3f error: %d infoFlags: %u",
          (float)presentationTimeStamp.value / presentationTimeStamp.timescale,
          (int)status, (unsigned int)infoFlags);
    dispatch_semaphore_signal(context->semaphore);
    return;
  }

  if (imageBuffer == NULL) {
    dispatch_semaphore_signal(context->semaphore);
    return;
  }

  dispatch_semaphore_signal(context->semaphore);
  // if (dispatch_semaphore_wait(context->render_semaphore, DISPATCH_TIME_NOW)
  // ==
  //     0) {
  //   NSLog(@"didDecompress Call render");
  //   dispatch_semaphore_signal(context->semaphore);
  //   @autoreleasepool {
  //     context->render(imageBuffer);
  //   };
  //   NSLog(@"didDecompress finish call render");
  // } else {
  //   printf("didDecompress Skip render\n");
  //   dispatch_semaphore_signal(context->semaphore);
  // }
}
