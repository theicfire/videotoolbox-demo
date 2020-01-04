#pragma once

#include <chrono>
#include <string>
#include <vector>

namespace custom {
class MinimalPlayer {
 public:
  explicit MinimalPlayer();
  ~MinimalPlayer();
  void play(const std::string& path);

 private:
  void open(const std::string& path);

  // PImpl
  struct Context;
  Context* m_context;
};
}  // namespace custom
