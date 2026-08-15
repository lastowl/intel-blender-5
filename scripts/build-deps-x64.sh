#!/usr/bin/env bash
# Build the full x86_64 macOS dependency stack for Blender 5.x.
#
# Why this exists:
#   Blender's official precompiled x64 libs (lib-macos_x64) are frozen at the
#   4.5 era (June 2025). Blender 5.1+ requires Python 3.13, and every C++ lib
#   that ships Python bindings (OIIO, USD, MaterialX, OSL, OCIO) must be
#   rebuilt against it. So we build the whole stack ourselves.
#
# On an Apple Silicon host this runs under Rosetta 2, so configure-time test
# binaries execute normally and the build behaves like a native x86_64 build
# rather than a true cross-compile. On a real Intel Mac it runs natively and
# the `arch` prefix is a no-op.
#
# This is slow (hours) but only needs redoing when Blender bumps dependency
# versions -- not on every mainline update.
#
# We drive CMake directly instead of using `make deps`, because that target
# hardcodes its CMake arguments and gives no way to pass the options below.

set -euo pipefail

BLENDER_SRC="${BLENDER_SRC:-/Users/murple/blender5/blender}"
DEPS_INSTALL_DIR="${DEPS_INSTALL_DIR:-/Users/murple/blender5/lib-x64-deps}"
DEPS_BUILD_DIR="${DEPS_BUILD_DIR:-/Users/murple/blender5/build-deps-x64}"
LOG="${LOG:-/Users/murple/blender5/logs/deps-x64.log}"
NPROCS="${NPROCS:-$(sysctl -n hw.ncpu)}"

# Homebrew keg-only tools the dependency builds need ahead of the ancient
# system versions (system bison is 2.3; several deps need 3.x).
HOMEBREW_PREFIX_DETECTED="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export PATH="$HOMEBREW_PREFIX_DETECTED/opt/bison/bin:$HOMEBREW_PREFIX_DETECTED/opt/flex/bin:$PATH"

# Matches the value the `deps` make target uses, for reproducible timestamps.
export SOURCE_DATE_EPOCH=1745584760

mkdir -p "$(dirname "$LOG")" "$DEPS_BUILD_DIR"

echo "=== Blender x86_64 dependency build ==="
echo "source:   $BLENDER_SRC"
echo "install:  $DEPS_INSTALL_DIR"
echo "build:    $DEPS_BUILD_DIR"
echo "jobs:     $NPROCS"
echo "log:      $LOG"
echo "blender:  $(git -C "$BLENDER_SRC" describe --tags --always 2>/dev/null || echo unknown)"
echo

{
  # PACKAGE_USE_UPSTREAM_SOURCES=OFF pulls dependency tarballs from Blender's
  # own mirror on projects.blender.org rather than from each project's
  # upstream host. Upstream hosts are a long tail of servers that go down,
  # move files, and (for ffmpeg.org here) can be unreachable from restricted
  # networks -- the mirror is one reliable host and is what CI should use.
  # Note: CMake itself runs as the host architecture. Do not wrap it in
  # `arch -x86_64` -- Homebrew's cmake is a single-architecture arm64 binary
  # and would fail with "Bad CPU type in executable". Targeting x86_64 is the
  # job of CMAKE_OSX_ARCHITECTURES, which propagates -arch x86_64 into every
  # dependency's compiler and linker flags. Dependency configure scripts that
  # compile and run small test binaries still work, because Rosetta 2 executes
  # the resulting x86_64 programs transparently.
  cmake \
    -S "$BLENDER_SRC/build_files/build_environment" \
    -B "$DEPS_BUILD_DIR" \
    -DHARVEST_TARGET="$DEPS_INSTALL_DIR" \
    -DPACKAGE_USE_UPSTREAM_SOURCES=OFF \
    -DCMAKE_OSX_ARCHITECTURES=x86_64

  make -C "$DEPS_BUILD_DIR" -j "$NPROCS" install
} 2>&1 | tee "$LOG"

echo
echo "Dependencies installed to $DEPS_INSTALL_DIR"
