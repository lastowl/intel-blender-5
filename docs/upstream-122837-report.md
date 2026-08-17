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

**Candidate causes ruled out**

Each of these was tested by patching the source, rebuilding, and re-measuring,
not by reading code:

1. **The existing ATI/Intel macOS GBuffer workaround is not the cause.**
   Disabling the `GPU_DEVICE_ATI | GPU_DEVICE_INTEL | GPU_DEVICE_INTEL_UHD`
   branch in `GBuffer::bind()` (`eevee_gbuffer.hh`) so the normal
   `GPU_framebuffer_bind_ex` path runs changes nothing. Still 0.0.

2. **Stencil export is not the cause.** `mtl_backend.mm` sets
   `GCaps.stencil_export_support = true` unconditionally. I forced it false for
   AMD/Intel on macOS, so `DEFERRED_TILE_CLASSIFY` takes the per-bit fallback
   path (one full-screen pass per stencil bit) instead of the single-pass
   shader-exported path. Still 0.0. I verified with a `printf` that the flag was
   actually `0` at runtime, because an earlier attempt silently tested a stale
   binary.

   This one seems worth recording, since "*Ok this points to the stencil
   classify shader!*" implies the export mechanism, and swapping it out changes
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
