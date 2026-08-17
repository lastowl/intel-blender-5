# Draft comment for blender/blender#122837

*Not posted. Review, adjust the tone and any details you want to change, then
post it yourself at
<https://projects.blender.org/blender/blender/issues/122837>.*

The value of this report is that the thread stalled on
"*I haven't been able to reproduce this issue locally as I don't have the same
hardware [...] I am lowering the priority of this issue until we found a way to
reproduce it*". This offers a reproducing machine, and rules out three
candidate causes so nobody repeats that work.

---

I have a reliably reproducing machine for the AMD/macOS side of this and can
run experiments on request, including patched builds — I build Blender from
source on it and an incremental rebuild takes about two minutes.

**System**

- MacBook Pro, Intel Core i9-9980HK
- AMD Radeon Pro 5500M (8 GB), Metal 3 — also has Intel UHD 630
- macOS 26.5 (25F84), Apple clang 21, MacOSX26.5 SDK
- Blender 5.2.0 LTS, built from `v5.2.0` for x86_64
- Reported GPU backend: `METAL`, vendor `AMD Radeon Pro 5500M`

**Reproduction**

Factory startup, EEVEE, render the default cube. It renders as a pure black
silhouette; the world background renders correctly. No shader compilation
errors, and render times are normal.

Measuring the centre pixel of the cube (0 = black) across variations, all on
the same machine in the same session:

| Variation | Cube |
| --- | --- |
| Default (`DITHERED`, deferred) | **0.0** |
| Material render method `BLENDED` (forward) | 0.549, correct |
| Emission shader | correct |
| Shadows disabled globally (`scene.eevee.use_shadows = False`) | 0.0 |
| Shadows disabled per-light (`light.use_shadow = False`) | 0.0 |
| Ray-tracing disabled | 0.0 |
| Light energy 100000 | 0.0 |
| Sun lamp, energy 10 | 0.0 |
| World lighting only, strength 3 | 0.0 |
| Cycles (CPU), same scene | correct |
| Workbench | correct |

The zero is exact and stays exact at 100000 W, so nothing is being attenuated —
those pixels are never shaded. This matches the emission/`BLENDED` findings
already in the thread, on AMD/macOS rather than Intel/Windows.

**Where the failure is, as far as I have traced it**

Working down the deferred path with instrumented builds:

1. **The GBuffer is written correctly.** Reading `gbuffer.header_tx` back
   immediately after `manager->submit(gbuffer_ps_, render_view)`:

   ```
   header_tx 200x200 layers=2 nonzero=4175/80000 max=0x1000031
   ```

   4175 non-zero texels is the cube's screen area, with real closure bits. So
   this is **not** a GBuffer write failure, and the classify shader is being
   handed valid input.

2. **The `Eval.Light` pass is submitted with shaders bound.** Instrumented:
   `closure_count_ = 2`, loop iterations 2, `eval_light_ps_.is_empty() == 0`,
   64 submissions in one render.

3. **But the eval fragment shader produces nothing, even unconditionally.** I
   put an unconditional store at the very top of `light_eval_frag`, before any
   branch:

   ```glsl
   const int2 texel = int2(frag_co.xy);
   srt.write_radiance_direct(uchar(0), texel, float3(4.0f, 0.0f, 0.0f));
   ```

   and additionally forced `write_radiance_direct` to encode a constant
   `float3(4, 0, 0)`. The cube stays exactly 0.0. Nothing turns red anywhere.

   That holds with the stencil test bypassed (`DRW_STATE_STENCIL_EQUAL` →
   `DRW_STATE_STENCIL_ALWAYS`) **and** with `DRW_STATE_DEPTH_LESS` removed
   from that sub-pass, so neither early-fragment test explains it.

4. **The fragment shader executes, and can write one bound image but not
   another, in the same invocation.** This is the sharpest result I have. I put
   two unconditional `imageStore` calls side by side at the top of
   `light_eval_frag`, before any branch:

   ```glsl
   imageStore(srt.direct_radiance_1_img,   texel, uint4(rgb9e5_encode(float3(4, 0, 0))));
   imageStore(srt.indirect_radiance_1_img, texel, float4(0, 4, 0, 1));
   ```

   Reading both textures back immediately after
   `manager->submit(eval_light_ps_, render_view)`:

   ```
   direct_radiance[0]   (uint)  200x200 nonzero=0/40000
   indirect_radiance[0] (float) 200x200 nonzero=40000/160000
   ```

   The indirect write lands on **every pixel**. The direct write lands on
   **none**. Same shader, same fragment, adjacent statements. So the fragment
   shader is definitely running, and the failure is specific to the
   `direct_radiance_*` images.

**Things that are *not* the cause**

I assumed the difference was the pixel format —
`DEFERRED_RADIANCE_FORMAT` is `UINT_32` (RGB9E5-packed) while
`RAYTRACE_RADIANCE_FORMAT` is `UFLOAT_11_11_10`. It is not. I converted the
whole deferred radiance path to the float format (`eevee_defines.hh`, the eval
shader's `uimage2D`→`image2D` and the dropped `rgb9e5_encode`, the combine
shader's `usampler2D`→`sampler2D` and dropped `rgb9e5_decode`, and the matching
changes in `eevee_subsurface.bsl.hh`), rebuilt, and cleared the shader cache.
**Still exactly 0.0.** That change is reverted.

Nor is it the texture pool: `--debug-gpu-no-texture-pool` changes nothing. Nor
is it an image binding slot collision — the render-buffer images occupy slots 0
and 1, the radiance images 2–7.

So the remaining difference between an image that accepts writes and one that
does not, from the same shader, is **how `direct_radiance_txs_` are allocated
and bound** (`TextureFromPool::acquire_2d(..., usage_read | usage_write)` in
`DeferredLayer::render()`) versus the raytracing-owned
`indirect_result_.closures[]`. I have not found what about that differs in a
way this GPU cares about, and would value a pointer.

**I have a Metal frame capture of the failing frame**

Captured headlessly (no Xcode attached) with a two-line change to
`MTLContext::debug_capture_begin` to send the capture to a
`MTLCaptureDestinationGPUTraceDocument` instead of the default
`MTLCaptureDestinationDeveloperTools`:

```
MTL_CAPTURE_ENABLED=1 BLENDER_MTL_CAPTURE_PATH=/path/eevee.gputrace \
blender --factory-startup --debug-gpu \
        --debug-gpu-scope-capture "EEVEE.render_sample" -P render.py
```

That yields a 636 MB `.gputrace` of the frame that renders black. I can upload
it or run queries against it — say the word.

From the captured shader sources I can confirm the Metal codegen is **not** the
problem: the eval shader declares its outputs correctly as
`texture2d<uint32_t, access::write> direct_radiance_{1,2,3}_img`, and the
combine shader declares the matching `access::read` versions. So the images are
bound with the right access qualifiers; the writes simply do not appear.

**A likely separate bug found on the way**

`eevee_deferred_tile_classify.bsl.hh` selects its stencil path at **compile
time**:

```glsl
#if defined(GPU_ARB_shader_stencil_export) || defined(GPU_METAL)
  gl_FragStencilRefARB = closure_count | is_transmission;
#else
  /* per-bit fallback using `current_bit` */
#endif
```

while `DeferredLayer::render()` selects its path at **runtime** on
`GPU_stencil_export_support()`. On Metal those disagree: setting
`GCaps.stencil_export_support = false` makes the host issue the per-bit
fallback draws, but the shader still compiles the `gl_FragStencilRefARB` branch
and ignores `current_bit`. The fallback is therefore unreachable on Metal, and
anyone trying to test it (as I first did) gets a misleading result. Worth
fixing independently of this bug.

**Candidate causes ruled out**

Each of these was tested by patching the source, rebuilding, and re-measuring,
not by reading code:

1. **The existing ATI/Intel macOS GBuffer workaround is not the cause.**
   Disabling the `GPU_DEVICE_ATI | GPU_DEVICE_INTEL | GPU_DEVICE_INTEL_UHD`
   branch in `GBuffer::bind()` (`eevee_gbuffer.hh`) so the normal
   `GPU_framebuffer_bind_ex` path runs changes nothing. Still 0.0.

2. **Stencil export is not the cause.** `mtl_backend.mm` sets
   `GCaps.stencil_export_support = true` unconditionally. Forcing it false is
   not sufficient on its own because of the compile-time/runtime mismatch noted
   above, so I patched **both**: `GCaps.stencil_export_support = false` *and*
   removed `GPU_METAL` from the shader's `#if`, so host and shader consistently
   take the per-bit fallback. Still 0.0.

   This is worth recording, since "*Ok this points to the stencil classify
   shader!*" implies the export mechanism, and replacing it end to end changes
   nothing.

3. **The known Metal caveats are not the cause.**
   `--debug-gpu-force-workarounds` (which on Metal disables texture gather,
   texture atomics and native tile inputs, and enables the texture pool
   workaround) changes nothing. Still 0.0.

**Metal validation is clean**

Running under both validation layers:

```
METAL_DEVICE_WRAPPER_TYPE=1 MTL_SHADER_VALIDATION=1 blender ...
Metal API Validation Enabled
Metal GPU Validation Enabled
```

produces no errors, warnings or assertions at all. So this does not look like
Blender making an API call that AMD rejects and Apple Silicon tolerates — every
call is accepted as valid. That points at a miscompute or a data-flow problem
rather than API misuse.

**A note on the in-render debug modes**

I tried to narrow this further with `DEBUG_GBUFFER_STORAGE` (14) and
`DEBUG_GBUFFER_EVALUATION` (15) to see whether the GBuffer is populated at all.
Those passes do **not** run during an F12 render — `DeferredPipeline::debug_pass_sync()`
early-returns because `Instance::debug_mode` is not set from `G.debug_value` on
the render path. They do run in the viewport (confirmed with a `printf`, 16
invocations). If that is unintended it may be worth a separate report; if
someone tells me the intended way to capture those two visualisations for a
still image, I will post them.

**What I can do next**

I have the hardware, a full source build and a fast incremental rebuild. Happy
to:

- run any patched build or capability toggle you want tested,
- bisect across versions or commits,
- capture a Metal frame capture from Xcode,
- dump specific buffer or texture contents if you point me at the place to
  instrument.

Tell me what would be most useful.
