#import <MetalKit/MetalKit.h>

@interface AAPLRenderer : NSObject<MTKViewDelegate>

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView;
- (BOOL)setImageBuffer:(CVPixelBufferRef __nullable)frame;

@end
