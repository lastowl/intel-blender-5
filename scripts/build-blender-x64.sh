#!/usr/bin/env bash
# Build Blender for Intel macOS (x86_64) and produce Blender.app.
#
# Works two ways:
#   * cross-compiled from an Apple Silicon host (the default here) -- CMake
#     runs as arm64 and emits x86_64 code via CMAKE_OSX_ARCHITECTURES
#   * natively on an Intel Mac or Intel CI runner, where the architecture
#     flag is simply a no-op
#
# Everything is parameterised through the environment so CI can drive it
# without editing the script.

set -euo pipefail

ROOT="${ROOT:-/Users/murple/blender5}"
BLENDER_SRC="${BLENDER_SRC:-$ROOT/blender}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build-x64}"
LIBDIR="${LIBDIR:-$ROOT/lib-x64-deps}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# Blender's own minimum for Intel macOS builds.
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-11.2}"

# Extra -D flags, e.g. EXTRA_CMAKE_ARGS="-DWITH_CYCLES_OSL=OFF"
EXTRA_CMAKE_ARGS="${EXTRA_CMAKE_ARGS:-}"

if [[ ! -d "$LIBDIR" ]]; then
  echo "error: LIBDIR does not exist: $LIBDIR" >&2
  echo "Build the dependency stack first (scripts/build-deps-x64.sh)," >&2
  echo "or point LIBDIR at an existing precompiled library directory." >&2
  exit 1
fi

# platform_apple.cmake insists the library directory be a git checkout.
# A self-built dependency tree is not one, so make it look like one. This is
# only a presence check on Blender's side; the contents are irrelevant.
if [[ ! -e "$LIBDIR/.git" ]]; then
  echo "note: $LIBDIR is not a git checkout; creating a marker to satisfy CMake"
  git -C "$LIBDIR" init -q
fi

echo "=== Blender x86_64 build ==="
echo "source:      $BLENDER_SRC"
echo "libdir:      $LIBDIR"
echo "build:       $BUILD_DIR"
echo "type:        $BUILD_TYPE"
echo "deploy tgt:  $DEPLOYMENT_TARGET"
echo "jobs:        $JOBS"
echo "blender rev: $(git -C "$BLENDER_SRC" describe --tags --always 2>/dev/null || echo unknown)"
echo

# Note: CMake runs as the host architecture. CMAKE_OSX_ARCHITECTURES is what
# makes the compiler emit x86_64; do not wrap this in `arch -x86_64`, because
# Homebrew's cmake is arm64-only and cannot execute under it.
# shellcheck disable=SC2086
cmake \
  -S "$BLENDER_SRC" \
  -B "$BUILD_DIR" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DLIBDIR="$LIBDIR" \
  $EXTRA_CMAKE_ARGS

# `install` is what assembles bin/Blender.app; plain `ninja` only links the
# executable and leaves the bundle incomplete.
ninja -C "$BUILD_DIR" -j "$JOBS" install

APP="$BUILD_DIR/bin/Blender.app"
echo
if [[ -d "$APP" ]]; then
  echo "Built: $APP"
  echo -n "architecture: "
  lipo -archs "$APP/Contents/MacOS/Blender"
else
  echo "warning: expected bundle not found at $APP" >&2
  exit 1
fi
