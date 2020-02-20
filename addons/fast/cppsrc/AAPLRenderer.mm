#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#import "AAPLRenderer.h"
#import "RenderingPipeline.h"

@implementation AAPLRenderer
{
    RenderingPipeline *pipeline;
    CVPixelBufferRef _imageBuffer;
    bool done_render;
}

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView
{
    self = [super init];
    if(self)
    {
        NSError *error;
        done_render = true;
        pipeline = [[RenderingPipeline alloc] initWithView:mtkView error:&error];
        if (pipeline == nil) {
            printf("ERROR: pipeline nil\n");
            return self;
        }
    }

    return self;
}

- (BOOL)setImageBuffer:(CVPixelBufferRef __nullable)frame
{
    _imageBuffer = frame;
    done_render = false;
    return YES;
}

/// Called whenever view changes orientation or is resized
- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size
{
    printf("Call resize\n");
}

/// Called whenever the view needs to render a frame.
- (void)drawInMTKView:(nonnull MTKView *)view
{
    if (done_render) {
        return;
    }
    @autoreleasepool {
        [pipeline render:_imageBuffer];
    };
    done_render = true;
}

@end
