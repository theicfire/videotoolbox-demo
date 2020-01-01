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
#include "h264_player.h"
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

int run_program(std::string filename) {
  clock_t start = clock();

  int ret, videoStream;
  AVFormatContext *pFormatCtx = nullptr;
  AVCodecContext *decoderCtx = nullptr;
  AVCodec *decoder = nullptr;
  AVStream *video = nullptr;
  AVFrame *frame = nullptr;
  AVPacket *packet = av_packet_alloc();
  if (SDL_Init(SDL_INIT_VIDEO)) {
    fprintf(stderr, "Could not initialize SDL - %s\n", SDL_GetError());
    exit(1);
  }

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
  H264Player player(decoderCtx->width, decoderCtx->height, decoderCtx->pix_fmt);

  // Splits what is stored in the file into frames and returns one each call.
  // These frames have not been decoded yet.
  while (av_read_frame(pFormatCtx, packet) == 0) {
    if (packet->stream_index == videoStream) {
      // Supply raw packet data as input to the decoder.
      ret = avcodec_send_packet(decoderCtx, packet);

      int result = avcodec_receive_frame(decoderCtx, frame);
      if (result == 0) {
        player.render(frame);
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
    SDL_Event event;
    SDL_PollEvent(&event);
    switch (event.type) {
      case SDL_QUIT:
        SDL_Quit();
        exit(0);
        break;
      default:
        break;
    }
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
