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
git clone --depth=1 --branch v5.2.0 \
  https://projects.blender.org/blender/blender.git blender

brew install autoconf automake bison dos2unix flex libtool \
  meson ninja pkg-config yasm nasm git-lfs

./scripts/apply-patches.sh
./scripts/build-deps-x64.sh    # hours, unattended
./scripts/package-deps.sh      # compress and split below the 2 GB asset cap
./scripts/publish-deps.sh      # upload as a release
```

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

## Layout

```
scripts/apply-patches.sh      apply the patch series to a Blender checkout
scripts/build-deps-x64.sh     build the x86_64 dependency stack (Intel Mac)
scripts/package-deps.sh       compress + split a built stack for publishing
scripts/publish-deps.sh       upload it as a GitHub release
scripts/fetch-deps.sh         download the stack matching a Blender checkout
scripts/build-blender-x64.sh  configure + build Blender, produce Blender.app
scripts/package-dmg.sh        wrap Blender.app into a .dmg
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

`WITH_METAL_BACKEND` is also already defined in our x86_64 build. So the
viewport is expected to be GPU-accelerated out of the box — this needs
confirming on real hardware, not asserting.

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

Order of work: confirm the viewport is already accelerated on real hardware
first, since that is most of the day-to-day benefit and may cost nothing. Then
attempt the Cycles revert as a separate, clearly-labelled patch that can be
dropped if it proves unstable — it should never be a prerequisite for a
working build.

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

**Not yet done**

* A complete 5.2 build against a self-built dependency stack — no CI run has
  reached the Blender job yet, so that half of the workflow is still untested.
* GPU acceleration. Not started; the build has to land first.
