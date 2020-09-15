//
//  main.m
//  tester
//
//  Created by chase lambert on 9/11/20.
//  Copyright © 2020 chase lambert. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import "VideoToolbox/VTDecompressionSession.h"

#include "h264_player.h"


int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // insert code here...
        NSLog(@"Hello, World!");
        
        fast::MinimalPlayer player;
        player.play("/Users/chase/code/speedy-mplayer/frames");
    }
    
    return 0;
}

