# Blender 5.x for Intel macOS (x86_64)

Unofficial x86_64 macOS builds of Blender 5.x, plus the patch set and scripts
needed to reproduce them on each mainline Blender update.

Blender 4.5 LTS was the last release with official Intel macOS builds. From 5.0
onward the Blender Foundation ships Apple Silicon only, citing the maintenance
cost of Intel/AMD GPU-specific graphics bugs. The source tree, however, still
contains working x86_64 code paths — what actually disappeared was the
*precompiled dependency stack* and the CI that exercised it.

## What actually blocks an Intel build

Not the Blender source. Three concrete things:

1. **No precompiled x64 libraries for 5.x.** `lib-macos_x64` stops at
   `blender-v4.5-release`; its `main` branch is frozen at June 2025. The arm64
   equivalent has 5.0, 5.1, 5.2 and a current `main`.
2. **Python 3.13.** Blender 5.1+ requires it; the frozen x64 libs ship 3.11.
   This is the hard wall between the two approaches below, because every
   bundled C++ library that exposes Python bindings (OpenImageIO, USD,
   MaterialX, OSL, OpenColorIO) has to be rebuilt against the new interpreter.
3. **Missing dependencies.** Relative to the arm64 5.2 library set, the frozen
   x64 set lacks: `abseil`, `ceres`, `draco`, `eigen`, `fmt`, `meshoptimizer`,
   `openjph`, `rubberband`, `thorvg`, `tracy`, `xml2`, `xr_openxr_sdk`.
   It also predates Blender 5.0's requirement for
   `libavfilter`, so its bundled ffmpeg is unusable as-is.
   (`sse2neon` also differs, but is ARM-only and irrelevant here.)

| Target | Requires Python | Frozen x64 libs provide | Viable with frozen libs |
| --- | --- | --- | --- |
| v5.0.x | 3.11 | 3.11 | yes |
| v5.1.x | 3.13 | 3.11 | no |
| v5.2.x | 3.13 | 3.11 | no |

## Two approaches

**Frozen libraries (5.0.x only).** Clone `lib-macos_x64@main` into
`lib/macos_x64` and build against it. Fast, but capped at 5.0.x, and features
whose dependencies are absent must be disabled (`ffmpeg`, `rubberband`).

**Self-built dependency stack (5.1, 5.2, main).** Build the whole dependency
tree from source for x86_64 with `scripts/build-deps-x64.sh`. Slow — hours —
but it is the officially supported mechanism, produces correct versions of
everything, and only needs redoing when Blender bumps dependency versions,
not on every mainline update. This is the durable path.

## The dependency build needs CMake 3.x

Blender's dependency tree predates CMake 4, and two different things break
under it:

* `brotli`, `jpeg`, `blosc`, `openal` declare `cmake_minimum_required(VERSION
  <3.5)`, which CMake 4 rejects. `CMAKE_POLICY_VERSION_MINIMUM=3.5` handles
  these.
* `alembic` calls `cmake_policy(SET CMP0042 OLD)`, and CMake 4 deleted that
  policy's OLD behaviour outright. No compatibility flag rescues it.

So the dependency build pins the last 3.x release (3.31.12). Blender itself
builds fine under CMake 4 — only the dependency stack needs the pin, and
`build-deps-x64.sh` checks and fails immediately with instructions rather than
dying part-way through.

## Build Blender anywhere, build the dependencies on Intel

These two halves behave very differently, and the split drives the whole
design:

* **Blender itself cross-compiles from arm64 without complaint.** Verified end
  to end: 10k+ objects, correct `-arch x86_64`, links, and the resulting
  bundle runs.
* **The dependency stack does not.** Each dependency detects the CPU itself,
  and they disagree with each other. `aom` compiled ARM NEON intrinsics into
  an x86_64 target (`unknown type name 'uint16x8_t'`); `x264` needs an
  autotools `--host` that Blender never passes, because upstream never
  cross-compiles; `x265` fails to configure. Every one is a patch to write and
  carry forever, and the list was still growing when we stopped.

So: build the dependency stack **natively on Intel**, once, and cache it.
Then Blender can be built against it from any machine. That keeps the patch
series near-empty, which is the whole point — see the CI workflow.

If you want to cross-compile the dependencies anyway,
`CMAKE_OSX_ARCHITECTURES=x86_64` makes the compiler emit x86_64 and Rosetta 2
runs many of the x86_64 test binaries that configure scripts build. Known
blockers, all still open:

* **Do not wrap `cmake` in `arch -x86_64`.** Homebrew's cmake is a
  single-architecture arm64 binary and fails with `Bad CPU type in
  executable`. Architecture selection is CMake's job, not the process's.
* **`aom` compiles ARM NEON sources into an x86_64 target.** It derives its
  target CPU from `CMAKE_SYSTEM_PROCESSOR`, and passing
  `-DCMAKE_SYSTEM_PROCESSOR=x86_64` does **not** work: in a native (non
  cross-compiling) configure, `project()` overwrites that variable with the
  host value. Verified directly:

  ```
  -- BEFORE project(): [x86_64]
  -- AFTER  project(): [arm64]
  ```

  A real fix needs the per-dependency knob (`-DAOM_TARGET_CPU=x86_64`) or
  `CMAKE_SYSTEM_NAME` set to force genuine cross-compile mode, which brings its
  own problems.
* **`x264`** needs an autotools `--host`, which Blender never passes because
  upstream never cross-compiles.
* **`x265`** fails to configure.

(`spirv-tools` also failed here at first and looked architecture-related. It
was not — it reproduced identically on native Intel and turned out to be a
build-graph race, fixed by patch `0002`.)

Each is a patch to write and then carry forever. That is the argument for
building the dependencies natively.

## The dependency stack does not fit in CI

GitHub's Intel runner has **4 cores**, and a job may run for at most **6
hours**. The dependency stack needs roughly 7–8 hours there: run 7 of the
workflow reached `ispc` at **335 minutes** with OSL, OpenImageIO, USD, OpenVDB
and MaterialX still to build. That is a structural limit, not a bug to patch —
`timeout-minutes` cannot exceed 360, and staging the build across jobs means
carrying multi-GB state through a 10 GB cache.

So the stack is built **once on real Intel hardware** and published as a
GitHub release. CI then builds Blender against it in well under an hour.

This is cheap to live with because the release is tagged with a hash of
Blender's `versions.cmake`, not with a Blender version. Any Blender revision
whose dependency versions are unchanged reuses the same stack, so the usual
cost of a new mainline release is a Blender build alone.

### One time, on an Intel Mac

```bash
git clone https://github.com/lastowl/intel-blender-5.git
cd intel-blender-5

# Install the toolchain BEFORE cloning Blender. git-lfs has to exist at clone
# time or its smudge filter never runs, and Blender's configure then stops
# with "Detected incomplete startup blend, likely due to missing Git LFS
# checkout". `git lfs pull` below repairs a checkout made without it.
brew install autoconf automake bison dos2unix flex libtool \
  meson ninja pkg-config yasm nasm git-lfs

git clone --depth=1 --branch v5.2.0 \
  https://projects.blender.org/blender/blender.git blender
git -C blender lfs pull

# The dependency build needs CMake 3.x (see above). Put it somewhere durable
# rather than /tmp -- the build runs for hours and may span a reboot.
version=3.31.12
curl -fsSL -o /tmp/cmake.tar.gz \
  "https://github.com/Kitware/CMake/releases/download/v${version}/cmake-${version}-macos-universal.tar.gz"
mkdir -p ~/.local/opt/cmake-${version}
tar -xzf /tmp/cmake.tar.gz -C ~/.local/opt/cmake-${version} --strip-components=1
export PATH="$HOME/.local/opt/cmake-${version}/CMake.app/Contents/bin:$PATH"

./scripts/apply-patches.sh
./scripts/build-deps-x64.sh    # hours, unattended
./scripts/package-deps.sh      # compress and split below the 2 GB asset cap
./scripts/publish-deps.sh      # upload as a release
```

`build-deps-x64.sh` defaults to `hw.ncpu` jobs. On a machine with fewer
physical cores than threads, set `NPROCS` below that — LLVM and USD link steps
are memory-hungry, and swapping costs more than the extra threads gain. The
build recorded below used `NPROCS=12` on 8 physical cores / 32 GB.

`build-deps-x64.sh` checks for CMake 3.x up front and prints how to install it
rather than failing part-way through. If dependency versions later change,
`fetch-deps.sh` fails loudly with the exact commands to rebuild, instead of
silently using a stale stack.

### Then, per Blender release

Run the **Build Blender (Intel macOS)** workflow with the tag you want. It
applies the patch series, fetches the published stack, builds, and uploads a
`.dmg`.

**Runner lifetime matters here.** `macos-13` was retired in December 2025. The
replacement label is `macos-15-intel`, and GitHub has said it is the last
x86_64 macOS image, available until **August 2027**. After that this needs a
self-hosted Intel runner — which is also the option that would remove the
6-hour ceiling entirely.

## Identity and signing

**Rebuilding this repo requires no Apple account, no certificate and no
configuration.** Signing and notarization are driven entirely by secrets that
are empty in a fork, and each script prints why it is skipping and exits 0.
The result is an unsigned `.dmg`, which is the normal, supported outcome. A
locally built app runs without ceremony; one that has been *downloaded*
unsigned needs its quarantine flag cleared:

```bash
xattr -cr /Applications/Blender.app
```

### This is not an official Blender build, and says so

Blender hardcodes `CFBundleIdentifier = org.blenderfoundation.blender`, with no
CMake option to change it. An unofficial build inheriting that identifier
collides with an official install in Launch Services, and a *signed* one
asserts Blender Foundation provenance under someone else's Developer ID. So
`scripts/brand-app.sh` runs unconditionally, signed or not, and:

* sets the bundle identifier to `org.unofficial.blender-intel-x64` (override
  with the `BUNDLE_ID` repository variable),
* rewrites the Get Info string to say it is an unofficial x86_64 build not
  affiliated with or endorsed by the Blender Foundation,
* drops the exported `.blend` UTI claim, so an unofficial build cannot outrank
  a real install as the system handler for `.blend` files.

The defaults are deliberately generic. `BUNDLE_VENDOR` is empty unless set, so
nobody who forks this inherits the identity of whoever published it. This is a
technical best effort, not legal advice — check Blender's current trademark
policy before distributing publicly.

### Publishing signed releases

Set these on the repository. Signing turns on when they are present:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERT_P12` | base64 of the Developer ID Application `.p12` |
| `MACOS_CERT_PASSWORD` | its export password |
| `MACOS_CODESIGN_IDENTITY` | e.g. `Developer ID Application: Example Ltd (TEAMID)` |
| `APPLE_API_KEY_P8` | base64 App Store Connect API key, for notarization |
| `APPLE_API_KEY_ID`, `APPLE_API_ISSUER` | its identifiers |

| Variable | Purpose |
| --- | --- |
| `BUNDLE_ID` | override the unofficial bundle identifier |
| `BUNDLE_VENDOR` | name shown in Get Info; blank when unset |

An App Store Connect API key is preferred over an Apple ID and app-specific
password: it is scoped, revocable, and no account password reaches the runner.
The workflow imports the certificate into a temporary keychain and deletes it
in an `if: always()` step, so a cert is never left behind on a failure.

Hardened runtime is required for notarization and would break Blender without
entitlements — Python `ctypes` needs unsigned executable memory, `.so` plugins
need library validation disabled, and OSL's LLVM JIT needs `allow-jit`.
`sign-app.sh` uses Blender's own `release/darwin/entitlements.plist` rather
than inventing a set. Signing is inside-out: 193 nested binaries, then the
thumbnailer extension with its sandbox entitlements, then the app. Signing the
app first and its libraries afterwards silently invalidates the outer
signature.

Verified locally end to end: `flags=0x10000(runtime)`, valid Developer ID
chain, timestamped, and the signed bundle still passes `ctypes`, imports
`numpy`/`zstandard`, and renders with OSL. Gatekeeper reports
`rejected / source=Unnotarized Developer ID` until the notarization step runs,
which is expected.

**Never run the app between signing and packaging.** Blender's bundled Python
writes `__pycache__/*.pyc` next to its sources on import, and any `.pyc`
created after signing is a file the signature does not cover:

```
a sealed resource is missing or invalid
```

This is easy to trigger by accident, and it bites silently — the image builds,
uploads, and only fails on the user's machine. Three defences are in place:

* `sign-app.sh` deletes every `__pycache__` directory before sealing, so the
  signed set is deterministic (68 of them in a 5.2.0 bundle).
* `package-dmg.sh` reads the version from `Info.plist` instead of executing
  `Blender --version`. Running the binary to ask its version was itself enough
  to break the signature it had just been given.
* `package-dmg.sh` re-verifies a signed bundle before packaging and refuses to
  build the image if the seal is broken, and copies with `ditto` rather than
  `cp -R`, which does not reliably preserve the extended attributes a
  signature depends on.

## Layout

```
scripts/apply-patches.sh      apply the patch series to a Blender checkout
scripts/build-deps-x64.sh     build the x86_64 dependency stack (Intel Mac)
scripts/package-deps.sh       compress + split a built stack for publishing
scripts/publish-deps.sh       upload it as a GitHub release
scripts/fetch-deps.sh         download the stack matching a Blender checkout
scripts/build-blender-x64.sh  configure + build Blender, produce Blender.app
scripts/brand-app.sh          set unofficial bundle identity (always runs)
scripts/sign-app.sh           codesign the bundle (skips with no identity)
scripts/package-dmg.sh        wrap Blender.app into a .dmg, sign if configured
scripts/notarize-dmg.sh       notarize + staple (skips with no credentials)
patches/                      patch series, regenerated from the blender repo
logs/                         build logs
blender/                      Blender source checkout (branch: intel-x64-<ver>)
```

## Patch workflow

Patches live as commits on a branch in the Blender checkout, and are exported
as a numbered series:

```bash
cd blender
git format-patch v5.2.0..intel-x64-5.2 -o ../patches/
```

To move to a new mainline release, rebase the branch onto the new tag and
re-export. Conflicts are the signal that a patch has been made redundant
upstream, or needs rework:

```bash
cd blender
git fetch --tags origin
git rebase v5.3.0 intel-x64-5.2
```

## GPU acceleration

"GPU support on Intel Macs" is really two independent subsystems, and they are
in very different states in 5.2. This matters, because one of them may need no
work at all.

**Viewport / EEVEE (the Metal GPU backend, `source/blender/gpu/metal`) still
supports AMD and Intel GPUs.** Nothing was removed here. `mtl_backend.mm`
detects `GPU_DEVICE_ATI` and `GPU_DEVICE_INTEL`, selects the immediate-mode
architecture path (`GPU_ARCHITECTURE_IMR`) for non-Apple GPUs, carries
AMD-specific workarounds, and its support check explicitly accepts both
vendors:

```objc
/* Known good configs. */
if (strstr(vendor, "AMD") || strstr(vendor, "Apple") || ...) { ... }
/* Explicit support for Intel-based platforms. */
if ((strstr(vendor, "Intel") || strstr(vendor, "INTEL"))) { ... }
```

`WITH_METAL_BACKEND` is also already defined in our x86_64 build, so the
viewport was *expected* to be GPU-accelerated out of the box.

**Measured on real hardware, that expectation is half right.** On a MacBook Pro
with an AMD Radeon Pro 5500M (8 GB) and Intel UHD 630, Blender 5.2.0 x86_64
reports:

```
backend  METAL
vendor   AMD Radeon Pro 5500M
```

So the Metal backend does initialise and select the discrete AMD GPU. But what
it then draws depends entirely on which path is exercised:

| Path | GPU used | Result |
| --- | --- | --- |
| Workbench (solid viewport) | AMD Metal | **correct** |
| EEVEE, emission shader | AMD Metal | **correct** |
| EEVEE, point light | AMD Metal | **black** |
| EEVEE, sun lamp (energy 10) | AMD Metal | **black** |
| EEVEE, world lighting only | AMD Metal | **black** |
| Cycles, GPU | none offered | no usable Metal device |
| Cycles, CPU | — | correct |

Identical scene, same session: Cycles renders the default cube correctly lit
while EEVEE renders it as a pure black silhouette against a world background
that *does* render. No shader compilation errors are emitted, and the render
completes in normal time.

The emission result is the informative one. Geometry, materials, shader
compilation and rasterisation are all fine — an emissive cube renders bright
and correct. What produces nothing is **light transport onto surfaces**: point,
sun and world lighting all contribute zero. So this is not "the Metal backend
is broken on AMD"; it is specifically EEVEE's lighting evaluation.

The practical consequence: **solid-mode viewport work is GPU-accelerated and
correct**, which is most of day-to-day modelling. EEVEE rendering and material
preview are not usable, and Cycles is CPU-only. That is a materially different
picture from "the viewport is fine", and it is exactly the class of
driver/compiler problem upstream cited when removing AMD from Cycles Metal —
which weakens the assumption that a Cycles revert would produce correct output
on this hardware even once it compiles.

### It is EEVEE's deferred path, and it is a known upstream bug

The failure is exactly and only the **deferred** pipeline. Setting a material's
render method switches which path it takes, and that flips the result:

| Material render method | Path | Cube brightness |
| --- | --- | --- |
| `DITHERED` (default) | deferred | **0.0** |
| `BLENDED` | forward | **0.549**, correct |

Zero is *exact*, and stays exact with shadows disabled globally, shadows
disabled per-light, ray-tracing off, and light energy raised to 100000. Nothing
is being attenuated — the deferred lighting pass simply never shades those
pixels.

This is [#122837, "EEVEE: Black surfaces on Intel GPU"][b1], **open and
`Status/Confirmed` since June 2024** and still being commented on in 2026. It
covers Intel iGPUs on Windows and AMD Radeon Pro on macOS together. Two things
in that thread matter here:

* A Blender developer reached the same conclusion from the same test —
  "*The Emission Shader works*" → "*Ok this points to the stencil classify
  shader!*"
* It is unfixed because **nobody upstream can reproduce it**: "*I haven't been
  able to reproduce this issue locally as I don't have the same hardware
  [...] I am lowering the priority of this issue until we found a way to
  reproduce it.*"

That is the real opportunity. We have the hardware they lack, a full source
tree, and a warm build directory where an EEVEE or GPU-backend change rebuilds
in about two minutes.

### Hypotheses eliminated so far

Each was tested by patching, rebuilding and re-measuring, not by reading code:

| Hypothesis | Test | Result |
| --- | --- | --- |
| The ATI/Intel Mac gbuffer bind workaround is itself wrong | disabled it in `eevee_gbuffer.hh` | still 0.0 |
| Metal claims `stencil_export_support` but AMD cannot do it | forced it false, taking the per-bit fallback path | still 0.0 (flag confirmed `0` at runtime) |
| One of the known Metal caveats (texture gather, texture atomics, native tile inputs, texture pool) | `--debug-gpu-force-workarounds` | still 0.0 |
| Blender is making a Metal call AMD rejects and Apple Silicon tolerates | `METAL_DEVICE_WRAPPER_TYPE=1 MTL_SHADER_VALIDATION=1` | **no errors at all** — every call is valid |

The stencil-export result is worth recording upstream: it is the mechanism the
developer's "points to the stencil classify shader" hypothesis implies, and
disabling it changes nothing. Either the classify shader computes no bits at
all, or the deferred lighting pass fails for a reason unrelated to stencil.

### Traced down the deferred path

Instrumented builds, reading GPU state back directly:

1. **The GBuffer is written correctly.** Reading `gbuffer.header_tx` back right
   after the GBuffer pass gives `nonzero=4175/80000, max=0x1000031` — the
   cube's screen area, with real closure bits. So the GBuffer write is *not*
   the fault, and the classify shader receives valid input. (This refutes the
   intuitive guess that the GBuffer was empty.)
2. **The `Eval.Light` pass is dispatched.** `closure_count_ = 2`, two loop
   iterations, `eval_light_ps_.is_empty() == 0`, 64 submissions per render.
3. **Yet the eval fragment shader emits nothing, even unconditionally.** An
   unconditional `write_radiance_direct(0, texel, float3(4,0,0))` at the very
   top of `light_eval_frag`, with `write_radiance_direct` itself forced to a
   constant, still leaves the cube at exactly 0.0 — with the stencil test
   bypassed *and* `DRW_STATE_DEPTH_LESS` removed, so neither early-fragment
   test explains it.

So: the pass runs, its input is valid, and its output never lands. The
remaining suspect — not yet proven — is that **fragment-shader `imageStore`
into the `direct_radiance_*_img` images silently does nothing on this GPU**.
That fits everything: the GBuffer, emission and `BLENDED` all write through
ordinary colour attachments and all work; only the deferred lighting result,
written via `imageStore`, disappears. A dropped write is not an API error,
which is consistent with validation being clean.

### A separate latent bug found on the way

`eevee_deferred_tile_classify.bsl.hh` picks its stencil path at **compile
time** (`#if defined(GPU_ARB_shader_stencil_export) || defined(GPU_METAL)`),
while `DeferredLayer::render()` picks at **runtime** on
`GPU_stencil_export_support()`. On Metal these disagree: forcing the capability
false makes the host issue the per-bit fallback draws while the shader still
compiles the `gl_FragStencilRefARB` branch and ignores `current_bit`. The
fallback is unreachable on Metal, and anyone testing it naively gets a
misleading pass — as happened here on the first attempt.

A draft report carrying all of this is in `docs/upstream-122837-report.md`,
written to give upstream the reproducing machine they have been missing. It is
not posted; that is a maintainer decision.

Remaining avenue: a Metal frame capture from Xcode to confirm or refute the
`imageStore` hypothesis directly.

### Workaround available today

Set the material's **Settings → Surface → Render Method** from `Dithered` to
`Blended`. Verified here: black becomes a correctly lit surface matching
Cycles. It is not free — forward rendering changes transparency sorting and
costs performance — but it makes EEVEE usable on an AMD Mac right now.

[b1]: https://projects.blender.org/blender/blender/issues/122837

**Cycles GPU rendering does not.** AMD and Intel were removed from the Cycles
Metal backend in 4.3 by `c8340cf7541` ("Cycles: Remove AMD and Intel GPU
support from Metal backend", 15 files, +118/−318). The gate now lives in
`MetalInfo::get_usable_devices()`:

```objc
if (!(strstr(device_name_char, "Intel") || strstr(device_name_char, "AMD")) &&
    strstr(device_name_char, "Apple"))
```

An AMD Mac therefore reports "No usable Metal devices found" and falls back to
CPU rendering.

Re-adding it is not a one-line revert. The upstream reasoning was Metal
driver/compiler bugs on those GPUs that forced parts of Cycles to be disabled,
and the revert has to land on two years of subsequent Cycles work — including
the bindless-resource refactor (`CYCLES_USE_TIER2D_BINDLESS`), which assumes
argument-buffer capabilities an older AMD GPU may not have.

A trial `git revert c8340cf7541` onto `v5.2.0` gives a concrete size estimate:
**12 files conflict, 22 conflict blocks**, concentrated in
`device/metal/device_impl.mm` (5) and spread across `device.cpp`, `queue.mm`,
`util.mm`, `context_begin.h`, `kernel/types.h` and `scene/light.cpp`. Tractable,
but every resolution is a judgement call that can only be validated on real AMD
hardware.

Order of work, revised now that the viewport has actually been measured:

1. **Diagnose EEVEE's black lighting on AMD.** This is the highest-value item
   and was not previously on the list, because the viewport was assumed fine.
   It affects every AMD Mac, is reproducible in a two-line script, and unlike
   the Cycles revert it is a bug hunt rather than a merge conflict.
2. **Only then consider the Cycles revert.** The evidence above argues for
   caution: EEVEE already demonstrates that lighting maths on this GPU can
   silently produce zeros with no error. Resolving 22 conflict blocks to reach
   a Cycles backend that renders black would be a poor trade. Establishing
   *why* EEVEE's lighting fails would say a lot about whether Cycles can work
   here at all.

Solid-mode viewport acceleration already works and needs nothing.

## Status

**Verified so far**

* A 5.0.1 x86_64 bundle builds, links, and runs (`Blender 5.0.1`, minimum
  macOS 11.2), cross-compiled from an Apple Silicon host against the frozen
  4.5-era libraries. `WITH_CODEC_FFMPEG` and `WITH_CODEC_SNDFILE` are off:
  that library set predates 5.0's `libavfilter` requirement, and `libopus.a`
  ships only inside the ffmpeg directory, so dropping ffmpeg breaks sndfile's
  link. A validation build, not a shippable one.
* The patch series applies cleanly to both `v5.2.0` and mainline (5.3 alpha),
  which is the property that makes it re-appliable each release.
* **The full x86_64 dependency stack builds on real Intel hardware.** 1.3 GB
  harvested from `v5.2.0` plus patches `0001`–`0008`; all 403 `.a`/`.dylib`
  files are `x86_64` with no exceptions. Python is 3.13.13, and every
  dependency the frozen 4.5-era set lacked is present: `abseil`, `ceres`,
  `draco`, `eigen`, `fmt`, `meshoptimizer`, `openjph`, `rubberband`, `thorvg`,
  `tracy`, `xml2`, `xr_openxr_sdk`, and an ffmpeg with `libavfilter`.
  This is the artefact the whole split design depends on.

**CI history**

| Run | Outcome |
| --- | --- |
| 1 | `alembic` failed — `cmake_policy(SET CMP0042 OLD)` deleted in CMake 4. Fixed by pinning CMake 3.31.12. |
| 2 | `alembic` passed; `spirv-tools` failed on a build-graph race. Fixed by patch `0002`. |
| 3 | Failed on `spirv-tools` again — the deps job was never applying the patch series. Workflow fixed. |
| 4 | Reached 54%; `spirv-tools` no longer raced. `x265` failed: `nasm: error: unrecognised option '-m'`. Fixed by patch `0003`. |
| 5 | `x265` fixed. Reached 56%; `flac` failed trying to regenerate autotools output with `aclocal-1.16`. Fixed by patch `0004`. |
| 6 | `flac` fixed. Reached 70%; `zstandard` failed with its output hidden by `LOG_BUILD 1`. Workflow now surfaces those logs. |
| 7 | Cleared zstandard and **LLVM**. Failed at 335 min on `ispc` (libc++ noexcept mismatch). Fixed by patch `0005`. |

Run 7 also established the real constraint: 335 minutes to reach `ispc`,
with OSL, OpenImageIO, USD, OpenVDB and MaterialX still to build, against
GitHub's hard 6-hour per-job ceiling on a 4-core runner. Patch `0005` alone
will not make a run fit; the dependency build has to move off a single
hosted job.

Native Intel confirmed its worth in run 2: `aom` built AVX2 intrinsics
correctly, the exact thing that fails when cross-compiling.

Note the correction below: run 6's zstandard failure was never actually
fixed. It is a race, and run 7 only got lucky.

**Native Intel build history** (i9-9980HK, 8 cores / 32 GB, `NPROCS=12`,
Apple clang 21 / macOS 26.5 SDK)

| Attempt | Outcome |
| --- | --- |
| 1 | Cleared `x265`, `flac`, `aom` and **LLVM** in 65 min. Failed on `zstandard`: `ModuleNotFoundError: No module named 'packaging'`. Fixed by patch `0006`. |
| 2 | Cleared `zstandard`, **`ispc`** (11 min in — patch `0005` validated), MaterialX and OpenVDB. Reached 96%; `openimagedenoise` failed needing the Metal shader compiler. Fixed by patch `0007`. |
| 3 | Cleared OIDN and `shaderc`. Reached 98%; `openimageio` failed compiling against Mono's bundled libtiff 4.0.9. Fixed by patch `0008`. |
| 4 | Cleared OpenImageIO, OSL and USD. **100%, complete stack harvested.** |

Three findings there that CI could not structurally have produced:

* **`zstandard` is a build-graph race, not a transient.** Its `setup.py`
  imports `packaging`, which `external_python_site_packages` installs, but
  `external_zstandard` only declared `external_python`. More parallelism
  exposes it; 4 cores mostly hid it. `numpy` and `cython` are held out of the
  pip install for the same reproducibility reason and both already declared
  the edge — zstandard was the omission. Patch `0006`.
* **OIDN's Metal device is wrong on Intel.** `openimagedenoise.cmake` set
  `OIDN_DEVICE_METAL=ON` for all of `APPLE`. OIDN supports Metal only on
  "Apple silicon GPUs (M1 and newer)", so on x86_64 it builds a backend the
  hardware can never instantiate — and building it needs the Metal shader
  compiler, a separate Xcode component absent from Command Line Tools. Fatal
  at 96% for nothing. Patch `0007` gates it on `BLENDER_PLATFORM_ARM`; the CPU
  device is unaffected.
* **An unpinned JPEG defeats a pinned TIFF.** `CMAKE_FIND_FRAMEWORK` defaults
  to `FIRST` on macOS. ZLIB, PNG and TIFF are pinned by explicit
  `_LIBRARY`/`_INCLUDE_DIR`, but JPEG is only hinted via `JPEG_ROOT`, so a Mono
  install resolves `JPEG_INCLUDE_DIR` to `Mono.framework/Headers` — which also
  ships `tiffio.h` from libtiff 4.0.9 and shadows our 4.7.1 via `-isystem`.
  Only reproduces on hosts carrying such a framework, which is why CI never saw
  it. Patch `0008` sets `CMAKE_FIND_FRAMEWORK=LAST`. The stack is meant to be
  hermetic.

The dependency stack does fit comfortably on real hardware: roughly 2 hours of
wall time across the four attempts, against the 7–8 hours CI needed to not
even finish.

**Blender 5.2.0 builds and runs against the self-built stack**

Built natively on the Intel Mac, `Blender 5.2.0 LTS`, `x86_64`, minimum macOS
11.2, 967 MB bundle. Tested, not merely linked:

| Check | Result |
| --- | --- |
| `--version` | `Blender 5.2.0 LTS`, `x86_64` |
| Python | 3.13.13 |
| `numpy` / `zstandard` import | 2.3.4 / 0.25.0 |
| Cycles CPU render **with OSL on** | 160×160×16spp in 1.4 s, correct image |
| ffmpeg H.264 encode | valid MP4 written |
| `WITH_CODEC_FFMPEG` / `WITH_CODEC_SNDFILE` | both **ON** |

The OSL render is the meaningful one: `shading_system = True` drives the LLVM
built in the dependency stack, so it exercises the longest pole end to end.
ffmpeg and sndfile being on is the concrete payoff over the frozen-library
route, which has to disable both.

One fix was needed in `build-blender-x64.sh`. Blender only defaults
`CMAKE_INSTALL_PREFIX` to the executable output directory inside
`if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)`, which holds only on the
first configure of a fresh cache. An earlier configure that failed for an
unrelated reason leaves `/usr/local` in the cache, and the override never fires
again — so `ninja install` tries to assemble the bundle in `/usr/local`. The
script now passes the prefix explicitly, which is idempotent and picks the same
value Blender would have.

**Not yet done**

* **EEVEE lighting renders black on AMD Metal.** Now measured, not assumed —
  see the GPU section. Solid-mode viewport is correctly accelerated on the
  Radeon Pro 5500M and emissive materials render fine, but point, sun and world
  lighting all contribute zero, with no error reported. Diagnosing this is the
  highest-value GPU work.
* Cycles GPU is unavailable by upstream design: `get_usable_devices()` rejects
  any device whose name contains "AMD" or "Intel", so `METAL: []` and rendering
  falls back to CPU. Not a defect in this build.
* The Cycles AMD/Intel revert (12 files, 22 conflict blocks) — deferred behind
  the EEVEE diagnosis, which is cheaper and informs whether the revert is even
  worth attempting.
* Nothing is code-signed. `package-dmg.sh` produces an unsigned image and
  documents `xattr -cr` as the workaround.
* CI has still never run the Blender job; that half of the workflow remains
  untested on a runner.
