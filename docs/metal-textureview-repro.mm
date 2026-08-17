// Does a fragment shader write through a 2D-array -> 2D texture VIEW land on this GPU?
// Blender binds exactly such a view for EEVEE's direct_radiance images.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>

static const char *kSrc = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; };
vertex VOut v_main(uint vid [[vertex_id]]) {
  float2 p = float2((vid << 1) & 2, vid & 2);
  VOut o; o.pos = float4(p * 2.0f - 1.0f, 0.0f, 1.0f); return o;
}
fragment void f_main(VOut in [[stage_in]],
                     texture2d<uint, access::write> viewTex [[texture(0)]],
                     texture2d<uint, access::write> plainTex [[texture(1)]],
                     texture2d<uint, access::write> swzTex   [[texture(2)]])
{
  uint2 c = uint2(in.pos.xy);
  viewTex.write(uint4(9u,0u,0u,0u), c);
  plainTex.write(uint4(9u,0u,0u,0u), c);
  swzTex.write(uint4(9u,0u,0u,0u), c);
}
)MSL";

int main() {
 @autoreleasepool {
  id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
  printf("device: %s\n", [[dev name] UTF8String]);
  const int W=64,H=64;
  MTLTextureUsage U = MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|
                      MTLTextureUsageRenderTarget|MTLTextureUsagePixelFormatView;

  // parent: 2D ARRAY, like Blender's allocation
  MTLTextureDescriptor *ad=[[MTLTextureDescriptor alloc] init];
  ad.pixelFormat=MTLPixelFormatR32Uint; ad.textureType=MTLTextureType2DArray;
  ad.width=W; ad.height=H; ad.arrayLength=3; ad.usage=U;
  ad.storageMode=MTLStorageModePrivate;
  id<MTLTexture> arrTex=[dev newTextureWithDescriptor:ad];
  // 2D view of slice 0 -- what Blender binds
  id<MTLTexture> view=[arrTex newTextureViewWithPixelFormat:MTLPixelFormatR32Uint
                                                textureType:MTLTextureType2D
                                                     levels:NSMakeRange(0,1)
                                                     slices:NSMakeRange(0,1)];
  printf("view: type=%lu usage=0x%lx parent=%p\n",
         (unsigned long)[view textureType],(unsigned long)[view usage],(__bridge void*)[view parentTexture]);

  // view created via the SWIZZLE API with an identity mask -- exactly what Blender does
  MTLTextureSwizzleChannels idsw = MTLTextureSwizzleChannelsMake(
      MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
  MTLTextureDescriptor *ad2=[[MTLTextureDescriptor alloc] init];
  ad2.pixelFormat=MTLPixelFormatR32Uint; ad2.textureType=MTLTextureType2DArray;
  ad2.width=W; ad2.height=H; ad2.arrayLength=3; ad2.usage=U;
  ad2.storageMode=MTLStorageModePrivate;
  id<MTLTexture> arrTex2=[dev newTextureWithDescriptor:ad2];
  id<MTLTexture> swzView=[arrTex2 newTextureViewWithPixelFormat:MTLPixelFormatR32Uint
                                                    textureType:MTLTextureType2D
                                                         levels:NSMakeRange(0,1)
                                                         slices:NSMakeRange(0,1)
                                                        swizzle:idsw];
  printf("swizzleView: type=%lu usage=0x%lx parent=%p\n",
         (unsigned long)[swzView textureType],(unsigned long)[swzView usage],
         (__bridge void*)[swzView parentTexture]);

  // control: plain 2D texture
  MTLTextureDescriptor *pd2=[[MTLTextureDescriptor alloc] init];
  pd2.pixelFormat=MTLPixelFormatR32Uint; pd2.textureType=MTLTextureType2D;
  pd2.width=W; pd2.height=H; pd2.usage=U; pd2.storageMode=MTLStorageModePrivate;
  id<MTLTexture> plain=[dev newTextureWithDescriptor:pd2];

  MTLTextureDescriptor *cd=[[MTLTextureDescriptor alloc] init];
  cd.pixelFormat=MTLPixelFormatRGBA16Float; cd.width=W; cd.height=H;
  cd.usage=MTLTextureUsageRenderTarget; cd.storageMode=MTLStorageModePrivate;
  id<MTLTexture> col=[dev newTextureWithDescriptor:cd];

  NSError *err=nil;
  id<MTLLibrary> lib=[dev newLibraryWithSource:@(kSrc) options:nil error:&err];
  if(!lib){printf("compile: %s\n",[[err description] UTF8String]);return 1;}
  MTLRenderPipelineDescriptor *pd=[[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction=[lib newFunctionWithName:@"v_main"];
  pd.fragmentFunction=[lib newFunctionWithName:@"f_main"];
  pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA16Float;
  pd.colorAttachments[0].writeMask=MTLColorWriteMaskNone;
  id<MTLRenderPipelineState> pso=[dev newRenderPipelineStateWithDescriptor:pd error:&err];
  if(!pso){printf("pso: %s\n",[[err description] UTF8String]);return 1;}

  id<MTLCommandQueue> q=[dev newCommandQueue];
  id<MTLCommandBuffer> cb=[q commandBuffer];
  MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture=col;
  rp.colorAttachments[0].loadAction=MTLLoadActionClear;
  rp.colorAttachments[0].storeAction=MTLStoreActionStore;
  id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:rp];
  [e setRenderPipelineState:pso];
  [e setFragmentTexture:view atIndex:0];
  [e setFragmentTexture:plain atIndex:1];
  [e setFragmentTexture:swzView atIndex:2];
  [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [e endEncoding];

  id<MTLBuffer> b1=[dev newBufferWithLength:W*H*4 options:MTLResourceStorageModeShared];
  id<MTLBuffer> b2=[dev newBufferWithLength:W*H*4 options:MTLResourceStorageModeShared];
  id<MTLBuffer> b3=[dev newBufferWithLength:W*H*4 options:MTLResourceStorageModeShared];
  id<MTLBlitCommandEncoder> bl=[cb blitCommandEncoder];
  // read the PARENT array slice 0 (where the view should have written)
  [bl copyFromTexture:arrTex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
           sourceSize:MTLSizeMake(W,H,1) toBuffer:b1 destinationOffset:0
   destinationBytesPerRow:W*4 destinationBytesPerImage:W*H*4];
  [bl copyFromTexture:plain sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
           sourceSize:MTLSizeMake(W,H,1) toBuffer:b2 destinationOffset:0
   destinationBytesPerRow:W*4 destinationBytesPerImage:W*H*4];
  [bl copyFromTexture:arrTex2 sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
           sourceSize:MTLSizeMake(W,H,1) toBuffer:b3 destinationOffset:0
   destinationBytesPerRow:W*4 destinationBytesPerImage:W*H*4];
  [bl endEncoding];
  [cb commit];[cb waitUntilCompleted];
  if(cb.error) printf("cb error: %s\n",[[cb.error description] UTF8String]);

  uint32_t *p1=(uint32_t*)[b1 contents],*p2=(uint32_t*)[b2 contents],*p3=(uint32_t*)[b3 contents];
  int n1=0,n2=0,n3=0;
  for(int i=0;i<W*H;i++){ if(p1[i]==9u)n1++; if(p2[i]==9u)n2++; if(p3[i]==9u)n3++; }
  printf("view (no-swizzle API)      : %d / %d\n", n1, W*H);
  printf("plain 2D texture           : %d / %d\n", n2, W*H);
  printf("view (SWIZZLE API, identity): %d / %d\n", n3, W*H);
  printf("\nverdict: %s\n", (n3==0 && n1>0)
    ? "REPRODUCED — swizzle-API views drop fragment writes on this GPU"
    : (n3>0) ? "swizzle view also works — not the cause" : "inconclusive");
 }
 return 0;
}
