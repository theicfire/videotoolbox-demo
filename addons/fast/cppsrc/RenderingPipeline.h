//
//  RenderingPipeline.h
//  MetalH264Player
//
//  Created by  Ivan Ushakov on 25.12.2019.
//  Copyright © 2019 Lunar Key. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <Quartz/Quartz.h>

@class MTKView;

NS_ASSUME_NONNULL_BEGIN

@interface RenderingPipeline : NSObject

- (instancetype)initWithView:(MTKView *)view error:(NSError **)error;

- (BOOL)render:(CVPixelBufferRef __nullable)frame;

@end

NS_ASSUME_NONNULL_END
