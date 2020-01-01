/**
 * Hardware accelerated decoding.
 *
 * Uses Apple Videotoolbox through FFmpeg (V4)
 * Uses SDL2 to render decoded frames
 *
 * If user does not have Videotoolbox, falls back to software decoding.
 *
 * Valuable Resources:
 * http://ffmpeg.org/doxygen/trunk/ffmpeg__videotoolbox_8c_source.html (Provides
 * some insight into decoded frames)
 * https://medium.com/liveop-x-team/accelerating-h264-decoding-on-ios-with-ffmpeg-and-videotoolbox-1f000cb6c549
 * https://ffmpeg.org/doxygen/3.4/hw_decode_8c-example.html (shows a hardware
 * decode example in c)
 * https://stackoverflow.com/questions/21007329/what-is-an-sdl-renderer (helpful
 * SDL terminology)
 *
 */

extern "C" {

#include <CoreVideo/CVPixelBuffer.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/videotoolbox.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
#include <time.h>

#include <SDL2/SDL.h>
#include <SDL2/SDL_render.h>
#include <SDL2/SDL_thread.h>
}

#include <cstdio>
#include <iostream>
#include "window.h"

/**
 * If user does not have hardware accelerated capability, fall back to software
 * format.
 */
static enum AVPixelFormat get_hw_surface_fmt(struct AVCodecContext *s,
                                             const enum AVPixelFormat *fmt) {
  while (*fmt != AV_PIX_FMT_NONE) {
    if (*fmt == AV_PIX_FMT_VIDEOTOOLBOX) {
      if (s->hwaccel_context == NULL) {
        AVVideotoolboxContext *ctx = av_videotoolbox_alloc_context();
        ctx->cv_pix_fmt_type = kCVPixelFormatType_420YpCbCr8Planar;

        int result = av_videotoolbox_default_init2(s, ctx);
        if (result < 0) {
          std::cerr << "Hardware decoder failed to initialize, falling back to "
                    << s->pix_fmt << std::endl;
          return s->pix_fmt;
        }
      }
      return *fmt;
    }
    ++fmt;
  }
  std::cerr << "Did not find Videotoolbox, falling back to format "
            << s->pix_fmt << std::endl;
  return s->pix_fmt;
}

static bool is_hw_decoded(AVFrame *frame) {
  return frame->format == AV_PIX_FMT_VIDEOTOOLBOX;
}

class SDLHolder {
  SDL_Texture *texture;
  SDL_Renderer *renderer;
  SDL_Window *window;
  Uint8 *yPlane, *uPlane, *vPlane;
  SwsContext *sws_ctx = nullptr;

 public:
  void sdl_init(int width, int height, enum AVPixelFormat pix_fmt) {
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

    sws_ctx = sws_getContext(width, height, pix_fmt, width, height,
                             AV_PIX_FMT_YUV420P, SWS_BILINEAR, nullptr, nullptr,
                             nullptr);

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

  void sdl_render(AVFrame *frame, int width, int height) {
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

      uint8_t *yDestPlane =
          (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(ref, 0);
      uint8_t *uDestPlane =
          (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(ref, 1);
      uint8_t *vDestPlane =
          (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(ref, 2);

      SDL_UpdateYUVTexture(
          texture, nullptr, yDestPlane,
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

      sws_scale(sws_ctx, (uint8_t const *const *)frame->data, frame->linesize,
                0, height, pict.data, pict.linesize);

      SDL_UpdateYUVTexture(texture, NULL, yPlane, width, uPlane, uvPitch,
                           vPlane, uvPitch);

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

  void sdl_handle_events() {
    SDL_Event event;
    SDL_PollEvent(&event);
    switch (event.type) {
      case SDL_QUIT:
        SDL_DestroyTexture(texture);
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        exit(0);
        break;
      default:
        break;
    }
  }
};

int run_program(std::string filename) {
  clock_t start = clock();

  int ret, videoStream;
  AVFormatContext *pFormatCtx = nullptr;
  AVCodecContext *decoderCtx = nullptr;
  AVCodec *decoder = nullptr;
  AVStream *video = nullptr;
  AVFrame *frame = nullptr;
  AVPacket *packet = av_packet_alloc();
  SDLHolder sdl_stuff;

  // Validate filepath is present

  // Register all formats and codecs with FFmpeg

  av_register_all();

  // Open video file

  if (avformat_open_input(&pFormatCtx, filename.c_str(),
                          nullptr /* autodetect format */, nullptr) != 0) {
    fprintf(stderr, "Could not open file %s\n", filename.c_str());
    return -1;
  }

  // Read packets of file to get stream information.
  // Populates pFormatCtx->streams with the proper information

  if (avformat_find_stream_info(pFormatCtx, nullptr) < 0) {
    fprintf(stderr, "Could not find stream information\n");
    return -1;
  }

  // Dump pFormatCtx now to see whats inside

  // av_dump_format(pFormatCtx, 0, argv[1], 0);

  // Find a video stream

  ret =
      av_find_best_stream(pFormatCtx, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0);
  if (ret < 0) {
    fprintf(stderr, "Cannot find a video stream in the input file\n");
    return -1;
  }
  videoStream = ret;

  // Build AVCodecContext and populate with video stream parameters

  if (!(decoderCtx = avcodec_alloc_context3(decoder))) return AVERROR(ENOMEM);

  video = pFormatCtx->streams[videoStream];

  if (avcodec_parameters_to_context(decoderCtx, video->codecpar) < 0) return -1;

  // get_hw_surface_fmt will be called with all available with the
  // AVCodecContext and all available formats for the codec.

  decoderCtx->get_format = get_hw_surface_fmt;

  // Initialize the AVCodecContext to use the given AVCodec

  if (avcodec_open2(decoderCtx, decoder, nullptr) < 0) {
    fprintf(stderr, "Could not open the codec!\n");
    return -1;
  }

  frame = av_frame_alloc();
  sdl_stuff.sdl_init(decoderCtx->width, decoderCtx->height,
                     decoderCtx->pix_fmt);

  // Splits what is stored in the file into frames and returns one each call.
  // These frames have not been decoded yet.
  while (av_read_frame(pFormatCtx, packet) == 0) {
    if (packet->stream_index == videoStream) {
      // Supply raw packet data as input to the decoder.
      ret = avcodec_send_packet(decoderCtx, packet);

      int result = avcodec_receive_frame(decoderCtx, frame);
      if (result == 0) {
        sdl_stuff.sdl_render(frame, decoderCtx->width, decoderCtx->height);
      } else if (result == AVERROR(EINVAL)) {
        std::cerr << "Codec not opened, or it is an encoder." << std::endl;
        exit(1);
      } else if (result == AVERROR_EOF) {
        std::cerr << "End of file reached" << std::endl;
      } else if (result == AVERROR(EAGAIN)) {
        std::cerr << "Output is not available in this state - send more input "
                     "to decoder."
                  << std::endl;
      }
    } else {
      printf("Got a stream that was not a video\n");
    }

    av_packet_unref(packet);
    sdl_stuff.sdl_handle_events();
  }

  if (decoderCtx->hwaccel != nullptr) {
    av_videotoolbox_default_free(decoderCtx);
  }

  // Free the frame

  av_frame_free(&frame);

  // Close the codec

  avcodec_close(decoderCtx);

  // Close the video file

  avformat_close_input(&pFormatCtx);

  // benchmark

  clock_t stop = clock();
  double elapsed = (double)(stop - start) / CLOCKS_PER_SEC;
  printf("\nTime elapsed: %.5f\n", elapsed);

  return 0;
}
