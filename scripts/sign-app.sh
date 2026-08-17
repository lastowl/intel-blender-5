#!/usr/bin/env bash
# Codesign a built Blender.app with a Developer ID, if one is configured.
#
# THIS IS OPTIONAL AND OFF BY DEFAULT. With CODESIGN_IDENTITY unset the script
# prints why it is skipping and exits 0, so a public checkout builds and
# packages with no Apple account, no certificate and no configuration. Only
# whoever publishes signed releases sets these.
#
#   CODESIGN_IDENTITY   e.g. "Developer ID Application: Example Ltd (TEAMID)"
#                       unset -> skip signing entirely
#   KEYCHAIN            optional keychain to search (CI uses a temp one)
#
# Order matters. codesign seals a bundle's contents, so anything nested has to
# be signed before the thing containing it -- deepest first, app last. Signing
# the app first and the libraries after silently invalidates the outer
# signature.
#
# Hardened runtime is required for notarization, and it breaks Blender without
# entitlements: Python ctypes needs unsigned executable memory, dylib plugins
# need library validation disabled, and OSL's LLVM JIT needs allow-jit.
# Blender ships exactly those in release/darwin/entitlements.plist, so use its
# own file rather than inventing one.

set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP="${APP:-$ROOT/build-x64/bin/Blender.app}"
BLENDER_SRC="${BLENDER_SRC:-$ROOT/blender}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
KEYCHAIN="${KEYCHAIN:-}"

ENTITLEMENTS="${ENTITLEMENTS:-$BLENDER_SRC/release/darwin/entitlements.plist}"
APPEX_ENTITLEMENTS="${APPEX_ENTITLEMENTS:-$BLENDER_SRC/release/darwin/thumbnailer_entitlements.plist}"

if [[ -z "$CODESIGN_IDENTITY" ]]; then
  cat <<'EOF'
note: CODESIGN_IDENTITY is not set -- skipping code signing.

  The resulting bundle is unsigned. That is the expected outcome for anyone
  rebuilding this repo: signing needs an Apple Developer account and is only
  used for published releases. An unsigned local build runs normally, because
  files you built yourself carry no quarantine attribute. An unsigned build
  that has been *downloaded* needs the quarantine flag cleared:

    xattr -cr /Applications/Blender.app
EOF
  exit 0
fi

if [[ ! -d "$APP" ]]; then
  echo "error: no app bundle at $APP" >&2
  exit 1
fi
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "error: entitlements not found: $ENTITLEMENTS" >&2
  echo "Point ENTITLEMENTS at Blender's release/darwin/entitlements.plist." >&2
  exit 1
fi

# macOS ships bash 3.2, where expanding an empty array under `set -u` is an
# "unbound variable" error rather than nothing. The ${arr[@]+"${arr[@]}"} guard
# expands to nothing when unset and to the elements otherwise, on both 3.2 and
# modern bash.
KEYCHAIN_ARGS=()
[[ -n "$KEYCHAIN" ]] && KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")

echo "=== signing $APP ==="
echo "identity:     $CODESIGN_IDENTITY"
echo "entitlements: $ENTITLEMENTS"

sign() {
  local target="$1"
  shift
  # macOS ships bash 3.2, where "${arr[@]}" on an empty array is an "unbound
  # variable" error under `set -u`. The ${arr[@]+...} guard expands to nothing
  # when empty and to the elements otherwise, on both 3.2 and modern bash.
  codesign --force --timestamp --options runtime \
    --sign "$CODESIGN_IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "$@" "$target"
}

# 0. Drop Python bytecode caches before sealing.
#
# Blender's bundled Python writes __pycache__/*.pyc next to its sources on
# import. Any .pyc created after signing is a file the signature does not
# cover, and codesign then reports:
#
#   a sealed resource is missing or invalid
#
# So remove them first, and never run the app between signing and packaging.
# The interpreter regenerates them at runtime; a user-writable copy is not
# needed inside a read-only bundle.
echo "--- removing Python bytecode caches ---"
pyc_dirs=$(find "$APP" -name "__pycache__" -type d | wc -l | tr -d ' ')
find "$APP" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
echo "removed $pyc_dirs __pycache__ directories"

# 1. Every nested Mach-O, deepest path first. Symlinks are skipped -- signing
#    through one would sign the target twice under a different path.
echo "--- signing nested binaries ---"
count=0
while IFS= read -r -d '' f; do
  [[ -L "$f" ]] && continue
  file -b "$f" 2>/dev/null | grep -q "Mach-O" || continue
  sign "$f"
  count=$((count + 1))
done < <(
  find "$APP" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) -print0 \
    | tr '\0' '\n' | awk '{print gsub(/\//,"/")" "$0}' | sort -rn | cut -d' ' -f2- | tr '\n' '\0'
)
echo "signed $count nested binaries"

# 2. The thumbnailer extension, which needs its own sandbox entitlements.
APPEX="$APP/Contents/PlugIns/blender-thumbnailer.appex"
if [[ -d "$APPEX" ]]; then
  echo "--- signing thumbnailer extension ---"
  if [[ -f "$APPEX_ENTITLEMENTS" ]]; then
    sign "$APPEX" --entitlements "$APPEX_ENTITLEMENTS"
  else
    sign "$APPEX"
  fi
fi

# 3. The app itself, last.
echo "--- signing app bundle ---"
sign "$APP" --entitlements "$ENTITLEMENTS"

echo "--- verifying ---"
codesign --verify --deep --strict --verbose=2 "$APP"
echo
echo "signed. Gatekeeper assessment (expect 'rejected' until notarized):"
spctl --assess --type execute --verbose=2 "$APP" 2>&1 || true
