// Minimal reproducer for: fragment-shader texture writes not landing on AMD
// Metal (macOS), as seen in Blender's EEVEE deferred lighting (#122837).
//
// Mirrors the failing configuration:
//   * a render pass whose fragment shader writes ONLY via texture.write(),
//     producing no colour output of its own
//   * two write textures bound side by side:
//       A: R32Uint        (Blender's DEFERRED_RADIANCE_FORMAT) -- observed FAILING
//       B: RG11B10Float   (Blender's RAYTRACE_RADIANCE_FORMAT) -- observed WORKING
//   * usage = ShaderRead | ShaderWrite | RenderTarget | PixelFormatView (0x17)
//     and MTLStorageModePrivate, matching what Blender actually allocates
//
// Build and run:
//   clang++ -std=c++17 -fobjc-arc -framework Metal -framework Foundation \
//       -o /tmp/mtlrepro docs/metal-imagestore-repro.mm && /tmp/mtlrepro
//
// Expected on a working GPU: both textures report a full count of written
// texels. If A reports 0 and B reports a full count, the driver is dropping
// R32Uint fragment writes and Blender is not at fault.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>

static const char *kShaderSrc = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; };

vertex VOut v_main(uint vid [[vertex_id]]) {
  /* Full-screen triangle. */
  float2 p = float2((vid << 1) & 2, vid & 2);
  VOut o;
  o.pos = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
  return o;
}

/* No colour output: writes go only through texture.write(), exactly as
 * EEVEE's light_eval_frag does. */
fragment void f_main(VOut in [[stage_in]],
                     texture2d<uint,  access::write> texUint  [[texture(0)]],
                     texture2d<float, access::write> texFloat [[texture(1)]])
{
  uint2 c = uint2(in.pos.xy);
  texUint.write(uint4(0x3F800000u, 0u, 0u, 0u), c);
  texFloat.write(float4(0.0f, 4.0f, 0.0f, 1.0f), c);
}
)METAL";

static id<MTLTexture> makeTex(id<MTLDevice> dev, MTLPixelFormat fmt, int w, int h)
{
  MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
  d.pixelFormat = fmt;
  d.textureType = MTLTextureType2D;
  d.width = w;
  d.height = h;
  d.mipmapLevelCount = 1;
  /* 0x17, matching Blender's allocation for these textures. */
  d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
            MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
  d.storageMode = MTLStorageModePrivate;
  return [dev newTextureWithDescriptor:d];
}

int main()
{
  @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("no Metal device\n"); return 1; }
    printf("device: %s\n", [[dev name] UTF8String]);

    const int W = 64, H = 64;
    id<MTLTexture> texUint = makeTex(dev, MTLPixelFormatR32Uint, W, H);
    id<MTLTexture> texFloat = makeTex(dev, MTLPixelFormatRG11B10Float, W, H);
    /* A dummy colour attachment, mirroring EEVEE binding an existing
     * framebuffer while its shader writes no colour. */
    id<MTLTexture> dummy = makeTex(dev, MTLPixelFormatRGBA8Unorm, W, H);

    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(kShaderSrc) options:nil error:&err];
    if (!lib) { printf("shader compile failed: %s\n", [[err description] UTF8String]); return 1; }

    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = [lib newFunctionWithName:@"v_main"];
    pd.fragmentFunction = [lib newFunctionWithName:@"f_main"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!pso) { printf("pipeline failed: %s\n", [[err description] UTF8String]); return 1; }

    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dummy;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:pso];
    [enc setFragmentTexture:texUint atIndex:0];
    [enc setFragmentTexture:texFloat atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];

    /* Private storage: blit to shared buffers to read back. */
    id<MTLBuffer> bufU = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> bufF = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    MTLSize sz = MTLSizeMake(W, H, 1);
    [blit copyFromTexture:texUint sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:sz
                 toBuffer:bufU destinationOffset:0
        destinationBytesPerRow:W * 4 destinationBytesPerImage:W * H * 4];
    [blit copyFromTexture:texFloat sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:sz
                 toBuffer:bufF destinationOffset:0
        destinationBytesPerRow:W * 4 destinationBytesPerImage:W * H * 4];
    [blit endEncoding];

    [cb commit];
    [cb waitUntilCompleted];
    if (cb.error) { printf("command buffer error: %s\n", [[cb.error description] UTF8String]); }

    uint32_t *u = (uint32_t *)[bufU contents];
    uint32_t *f = (uint32_t *)[bufF contents];
    int nzU = 0, nzF = 0;
    for (int i = 0; i < W * H; i++) {
      if (u[i] != 0u) nzU++;
      if (f[i] != 0u) nzF++;
    }
    printf("R32Uint      texels written: %d / %d\n", nzU, W * H);
    printf("RG11B10Float texels written: %d / %d\n", nzF, W * H);
    printf("\nverdict: %s\n",
           (nzU == 0 && nzF > 0) ?
               "REPRODUCED -- R32Uint fragment writes are dropped, float writes land" :
               (nzU > 0 && nzF > 0) ? "both formats work -- NOT reproduced at this level" :
                                      "inconclusive (neither landed)");
  }
  return 0;
}
