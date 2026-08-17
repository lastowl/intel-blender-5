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

* **Viewport GPU acceleration is unconfirmed.** Cycles reports no Metal
  devices, exactly as predicted — `get_usable_devices()` filters out non-Apple
  GPUs, so `METAL: []` and rendering falls back to CPU. That is the *Cycles*
  subsystem. The EEVEE/viewport Metal backend is independent and still supports
  AMD and Intel, but confirming it needs an interactive launch on the real GPU;
  a background build cannot answer it. Do this before attempting the Cycles
  revert.
* The Cycles AMD/Intel revert (12 files, 22 conflict blocks).
* Nothing is code-signed. `package-dmg.sh` produces an unsigned image and
  documents `xattr -cr` as the workaround.
* CI has still never run the Blender job; that half of the workflow remains
  untested on a runner.
