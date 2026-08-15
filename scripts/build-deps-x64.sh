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

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BLENDER_SRC="${BLENDER_SRC:-$ROOT/blender}"
DEPS_INSTALL_DIR="${DEPS_INSTALL_DIR:-$ROOT/lib-x64-deps}"
DEPS_BUILD_DIR="${DEPS_BUILD_DIR:-$ROOT/build-deps-x64}"
LOG="${LOG:-$ROOT/logs/deps-x64.log}"
NPROCS="${NPROCS:-$(sysctl -n hw.ncpu)}"

# Homebrew keg-only tools the dependency builds need ahead of the ancient
# system versions (system bison is 2.3; several deps need 3.x).
HOMEBREW_PREFIX_DETECTED="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export PATH="$HOMEBREW_PREFIX_DETECTED/opt/bison/bin:$HOMEBREW_PREFIX_DETECTED/opt/flex/bin:$PATH"

# Matches the value the `deps` make target uses, for reproducible timestamps.
export SOURCE_DATE_EPOCH=1745584760

# Several dependencies (brotli, jpeg, blosc, openal, ...) still declare
# cmake_minimum_required(VERSION <3.5), which CMake 4.x refuses outright.
# This is CMake's supported escape hatch, and as an environment variable it
# reaches every ExternalProject sub-configure without patching each one.
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# ...but that only covers cmake_minimum_required. Dependencies that call
# cmake_policy(SET <id> OLD) for a policy CMake 4 deleted cannot be rescued
# that way -- alembic does exactly this with CMP0042. So the dependency build
# needs a CMake 3.x. Fail now with instructions rather than 15 minutes in.
cmake_major="$(cmake --version | head -1 | sed -E 's/[^0-9]*([0-9]+).*/\1/')"
if [[ "$cmake_major" -ge 4 ]]; then
  cat >&2 <<'EOF'
error: the dependency build requires CMake 3.x, found CMake 4 or newer.

  Blender's dependency tree predates CMake 4. alembic calls
  cmake_policy(SET CMP0042 OLD), whose OLD behaviour CMake 4 removed
  entirely, so it fails to configure no matter what compatibility flags
  are set.

  Install the last 3.x release and put it first on PATH, e.g.:

    version=3.31.12
    curl -fsSL -o /tmp/cmake.tar.gz \
      "https://github.com/Kitware/CMake/releases/download/v${version}/cmake-${version}-macos-universal.tar.gz"
    mkdir -p /tmp/cmake && tar -xzf /tmp/cmake.tar.gz -C /tmp/cmake --strip-components=1
    export PATH="/tmp/cmake/CMake.app/Contents/bin:$PATH"

  Blender itself builds fine under CMake 4 -- only this script needs 3.x.
EOF
  exit 1
fi

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
