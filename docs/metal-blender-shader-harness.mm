// Compile Blender's exact captured deferred-light fragment shader and draw.
// usage: harness <fragment.metal>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>

static const char *kVert = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 __eevee_deferred_VertOut_screen_uv [[center_perspective]]; };
vertex VOut my_vert(uint vid [[vertex_id]]) {
  float2 p = float2((vid << 1) & 2, vid & 2);
  VOut o; o.pos = float4(p * 2.0f - 1.0f, 0.5f, 1.0f); o.__eevee_deferred_VertOut_screen_uv = p; return o;
}
)MSL";

static id<MTLTexture> mk(id<MTLDevice> d, MTLPixelFormat f, MTLTextureType tt,
                         int w, int h, int layers) {
  MTLTextureDescriptor *td = [[MTLTextureDescriptor alloc] init];
  td.pixelFormat = f; td.textureType = tt; td.width = w; td.height = h;
  td.arrayLength = (tt == MTLTextureType2DArray) ? layers : 1;
  td.depth = (tt == MTLTextureType3D) ? 4 : 1;
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
             MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
  if (tt == MTLTextureType3D) td.usage &= ~MTLTextureUsageRenderTarget;
  td.storageMode = MTLStorageModePrivate;
  return [d newTextureWithDescriptor:td];
}

int main(int argc, char **argv) {
  @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    printf("device: %s\n", [[dev name] UTF8String]);
    NSError *err = nil;
    NSString *fragSrc = [NSString stringWithContentsOfFile:@(argv[1])
                                                  encoding:NSUTF8StringEncoding error:&err];
    if (!fragSrc) { printf("read fail\n"); return 1; }

    MTLCompileOptions *opt = [[MTLCompileOptions alloc] init];
    id<MTLLibrary> flib = [dev newLibraryWithSource:fragSrc options:opt error:&err];
    if (!flib) { printf("FRAG COMPILE FAILED:\n%s\n", [[err localizedDescription] UTF8String]); return 1; }
    id<MTLLibrary> vlib = [dev newLibraryWithSource:@(kVert) options:opt error:&err];

    MTLFunctionConstantValues *cv = [[MTLFunctionConstantValues alloc] init];
    float ps = 1.0f;
    bool split_indirect = getenv("C_SPLIT") != nullptr;
    bool lightprobe = getenv("C_PROBE") != nullptr;
    bool transmission = getenv("C_TRANS") != nullptr;
    int shadow_id = -1;
    int rays = getenv("C_RAYS") ? atoi(getenv("C_RAYS")) : 1;
    int steps = getenv("C_STEPS") ? atoi(getenv("C_STEPS")) : 1;
    printf("constants: split=%d probe=%d trans=%d rays=%d steps=%d\n",
           (int)split_indirect, (int)lightprobe, (int)transmission, rays, steps);
    [cv setConstantValue:&ps type:MTLDataTypeFloat atIndex:1];
    [cv setConstantValue:&split_indirect type:MTLDataTypeBool atIndex:30];
    [cv setConstantValue:&lightprobe type:MTLDataTypeBool atIndex:31];
    [cv setConstantValue:&transmission type:MTLDataTypeBool atIndex:32];
    [cv setConstantValue:&shadow_id type:MTLDataTypeInt atIndex:33];
    [cv setConstantValue:&rays type:MTLDataTypeInt atIndex:34];
    [cv setConstantValue:&steps type:MTLDataTypeInt atIndex:35];

    id<MTLFunction> ff = [flib newFunctionWithName:@"_eevee_deferred_light_triple_frag"
                                    constantValues:cv error:&err];
    if (!ff) { printf("FRAG FN FAILED: %s\n", [[err localizedDescription] UTF8String]); return 1; }
    id<MTLFunction> vf = [vlib newFunctionWithName:@"my_vert"];

    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = vf; pd.fragmentFunction = ff;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    pd.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
    pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    pd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!pso) { printf("PSO FAILED: %s\n", [[err localizedDescription] UTF8String]); return 1; }
    printf("PSO created OK\n");

    const int W = 64, H = 64;
    // binding table from the captured shader
    id<MTLTexture> rp_color = mk(dev, MTLPixelFormatRGBA16Float, MTLTextureType2DArray, W, H, 2);
    id<MTLTexture> rp_value = mk(dev, MTLPixelFormatR16Float, MTLTextureType2DArray, W, H, 2);
    id<MTLTexture> dr1 = mk(dev, MTLPixelFormatR32Uint, MTLTextureType2D, W, H, 1);
    id<MTLTexture> dr2 = mk(dev, MTLPixelFormatR32Uint, MTLTextureType2D, W, H, 1);
    id<MTLTexture> dr3 = mk(dev, MTLPixelFormatR32Uint, MTLTextureType2D, W, H, 1);
    id<MTLTexture> ir1 = mk(dev, MTLPixelFormatRG11B10Float, MTLTextureType2D, W, H, 1);
    id<MTLTexture> ir2 = mk(dev, MTLPixelFormatRG11B10Float, MTLTextureType2D, W, H, 1);
    id<MTLTexture> ir3 = mk(dev, MTLPixelFormatRG11B10Float, MTLTextureType2D, W, H, 1);
    id<MTLTexture> util = mk(dev, MTLPixelFormatRGBA16Float, MTLTextureType2DArray, W, H, 2);
    id<MTLTexture> hiz  = mk(dev, MTLPixelFormatR32Float, MTLTextureType2D, W, H, 1);
    id<MTLTexture> stm  = mk(dev, MTLPixelFormatR32Uint, MTLTextureType2D, W, H, 1);
    id<MTLTexture> satl = mk(dev, MTLPixelFormatR32Uint, MTLTextureType2DArray, W, H, 2);
    id<MTLTexture> irat = mk(dev, MTLPixelFormatRGBA16Float, MTLTextureType3D, 8, 8, 1);
    id<MTLTexture> lps  = mk(dev, MTLPixelFormatRGBA16Float, MTLTextureType2DArray, W, H, 2);
    id<MTLTexture> gc   = mk(dev, MTLPixelFormatRGB10A2Unorm, MTLTextureType2DArray, W, H, 2);
    id<MTLTexture> gn   = mk(dev, MTLPixelFormatRG16Unorm, MTLTextureType2DArray, W, H, 2);
    id<MTLTexture> gh   = mk(dev, MTLPixelFormatR32Uint, MTLTextureType2DArray, W, H, 2);

    id<MTLTexture> colRT = mk(dev, MTLPixelFormatRGBA16Float, MTLTextureType2D, W, H, 1);
    id<MTLTexture> dsRT;
    { MTLTextureDescriptor *td=[[MTLTextureDescriptor alloc] init];
      td.pixelFormat=MTLPixelFormatDepth32Float_Stencil8; td.width=W; td.height=H;
      td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModePrivate;
      dsRT=[dev newTextureWithDescriptor:td]; }

    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = colRT;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.depthAttachment.texture = dsRT; rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.storeAction = MTLStoreActionStore;
    rp.stencilAttachment.texture = dsRT; rp.stencilAttachment.loadAction = MTLLoadActionClear;
    rp.stencilAttachment.storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:pso];
    MTLDepthStencilDescriptor *ds = [[MTLDepthStencilDescriptor alloc] init];
    ds.depthCompareFunction = MTLCompareFunctionAlways; ds.depthWriteEnabled = NO;
    MTLStencilDescriptor *st = [[MTLStencilDescriptor alloc] init];
    st.stencilCompareFunction = MTLCompareFunctionAlways;
    st.depthStencilPassOperation = MTLStencilOperationReplace;
    [enc setDepthStencilState:[dev newDepthStencilStateWithDescriptor:ds]];
    [enc setStencilReferenceValue:0x3];

    id<MTLTexture> texs[] = {rp_color, rp_value, dr1, dr2, dr3, ir1, ir2, ir3,
                             nil, nil, util, hiz, stm, satl, irat, lps,
                             nil,nil,nil,nil,nil,nil,nil,nil,nil, gc, gn, gh};
    for (int i = 0; i < 28; i++) if (texs[i]) [enc setFragmentTexture:texs[i] atIndex:i];
    id<MTLBuffer> zbuf = [dev newBufferWithLength:1<<20 options:MTLResourceStorageModeShared];
    int bufslots[] = {0, 6, 17, 18, 19, 30};
    for (int i = 0; i < 6; i++) [enc setFragmentBuffer:zbuf offset:0 atIndex:bufslots[i]];
    // vertex needs nothing

    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];

    id<MTLBuffer> bU = [dev newBufferWithLength:W*H*4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> bA = [dev newBufferWithLength:W*H*4 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl copyFromTexture:dr1 sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
             sourceSize:MTLSizeMake(W,H,1) toBuffer:bU destinationOffset:0
     destinationBytesPerRow:W*4 destinationBytesPerImage:W*H*4];
    [bl copyFromTexture:ir1 sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
             sourceSize:MTLSizeMake(W,H,1) toBuffer:bA destinationOffset:0
     destinationBytesPerRow:W*4 destinationBytesPerImage:W*H*4];
    [bl endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    if (cb.error) printf("CB ERROR: %s\n", [[cb.error description] UTF8String]);

    uint32_t *u=(uint32_t*)[bU contents]; uint32_t *a=(uint32_t*)[bA contents];
    int nu=0, na=0;
    for (int i=0;i<W*H;i++){ if(u[i]==9u)nu++; if(a[i])na++; }
    printf("direct_radiance_1 (R32Uint) texels==9: %d / %d\n", nu, W*H);
    printf("indirect_radiance_1 (RG11B10) nonzero: %d / %d\n", na, W*H);
    printf("verdict: %s\n", nu==0 ? "WRITES DROPPED — Blender codegen reproduces the bug"
                                  : "writes land — codegen not the cause either");
  }
  return 0;
}
