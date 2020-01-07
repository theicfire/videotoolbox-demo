#pragma once
#include <chrono>
#include <string>
#include <vector>

namespace fast {
  struct FrameStatistics {
    int index;
    double decodingTime;
    double renderingTime;
  };

  class PlayerStatistics {
   public:
    PlayerStatistics();

    void startFrame();
    void endFrame();

    void startDecoding();
    void endDecoding();

    void startRendering();
    void endRendering();

    std::vector<FrameStatistics> getFrameStatistics() const;

   private:
    std::chrono::high_resolution_clock::time_point m_time;
    std::vector<FrameStatistics> m_frames;
    int m_index;
    FrameStatistics m_currentFrame;
  };

  class DecodeRender {
   public:
    DecodeRender(std::vector<uint8_t>& frame);
    ~DecodeRender();
    void decode_render(std::vector<uint8_t>& frame);
    void decode_render_local(std::vector<uint8_t>& frame, bool multiple_nalu);
    void sdl_loop();
    std::vector<FrameStatistics> getFrameStatistics() const;

   private:
    struct Context;
    Context* m_context;
  };
}
