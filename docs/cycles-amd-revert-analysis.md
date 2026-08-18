# Reverting Cycles AMD/Intel Metal support: what is actually possible

Analysis of reverting `c8340cf7541` ("Cycles: Remove AMD and Intel GPU support
from Metal backend", 116 insertions / 316 deletions across 15 files) onto
`v5.2.0`.

`git revert -n c8340cf7541` produces **12 conflicted files, 22 conflict
blocks**, matching the estimate this repository already carried. But the count
understates the problem: several conflicts cannot be resolved in favour of the
reverted code at all, because the code it depended on no longer exists.

## Not revertible — the ground moved

| Area | Why the old code cannot come back |
| --- | --- |
| `scene/light.cpp` | `device_update_lights(Device*, DeviceScene*, Scene*)` has been restructured into `count_lights(KernelIntegrator*, const Scene*)`. Different signature, different responsibilities. |
| `has_light_tree` | The whole capability gate is obsolete. The light tree is now unconditional; the flag is gone from `DeviceInfo`, `device.cpp` and `hip/device.cpp`. |
| `kernel/device/metal/context_begin.h` | The Intel texture-read workaround operates on `metal_ancillaries->textures_2d[]`. Bindless refactoring replaced that with `((ccl_global Texture2DParamsMetal*)metal_ancillaries->textures)[]`. The workaround has nothing left to operate on. |
| `device/metal/queue.mm` | The old fixed state-count logic has been replaced by working-set-aware sizing with `CYCLES_METAL_WORKING_SET_PERCENT`. The new code is strictly better. |
| `kernel/types.h`, `device/device.h` | Conflicts are whole superseded blocks — the `KERNEL_FEATURE` list and the old uninitialised `DeviceInfo` layout. |

Taking "theirs" on any of these would regress two years of Cycles work.

## Still meaningful — the real AMD accommodations

Five things the commit removed remain both applicable and substantive:

1. **Vendor detection.** `MetalGPUVendor { METAL_GPU_APPLE, METAL_GPU_AMD,
   METAL_GPU_INTEL }` plus `get_device_vendor()`. This one merges *cleanly* —
   `util.h` auto-merged with no conflict, so the enum and declaration are
   already back.

2. **Device admission.** `util.mm` gated AMD on macOS 12.3+, Intel on 13.0+,
   and preferred a discrete AMD over an integrated Intel when both were
   present (`CYCLES_METAL_FORCE_INTEL` to override). Current code admits only
   Apple GPUs by string match.

3. **MNEE disabled on AMD.** `info.has_mnee = vendor != METAL_GPU_AMD`. A real
   capability difference, not a workaround. Now spelled `has_mnee_` and
   unconditionally true.

4. **Kernel specialization restricted to Apple GPUs.** The removed code only
   applied `kernel_optimization_level` when `device_vendor == METAL_GPU_APPLE`;
   AMD stayed on `PSO_GENERIC`. Current code specializes regardless of vendor.
   This is not cosmetic — see the timing note below.

5. **Storage mode for non-unified memory.** The removed code set
   `default_storage_mode = MTLResourceStorageModeManaged`, using
   `MTLResourceStorageModeShared` only when `[mtlDevice hasUnifiedMemory]`.
   `default_storage_mode` no longer exists; `MTLResourceStorageModeShared` is
   hardcoded at roughly eight allocation sites. This is the largest piece of
   real work, and the one most likely to matter on a discrete GPU with its own
   VRAM.

## Measured: specialization is expensive on AMD

With the device gate simply opened and everything else left as upstream ships
it, kernel compilation on a Radeon Pro 5500M ran for **58 minutes without
completing** — two `MTLCompilerService` processes pegged at ~99%, one having
consumed 47 minutes of CPU.

That is exactly the configuration item 4 above prevented. Upstream never
specialized kernels for AMD, so opening the gate alone puts the compiler into
a state that was never supported or tuned for.

## Measured: it runs, and renders nothing

With `CYCLES_METAL_SPECIALIZATION_LEVEL=0` (the `PSO_GENERIC` path the removed
code used for AMD) the render **completed**:

```
RENDER_OK in 18622.7s        (5 h 10 m)
centre pixel RGBA (0, 0, 0, 0)
alpha 0 across the whole frame
```

Not a dark image — a completely empty one. No geometry, no world background,
nothing. Cycles accepted the device, compiled every kernel, dispatched the
render and wrote an empty film.

So the answer to "does the modern backend work on AMD without the removed
code" is **no**, and it fails silently rather than loudly, which is the same
shape as the EEVEE bug: work is dispatched, nothing lands.

## And the kernel cache is disabled on AMD

`MetalKernelPipeline::should_use_binary_archive()` refuses to archive for any
non-Apple vendor:

```objc
/* Workaround for issues using Binary Archives on non-Apple Silicon systems. */
MetalGPUVendor gpu_vendor = MetalInfo::get_device_vendor(mtlDevice);
if (gpu_vendor != METAL_GPU_APPLE) {
  return false;
}
```

No cache was written, so **every render pays the full compile again**. Even a
correct image would be unusable at five hours per frame. There is an escape
hatch — `CYCLES_METAL_DISABLE_BINARY_ARCHIVES=0` takes the earlier branch and
bypasses the vendor check — but the first run still has to populate the cache.

Note this function still consults `MetalGPUVendor`, so vendor awareness
survives in places even after the removal commit.

## Conclusion

A wholesale revert is the wrong instrument, and the surgical subset is larger
than it first appears.

The storage-mode item in particular is not a substitution. `Managed` buffers
require explicit `didModifyRange:` after CPU writes and `synchronizeResource:`
before CPU reads. The modern code makes none of those calls anywhere, because
it assumes unified memory throughout. Restoring `default_storage_mode` without
also restoring that synchronisation would simply fail in a different way.

Realistic assessment: making Cycles work on AMD Metal again is not a merge
exercise, it is re-implementing discrete-GPU support across the backend —
storage modes and their synchronisation, MNEE gating, specialization gating,
binary archives, and whatever the empty film turns out to be. That is
sustained work measured in days, against a five-hour edit-test cycle until
caching is forced on.

For contrast, the EEVEE fix that made the viewport and F12 renders work was
**four lines**. The two problems are not comparable in scale, and it is worth
being clear which one delivered the usable result.
