#!/usr/bin/env bash
# Package a built x86_64 dependency stack for publication.
#
# Produces a compressed tarball split into chunks below GitHub's 2 GB
# per-release-asset limit, plus a manifest with checksums. publish-deps.sh
# uploads the result; fetch-deps.sh reassembles it.
#
# The release is identified by a hash of Blender's versions.cmake rather than
# by a Blender version, because that file is what determines the contents of
# the stack. Two Blender releases with identical dependency versions share one
# published stack, so most mainline updates need no dependency rebuild at all.

set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BLENDER_SRC="${BLENDER_SRC:-$ROOT/blender}"
DEPS_INSTALL_DIR="${DEPS_INSTALL_DIR:-$ROOT/lib-x64-deps}"
OUT_DIR="${OUT_DIR:-$ROOT/deps-package}"

# Keep clear of the 2 GB asset ceiling.
CHUNK_SIZE="${CHUNK_SIZE:-1900m}"

if [[ ! -d "$DEPS_INSTALL_DIR" ]]; then
  echo "error: no dependency stack at $DEPS_INSTALL_DIR" >&2
  echo "Build it first with scripts/build-deps-x64.sh" >&2
  exit 1
fi

versions="$BLENDER_SRC/build_files/build_environment/cmake/versions.cmake"
if [[ ! -f "$versions" ]]; then
  echo "error: cannot find $versions" >&2
  exit 1
fi
hash="$(shasum -a 256 "$versions" | cut -c1-16)"
tag="deps-x64-$hash"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "=== Packaging x86_64 dependency stack ==="
echo "source:  $DEPS_INSTALL_DIR ($(du -sh "$DEPS_INSTALL_DIR" | cut -f1))"
echo "tag:     $tag"
echo "output:  $OUT_DIR"
echo

# Store paths relative to the stack root so it can be unpacked anywhere.
echo "Compressing (this takes a few minutes)..."
tar -czf "$OUT_DIR/$tag.tar.gz" -C "$DEPS_INSTALL_DIR" .

size_bytes=$(stat -f %z "$OUT_DIR/$tag.tar.gz")
echo "Compressed: $(du -h "$OUT_DIR/$tag.tar.gz" | cut -f1)"

# Always split, even when a single chunk would fit: it keeps the fetch side to
# exactly one code path.
echo "Splitting into ${CHUNK_SIZE} chunks..."
split -b "$CHUNK_SIZE" "$OUT_DIR/$tag.tar.gz" "$OUT_DIR/$tag.tar.gz.part-"
rm "$OUT_DIR/$tag.tar.gz"

{
  echo "tag=$tag"
  echo "versions_sha256_16=$hash"
  echo "tarball_bytes=$size_bytes"
  echo "blender_rev=$(git -C "$BLENDER_SRC" describe --tags --always 2>/dev/null || echo unknown)"
  echo "parts:"
  for f in "$OUT_DIR/$tag.tar.gz.part-"*; do
    echo "  $(basename "$f") $(shasum -a 256 "$f" | cut -d' ' -f1)"
  done
} > "$OUT_DIR/manifest.txt"

echo
echo "Parts:"
ls -lh "$OUT_DIR" | tail -n +2 | awk '{printf "  %-40s %s\n", $9, $5}'
echo
echo "Next: scripts/publish-deps.sh"
