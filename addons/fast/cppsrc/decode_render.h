#pragma once
#include <chrono>
#include <string>
#include <vector>

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

  std::vector<FrameStatistics> getFrameStatistics();

 private:
  std::chrono::high_resolution_clock::time_point m_time;
  std::vector<FrameStatistics> m_frames;
  int m_index;
  FrameStatistics m_currentFrame;
};

class DecodeRender {
 public:
  DecodeRender(const std::vector<uint8_t>& frame);
  ~DecodeRender();
  void decode_render(const std::vector<uint8_t>& frame);
  void sdl_loop();
  std::vector<FrameStatistics> getFrameStatistics();

 private:
  struct Context;
  Context* m_context;
};