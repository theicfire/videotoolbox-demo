#pragma once

#import <AVFoundation/AVFoundation.h>

class DecodeRender {
 public:
  DecodeRender(CMVideoFormatDescriptionRef formatDescription, CMVideoDimensions videoDimensions);
  ~DecodeRender();
  void decode_render(CMSampleBufferRef sampleBuffer);
  void loop();

 private:
  struct Context;
  Context* m_context;
};