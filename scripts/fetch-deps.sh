#!/usr/bin/env bash
# Download and unpack a published x86_64 dependency stack.
#
# Works out which release it needs from the Blender checkout's versions.cmake,
# so it stays correct as Blender moves forward: if a release bumps dependency
# versions the tag changes and the fetch fails loudly, rather than silently
# building against a stale stack.

set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BLENDER_SRC="${BLENDER_SRC:-$ROOT/blender}"
DEPS_INSTALL_DIR="${DEPS_INSTALL_DIR:-$ROOT/lib-x64-deps}"
REPO="${REPO:-}"

versions="$BLENDER_SRC/build_files/build_environment/cmake/versions.cmake"
if [[ ! -f "$versions" ]]; then
  echo "error: cannot find $versions" >&2
  exit 1
fi
hash="$(shasum -a 256 "$versions" | cut -c1-16)"
tag="deps-x64-$hash"

if [[ -z "$REPO" ]]; then
  REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null |
    sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
fi
if [[ -z "$REPO" ]]; then
  echo "error: could not determine the repository; set REPO=owner/name" >&2
  exit 1
fi

echo "=== Fetching dependency stack ==="
echo "repo: $REPO"
echo "tag:  $tag"

if ! gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
  cat >&2 <<EOF

error: no published dependency stack for tag '$tag'.

This means Blender's dependency versions changed, so the existing stack no
longer matches this checkout. Rebuild and republish on an Intel Mac:

  scripts/build-deps-x64.sh     # hours, unattended
  scripts/package-deps.sh
  scripts/publish-deps.sh

Existing stacks:
EOF
  gh release list --repo "$REPO" --limit 20 2>/dev/null |
    grep '^deps-x64-' >&2 || echo "  (none)" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Downloading parts..."
gh release download "$tag" --repo "$REPO" --dir "$work" --pattern "*.part-*"

echo "Verifying..."
if gh release download "$tag" --repo "$REPO" --dir "$work" \
     --pattern "manifest.txt" 2>/dev/null; then
  # Manifest lines are "  <name> <sha256>"; check each part we downloaded.
  fail=0
  while read -r name want; do
    [[ -f "$work/$name" ]] || continue
    got="$(shasum -a 256 "$work/$name" | cut -d' ' -f1)"
    if [[ "$got" != "$want" ]]; then
      echo "  checksum mismatch: $name" >&2
      fail=1
    fi
  done < <(sed -n 's/^  \(.*\.part-[a-z]*\) \([0-9a-f]\{64\}\)$/\1 \2/p' "$work/manifest.txt")
  [[ $fail -eq 0 ]] || { echo "error: checksum verification failed" >&2; exit 1; }
  echo "  checksums OK"
else
  echo "  no manifest published; skipping checksum verification" >&2
fi

echo "Unpacking to $DEPS_INSTALL_DIR ..."
rm -rf "$DEPS_INSTALL_DIR"
mkdir -p "$DEPS_INSTALL_DIR"
cat "$work/$tag.tar.gz.part-"* | tar -xzf - -C "$DEPS_INSTALL_DIR"

echo "Done: $DEPS_INSTALL_DIR ($(du -sh "$DEPS_INSTALL_DIR" | cut -f1))"
