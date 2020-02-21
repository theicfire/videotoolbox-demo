//
//  RenderingPipeline.m
//  MetalH264Player
//
//  Created by  Ivan Ushakov on 25.12.2019.
//  Copyright © 2019 Lunar Key. All rights reserved.
//

#import "RenderingPipeline.h"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <AVFoundation/AVFoundation.h>

#define MTL_STRINGIFY(s) @ #s

static NSString *const kShaderSource = MTL_STRINGIFY(
    using namespace metal;

    struct InputVertex {
        float2 position [[attribute(0)]];
        float2 uv [[attribute(1)]];
    };

    struct ProjectedVertex {
        float4 position [[position]];
        float2 uv;
    };

    vertex ProjectedVertex vertex_shader(InputVertex input_vertex [[stage_in]])
    {
        ProjectedVertex output;
        output.position = float4(input_vertex.position, 0, 1.0);
        output.uv = input_vertex.uv;
        return output;
    }

    constexpr sampler frame_sampler(address::clamp_to_edge, filter::linear);

    fragment half4 fragment_shader(ProjectedVertex input [[stage_in]],
                                   texture2d<float, access::sample> luma_texture [[texture(0)]],
                                   texture2d<float, access::sample> chroma_texture [[texture(1)]])
    {
        // Conversion found from https://stackoverflow.com/questions/17892346/how-to-convert-rgb-yuv-rgb-both-ways
        // I believe this is BT.601
        float y = luma_texture.sample(frame_sampler, input.uv).r;
        float2 uv1 = chroma_texture.sample(frame_sampler, input.uv).rg;

        float u = uv1.x;
        float v = uv1.y;
        u = u - 0.5;
        v = v - 0.5;
        y = y - .062745; // 16 / 255

        float r = 1.164 * y + 1.596 * v;
        float g = 1.164 * y - .392 * u - .813 * v;
        float b = 1.164 * y + 2.017 * u;

        return half4(float4(r, g, b, 1.0));
    }
);

@implementation RenderingPipeline
{
    MTKView *_view;
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _state;
    id<MTLCommandQueue> _commandQueue;
    id<MTLBuffer> _vertexBuffer;
    CVMetalTextureCacheRef _textureCache;
    id<MTLTexture> _lumaTexture;
    id<MTLTexture> _chromaTexture;
    dispatch_semaphore_t _inflight_semaphore;
}

- (instancetype)initWithView:(MTKView *)view error:(NSError **)error {
    self = [super init];
    if (self) {
        _view = view;
        _device = view.device;
        _inflight_semaphore = dispatch_semaphore_create(1);

        id<MTLLibrary> library = [_device newLibraryWithSource:kShaderSource options:NULL error:error];
        if (library == nil) {
            return nil;
        }

        id<MTLFunction> vertexFunction = [library newFunctionWithName:@"vertex_shader"];
        if (vertexFunction == nil) {
            *error = [NSError errorWithDomain:@"Pipeline" code:0 userInfo:nil];
            return nil;
        }

        id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"fragment_shader"];
        if (fragmentFunction == nil) {
            *error = [NSError errorWithDomain:@"Pipeline" code:0 userInfo:nil];
            return nil;
        }

        MTLVertexDescriptor *vertexDescriptor = [MTLVertexDescriptor new];
        vertexDescriptor.attributes[0].format = MTLVertexFormatFloat2; // position
        vertexDescriptor.attributes[0].offset = 0;
        vertexDescriptor.attributes[0].bufferIndex = 0;
        vertexDescriptor.attributes[1].format = MTLVertexFormatFloat2; // texCoords
        vertexDescriptor.attributes[1].offset = 2 * sizeof(simd_float1);
        vertexDescriptor.attributes[1].bufferIndex = 0;
        vertexDescriptor.layouts[0].stride = 4 * sizeof(simd_float1);
        // Why we need this cast in Objective C++?
        vertexDescriptor.layouts[0].stepFunction = (MTLVertexStepFunction)MTLStepFunctionPerVertex;
        vertexDescriptor.layouts[0].stepRate = 1;

        MTLRenderPipelineDescriptor *pipelineDescriptor = [MTLRenderPipelineDescriptor new];
        pipelineDescriptor.vertexFunction = vertexFunction;
        pipelineDescriptor.vertexDescriptor = vertexDescriptor;
        pipelineDescriptor.fragmentFunction = fragmentFunction;
        pipelineDescriptor.colorAttachments[0].pixelFormat = _view.colorPixelFormat;
        pipelineDescriptor.depthAttachmentPixelFormat = MTLPixelFormatInvalid;

        _state = [_device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:error];
        if (_state == nil) {
            return nil;
        }

        _commandQueue = [_device newCommandQueue];
        if (_commandQueue == nil) {
            *error = [NSError errorWithDomain:@"Pipeline" code:0 userInfo:nil];
            return nil;
        }

        _vertexBuffer = [_device newBufferWithLength:16 * sizeof(simd_float1) options:0];

        if (CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_textureCache) != kCVReturnSuccess) {
            *error = [NSError errorWithDomain:@"Pipeline" code:0 userInfo:nil];
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    if (_textureCache) {
        CFRelease(_textureCache);
        _textureCache = nil;
    }
}

- (BOOL)render:(CVPixelBufferRef)frame {
    if (dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_NOW) != 0) {
       return NO;
    }
    if (frame != NULL && ![self setupTexturesForFrame:frame]) {
        dispatch_semaphore_signal(_inflight_semaphore);
        return NO;
    }

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    if (commandBuffer == nil) {
        dispatch_semaphore_signal(_inflight_semaphore);
        return NO;
    }
    CVBufferRetain(frame);

     __block dispatch_semaphore_t block_semaphore = _inflight_semaphore;
      [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull) {
        CVBufferRelease(frame);
        // GPU work completed.
        dispatch_semaphore_signal(block_semaphore);
      }];

    MTLRenderPassDescriptor *renderPassDescriptor = _view.currentRenderPassDescriptor;
    if (renderPassDescriptor) {
        id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

        if (frame != NULL) {
            [self setupEncoder:commandEncoder forFrame:frame];
        }

        [commandEncoder endEncoding];
        [commandBuffer presentDrawable:_view.currentDrawable];
    }

    [commandBuffer commit];

    return YES;
}

- (BOOL)setupTexturesForFrame:(CVPixelBufferRef)frame {
    int width = (int)CVPixelBufferGetWidth(frame);
    int height = (int)CVPixelBufferGetHeight(frame);

    CVMetalTextureRef texture = NULL;
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, frame, NULL, MTLPixelFormatR8Unorm, width, height, 0, &texture);
    if (texture == NULL) {
        return NO;
    }

    id<MTLTexture> lumaTexture = CVMetalTextureGetTexture(texture);

    CFRelease(texture);
    texture = NULL;

    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, frame, NULL, MTLPixelFormatRG8Unorm, width / 2, height / 2, 1, &texture);
    if (texture == NULL) {
        return NO;
    }

    id<MTLTexture> chromaTexture = CVMetalTextureGetTexture(texture);

    CFRelease(texture);
    texture = NULL;

    if (lumaTexture != nil && chromaTexture != nil) {
        _lumaTexture = lumaTexture;
        _chromaTexture = chromaTexture;
        return YES;
    }

    return NO;
}

- (void)setupEncoder:(id<MTLRenderCommandEncoder>)commandEncoder forFrame:(CVPixelBufferRef)frame {
    int width = (int)CVPixelBufferGetWidth(frame);
    int height = (int)CVPixelBufferGetHeight(frame);

    // Set up the quad vertices with respect to the orientation and aspect ratio of the video.
    CGSize aspectRatio = CGSizeMake(width, height);
    CGRect vertexSamplingRect = AVMakeRectWithAspectRatioInsideRect(aspectRatio, _view.bounds);

    // Compute normalized quad coordinates to draw the frame into.
    CGSize normalizedSamplingSize = CGSizeMake(0.0, 0.0);
    CGSize cropScaleAmount = CGSizeMake(vertexSamplingRect.size.width / _view.bounds.size.width,
                                        vertexSamplingRect.size.height / _view.bounds.size.height);

    // Normalize the quad vertices.
    if (cropScaleAmount.width > cropScaleAmount.height) {
        normalizedSamplingSize.width = 1.0;
        normalizedSamplingSize.height = cropScaleAmount.height / cropScaleAmount.width;
    } else {
        normalizedSamplingSize.width = 1.0;
        normalizedSamplingSize.height = cropScaleAmount.width / cropScaleAmount.height;
    }

    CGRect textureSamplingRect = CGRectMake(0, 0, 1, 1);

    // explicit cast from double to float in Objective C++
    simd_float1 x1 = (simd_float1)(-1 * normalizedSamplingSize.width);
    simd_float1 y1 = (simd_float1)(-1 * normalizedSamplingSize.height);
    simd_float1 u1 = (simd_float1)CGRectGetMinX(textureSamplingRect);
    simd_float1 v1 = (simd_float1)CGRectGetMaxY(textureSamplingRect);

    simd_float1 x2 = (simd_float1)normalizedSamplingSize.width;
    simd_float1 y2 = (simd_float1)(-1 * normalizedSamplingSize.height);
    simd_float1 u2 = (simd_float1)CGRectGetMaxX(textureSamplingRect);
    simd_float1 v2 = (simd_float1)CGRectGetMaxY(textureSamplingRect);

    simd_float1 x3 = (simd_float1)(-1 * normalizedSamplingSize.width);
    simd_float1 y3 = (simd_float1)normalizedSamplingSize.height;
    simd_float1 u3 = (simd_float1)CGRectGetMinX(textureSamplingRect);
    simd_float1 v3 = (simd_float1)CGRectGetMinY(textureSamplingRect);

    simd_float1 x4 = (simd_float1)normalizedSamplingSize.width;
    simd_float1 y4 = (simd_float1)normalizedSamplingSize.height;
    simd_float1 u4 = (simd_float1)CGRectGetMaxX(textureSamplingRect);
    simd_float1 v4 = (simd_float1)CGRectGetMinY(textureSamplingRect);

    simd_float1 vertexData[] = {
        x1, y1, u1, v1,
        x2, y2, u2, v2,
        x3, y3, u3, v3,
        x4, y4, u4, v4
    };
    memcpy(_vertexBuffer.contents, vertexData, 16 * sizeof(simd_float1));
    [commandEncoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];

    [commandEncoder setFragmentTexture:_lumaTexture atIndex:0];
    [commandEncoder setFragmentTexture:_chromaTexture atIndex:1];

    [commandEncoder setRenderPipelineState:_state];
    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

@end
