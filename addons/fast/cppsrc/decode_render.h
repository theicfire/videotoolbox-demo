#pragma once
#include <SDL2/SDL.h>
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
  int m_index = 0;
  FrameStatistics m_currentFrame;
};

class DecodeRender {
public:
  DecodeRender();
  ~DecodeRender();
  bool decode_render(std::vector<uint8_t> &frame);
  void decode_render_local(std::vector<uint8_t> &frame, bool multiple_nalu);
  void reset();
  int get_width();
  int get_height();
  void setConnectionErrorVisible(bool visible);
  std::vector<FrameStatistics> getFrameStatistics() const;

private:
  struct Context;
  Context *m_context = nullptr;
  bool first_frame = true;
};
} // namespace fast
