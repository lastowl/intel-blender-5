#!/usr/bin/env bash
# Publish a packaged dependency stack as a GitHub release.
#
# Run after package-deps.sh. Requires the gh CLI, authenticated with write
# access to the repository.
#
# The release tag encodes a hash of Blender's versions.cmake, so CI can work
# out which stack it needs without being told.

set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUT_DIR="${OUT_DIR:-$ROOT/deps-package}"
REPO="${REPO:-}"

if [[ ! -f "$OUT_DIR/manifest.txt" ]]; then
  echo "error: no manifest at $OUT_DIR/manifest.txt" >&2
  echo "Run scripts/package-deps.sh first." >&2
  exit 1
fi

tag="$(grep '^tag=' "$OUT_DIR/manifest.txt" | cut -d= -f2)"
blender_rev="$(grep '^blender_rev=' "$OUT_DIR/manifest.txt" | cut -d= -f2)"

# Default to the repository this checkout points at.
if [[ -z "$REPO" ]]; then
  # Strip scheme, any user@ prefix, host and .git suffix. HTTPS remotes that
  # embed a username (https://user@github.com/owner/name.git) are common and
  # were previously left intact, producing a mangled URL in the final message.
  REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null |
    sed -E 's#^git@github\.com:##; s#^https://([^@/]+@)?github\.com/##; s#\.git$##')"
fi
if [[ -z "$REPO" ]]; then
  echo "error: could not determine the repository; set REPO=owner/name" >&2
  exit 1
fi

parts=("$OUT_DIR/$tag.tar.gz.part-"*)
if [[ ! -e "${parts[0]}" ]]; then
  echo "error: no parts found in $OUT_DIR" >&2
  exit 1
fi

total=$(du -ch "${parts[@]}" | tail -1 | cut -f1)

echo "=== Publishing dependency stack ==="
echo "repo:    $REPO"
echo "tag:     $tag"
echo "parts:   ${#parts[@]} ($total)"
echo "built from Blender: $blender_rev"
echo

if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $tag already exists; uploading parts with --clobber."
  gh release upload "$tag" "${parts[@]}" "$OUT_DIR/manifest.txt" \
    --repo "$REPO" --clobber
else
  gh release create "$tag" "${parts[@]}" "$OUT_DIR/manifest.txt" \
    --repo "$REPO" \
    --title "x86_64 macOS dependency stack ($tag)" \
    --notes "Prebuilt Blender dependency stack for Intel macOS.

Built from Blender \`$blender_rev\` with the patch series in \`patches/\`.
The tag encodes a hash of \`build_files/build_environment/cmake/versions.cmake\`,
so any Blender revision with the same dependency versions can reuse this stack.

Consumed automatically by the build workflow via \`scripts/fetch-deps.sh\`.
Not an official Blender artifact."
fi

echo
echo "Published: https://github.com/$REPO/releases/tag/$tag"
