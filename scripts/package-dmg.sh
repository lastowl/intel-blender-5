#!/usr/bin/env bash
# Wrap a built Blender.app into a distributable .dmg.
#
# Deliberately minimal: a compressed image containing the app and an
# /Applications symlink to drag it onto. Blender's own release tooling adds a
# styled background and window layout, but that lives in the buildbot repo,
# not the source tree.
#
# Signing is optional and off by default. If CODESIGN_IDENTITY is set the image
# is signed once created; otherwise the result is unsigned, which is the normal
# outcome for a rebuild. An unsigned image that has been downloaded needs the
# quarantine attribute cleared before it will open:
#
#   xattr -cr /Applications/Blender.app
#
# Sign the *app* first (scripts/sign-app.sh) -- signing only the image leaves
# the bundle inside it unsigned.

set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP="${APP:-$ROOT/build-x64/bin/Blender.app}"
OUT_DIR="${OUT_DIR:-$ROOT}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
KEYCHAIN="${KEYCHAIN:-}"

# Named so a mounted volume is not mistaken for an official release.
VOLUME_NAME="${VOLUME_NAME:-Blender (unofficial x86_64)}"

if [[ ! -d "$APP" ]]; then
  echo "error: no app bundle at $APP" >&2
  exit 1
fi

ARCH="$(lipo -archs "$APP/Contents/MacOS/Blender" | tr -d ' ')"

# Read the version from Info.plist rather than running the binary.
#
# Executing Blender makes its bundled Python write __pycache__/*.pyc inside the
# bundle. On a signed app those files are not covered by the signature, and
# codesign then fails with "a sealed resource is missing or invalid" -- so
# merely asking a signed bundle for its version used to break it.
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
: "${VERSION:=unknown}"

# If the bundle is signed, it must still verify before it is worth packaging.
# Failing here is far better than shipping an image whose app is rejected on
# the user's machine.
if codesign -dv "$APP" >/dev/null 2>&1; then
  echo "app is signed; verifying before packaging..."
  if ! codesign --verify --deep --strict "$APP" 2>&1; then
    echo "error: $APP is signed but fails verification." >&2
    echo "Something modified the bundle after signing (commonly __pycache__" >&2
    echo "written by running the app). Re-run scripts/sign-app.sh." >&2
    exit 1
  fi
  echo "signature OK"
fi

DMG="$OUT_DIR/blender-${VERSION}-macos-${ARCH}-unofficial.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "app:     $APP"
echo "version: $VERSION"
echo "arch:    $ARCH"
echo "output:  $DMG"

# ditto, not cp -R: cp does not reliably carry the extended attributes a code
# signature depends on, so a signed bundle can arrive in the image broken.
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "$VOLUME_NAME $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG"

if [[ -n "$CODESIGN_IDENTITY" ]]; then
  echo
  echo "=== signing image ==="
  # ${arr[@]+...} guard: bash 3.2 (which macOS ships) errors on an empty array
  # expansion under `set -u`.
  KEYCHAIN_ARGS=()
  [[ -n "$KEYCHAIN" ]] && KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" \
    ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "$DMG"
  codesign --verify --verbose=2 "$DMG"
else
  echo
  echo "note: CODESIGN_IDENTITY unset -- image left unsigned (normal for a rebuild)."
fi

echo
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
