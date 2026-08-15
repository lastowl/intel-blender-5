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

## Build Blender anywhere, build the dependencies on Intel

These two halves behave very differently, and the split drives the whole
design:

* **Blender itself cross-compiles from arm64 without complaint.** Verified end
  to end: 10k+ objects, correct `-arch x86_64`, links, and the resulting
  bundle runs.
* **The dependency stack does not.** Each dependency detects the CPU itself,
  and they disagree with each other. `aom` compiled ARM NEON intrinsics into
  an x86_64 target (`unknown type name 'uint16x8_t'`); `x265` failed to
  configure; `x264` needs an autotools `--host` that Blender never passes,
  because upstream never cross-compiles. Every one of those is a patch to
  carry forever.

So: build the dependency stack **natively on Intel**, once, and cache it.
Then Blender can be built against it from any machine. That keeps the patch
series near-empty, which is the whole point — see the CI workflow.

If you do want to cross-compile the dependencies anyway,
`CMAKE_OSX_ARCHITECTURES=x86_64` makes the compiler emit x86_64 and Rosetta 2
runs the x86_64 test binaries that configure scripts build. Two rules:

* Do **not** wrap `cmake` in `arch -x86_64`. Homebrew's cmake is a
  single-architecture arm64 binary and fails with `Bad CPU type in
  executable`. Architecture selection is CMake's job, not the process's.
* Expect to keep fixing per-dependency CPU detection. Patch `0002` handles the
  CMake-based ones; the autotools-based ones are still open.

## Building in CI

`.github/workflows/build-intel-mac.yml` builds natively on GitHub's Intel
runner, caching the dependency stack so only the first run pays for it.

The cache is keyed on a hash of Blender's `versions.cmake`, not on the Blender
tag, so releases that share dependency versions share one cached stack — a new
mainline release usually costs a Blender build only, not a dependency build.

**Runner lifetime matters here.** `macos-13` was retired in December 2025. The
replacement label is `macos-15-intel`, and GitHub has said it is the last
x86_64 macOS image, available until **August 2027**. After that this needs a
self-hosted Intel runner, or the cross-compile path above.

The dependency build is also close to GitHub's 6-hour job ceiling on a cold
cache, which is why dependencies and Blender are separate jobs.

## Layout

```
scripts/build-deps-x64.sh     build the x86_64 dependency stack
scripts/build-blender-x64.sh  configure + build Blender, produce Blender.app
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

**Not yet done**

* A complete 5.2 build against a self-built dependency stack. The local
  cross-compiled dependency build reaches ~520 targets before `aom` and `x264`
  fail on architecture detection; the CI workflow sidesteps this by building
  natively on Intel.
* Nothing has been run in CI yet — the workflow is written but untested.
* GPU acceleration. Not started; the build has to land first.
