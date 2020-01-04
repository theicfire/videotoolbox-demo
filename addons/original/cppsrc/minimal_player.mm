#include "minimal_player.h"

#include <exception>

#include <SDL2/SDL.h>

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#import "decode_render.h"

using namespace custom;

// PImpl helps to avoid having Cocoa/Objective C code in header
struct MinimalPlayer::Context {
    AVAssetReader *reader;
    NSArray *videoTracks;
    CMVideoDimensions videoDimensions;
    AVAssetReaderTrackOutput *videoTrackOutput;
    CMVideoFormatDescriptionRef formatDescription;

    Context() { } 
    ~Context() { }

    void setup();
    CMSampleBufferRef processNextFrame();
};

MinimalPlayer::MinimalPlayer() : m_context(new Context()) {

}

MinimalPlayer::~MinimalPlayer() {
    if (m_context) {
        delete m_context;
    }
}

void MinimalPlayer::play(const std::string& path) {
    open(path);

    DecodeRender* decodeRender = new DecodeRender(m_context->formatDescription, m_context->videoDimensions);
    bool quit = false;
    while (!quit) {
        decodeRender->loop();
        CMSampleBufferRef buffRef = m_context->processNextFrame();
        if (buffRef == NULL) {
            break;
        }
        decodeRender->decode_render(buffRef);
        // manual sync
        usleep(25000);
    }
}

void MinimalPlayer::open(const std::string& path) {
    NSURL *url = [NSURL fileURLWithPath:[[NSString alloc] initWithUTF8String:path.c_str()]];
    NSDictionary *options = @{AVURLAssetPreferPreciseDurationAndTimingKey: @(YES)};
    AVAsset *asset = [[AVURLAsset alloc] initWithURL:url options:options];

    NSError *error = nil;
    m_context->reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error) {
        throw std::runtime_error(error.localizedDescription.UTF8String);
    }

    m_context->videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    m_context->setup();
}

CMSampleBufferRef MinimalPlayer::Context::processNextFrame() {
    if (reader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sampleBuffer = [videoTrackOutput copyNextSampleBuffer];
        if (sampleBuffer) {
            return sampleBuffer;
            // VTDecompressionSessionDecodeFrame(decompressionSession, sampleBuffer, flags, NULL, &flagOut);
            // CFRelease(sampleBuffer);
        }
        return NULL;
    } else if (reader.status == AVAssetReaderStatusFailed) {
        // NSLog(@"Asset Reader failed with error: %@", self.assetReader.error);
    } else if (reader.status == AVAssetReaderStatusCompleted) {
        // NSLog(@"Reached the end of the video.");
    }

    return NULL;
}

void MinimalPlayer::Context::setup() {
    AVAssetTrack *track = (AVAssetTrack *)videoTracks.firstObject;

    formatDescription = (__bridge CMVideoFormatDescriptionRef)track.formatDescriptions.firstObject;
    videoDimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);

    videoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
    if ([reader canAddOutput:videoTrackOutput]) {
        [reader addOutput:videoTrackOutput];
    }

    BOOL didStart = [reader startReading];
    if (!didStart) {
        // TODO
    }
}
