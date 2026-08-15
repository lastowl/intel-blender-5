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

## Building on Apple Silicon

Both paths work from an arm64 host. `CMAKE_OSX_ARCHITECTURES=x86_64` makes the
compiler emit x86_64; Rosetta 2 transparently runs the x86_64 test binaries
that dependency configure scripts compile and execute, so the dependency build
behaves much like a native one.

Do **not** wrap `cmake` in `arch -x86_64`. Homebrew's cmake is a
single-architecture arm64 binary and fails with `Bad CPU type in executable`.
Architecture selection is CMake's job, not the process's.

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

Work in progress. See `patches/` for what has been needed so far.
