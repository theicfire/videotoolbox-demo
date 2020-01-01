#pragma once
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/videotoolbox.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
}

class H264Player {
  SDL_Texture *texture;
  SDL_Renderer *renderer;
  SDL_Window *window;
  Uint8 *yPlane, *uPlane, *vPlane;
  SwsContext *sws_ctx = nullptr;
  int height;
  int width;

 public:
  H264Player(int width, int height, enum AVPixelFormat pix_fmt);
  void render(AVFrame *frame);
};
