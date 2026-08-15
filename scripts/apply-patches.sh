#!/usr/bin/env bash
# Apply the Intel-macOS patch series to a Blender checkout.
#
# Patches are kept as a numbered series in patches/ (produced by
# `git format-patch`). They are applied with `git am`, so a failure leaves the
# checkout mid-am with a clear conflict rather than a half-patched tree.
#
# An empty patches/ directory is not an error: on a native Intel host most of
# the series is unnecessary, and the goal is for this set to stay as close to
# empty as upstream allows.

set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BLENDER_SRC="${BLENDER_SRC:-$ROOT/blender}"
PATCH_DIR="${PATCH_DIR:-$ROOT/patches}"

shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
shopt -u nullglob

if [[ ${#patches[@]} -eq 0 ]]; then
  echo "No patches in $PATCH_DIR -- nothing to apply."
  exit 0
fi

echo "Applying ${#patches[@]} patch(es) to $BLENDER_SRC"

# git am needs an identity even though these commits are never pushed.
git -C "$BLENDER_SRC" \
  -c user.name="Intel Mac Builds" \
  -c user.email="noreply@localhost" \
  am --keep-non-patch "${patches[@]}"

echo "Applied cleanly."
git -C "$BLENDER_SRC" log --oneline -n "${#patches[@]}"
