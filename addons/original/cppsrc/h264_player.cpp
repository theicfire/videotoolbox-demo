#include <CoreVideo/CVPixelBuffer.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_render.h>
#include <SDL2/SDL_thread.h>
#include <cstdio>
#include <iostream>

#include "h264_player.h"

static bool is_hw_decoded(AVFrame *frame) {
  return frame->format == AV_PIX_FMT_VIDEOTOOLBOX;
}

H264Player::H264Player(int width, int height, enum AVPixelFormat pix_fmt)
    : height(height), width(width) {
  size_t yPlaneSz, uvPlaneSz;
  // Initial SDL subsystems

  if (SDL_Init(SDL_INIT_VIDEO)) {
    fprintf(stderr, "Could not initialize SDL - %s\n", SDL_GetError());
    exit(1);
  }

  window = SDL_CreateWindow(
      "Videotoolbox Decoder" /* title */, SDL_WINDOWPOS_CENTERED /* x */,
      SDL_WINDOWPOS_CENTERED /* y */, width, height, SDL_WINDOW_SHOWN);

  if (!window) {
    std::cerr << "SDL could not create a window." << std::endl;
    exit(1);
  }

  // Make a renderer that is to render to the screen

  renderer = SDL_CreateRenderer(window, -1, 0);
  if (!renderer) {
    std::cerr << "SDL could not create a renderer." << std::endl;
    exit(1);
  }

  // Allocate a place to put YUV image on the screen

  texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_YV12,
                              SDL_TEXTUREACCESS_STREAMING, width, height);
  if (!texture) {
    std::cerr << "SDL could not create a texture." << std::endl;
    exit(1);
  }

  // Initialize SWS context for software scaling

  sws_ctx =
      sws_getContext(width, height, pix_fmt, width, height, AV_PIX_FMT_YUV420P,
                     SWS_BILINEAR, nullptr, nullptr, nullptr);

  // set up YV12 pixel array (12 bits per pixel)

  yPlaneSz = width * height;
  uvPlaneSz = width * height / 4;
  yPlane = (Uint8 *)malloc(yPlaneSz);
  uPlane = (Uint8 *)malloc(uvPlaneSz);
  vPlane = (Uint8 *)malloc(uvPlaneSz);

  if (!yPlane || !uPlane || !vPlane) {
    fprintf(stderr, "Could not allocate pixel buffers - exiting\n");
    exit(1);
  }
}

void H264Player::render(AVFrame *frame) {
  int uvPitch = width / 2;
  if (is_hw_decoded(frame)) {
    CVPixelBufferRef ref = (CVPixelBufferRef)frame->data[3];

    CVPixelBufferLockBaseAddress(ref, 0);

    // debug stuff

    // looking at pixel format of CVPixelBuffer
    // this should be same as what is set in hw_surface_fmt
    // OSType type = CVPixelBufferGetPixelFormatType(ref);
    // std::cout << "Format of CVPixelBuffer: " << (type ==
    // kCVPixelFormatType_420YpCbCr8Planar) << ", frame format: " <<
    // AV_PIX_FMT_GBRAP10LE << std::endl; frame->format ==
    // AV_PIX_FMT_VIDEOTOOLBOX

    uint8_t *yDestPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(ref, 0);
    uint8_t *uDestPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(ref, 1);
    uint8_t *vDestPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(ref, 2);

    SDL_UpdateYUVTexture(texture, nullptr, yDestPlane,
                         CVPixelBufferGetBytesPerRowOfPlane(ref, 0), uDestPlane,
                         CVPixelBufferGetBytesPerRowOfPlane(ref, 1), vDestPlane,
                         CVPixelBufferGetBytesPerRowOfPlane(ref, 2));

    // Clear rendering target

    SDL_RenderClear(renderer);

    // Copy portion of texture to rendering target

    SDL_RenderCopy(renderer, texture, nullptr /* copy entire texture */,
                   nullptr /* entire rendering target */
    );

    // The other Render* methods draw to hidden target
    // This function actually draws to window tied to renderer

    SDL_RenderPresent(renderer);

    CVPixelBufferUnlockBaseAddress(ref, 0);

  } else {
    AVPicture pict;
    pict.data[0] = yPlane;
    pict.data[1] = uPlane;
    pict.data[2] = vPlane;
    pict.linesize[0] = width;
    pict.linesize[1] = uvPitch;
    pict.linesize[2] = uvPitch;

    // Convert the image into YUV format for SDL

    sws_scale(sws_ctx, (uint8_t const *const *)frame->data, frame->linesize, 0,
              height, pict.data, pict.linesize);

    SDL_UpdateYUVTexture(texture, NULL, yPlane, width, uPlane, uvPitch, vPlane,
                         uvPitch);

    // Clear rendering target

    SDL_RenderClear(renderer);

    // Copy portion of texture to rendering target

    SDL_RenderCopy(renderer, texture, nullptr /* copy entire texture */,
                   nullptr /* entire rendering target */
    );

    // The other Render* methods draw to hidden target
    // This function actually draws to window tied to renderer

    SDL_RenderPresent(renderer);
  }
}