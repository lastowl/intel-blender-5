#!/usr/bin/env bash
# Wrap a built Blender.app into a distributable .dmg.
#
# Deliberately minimal: a compressed image containing the app and an
# /Applications symlink to drag it onto. Blender's own release tooling adds a
# styled background and window layout, but that lives in the buildbot repo,
# not the source tree.
#
# The result is unsigned. macOS Gatekeeper will refuse to open it until the
# quarantine attribute is cleared:
#
#   xattr -cr /Applications/Blender.app

set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP="${APP:-$ROOT/build-x64/bin/Blender.app}"
OUT_DIR="${OUT_DIR:-$ROOT}"
VOLUME_NAME="${VOLUME_NAME:-Blender}"

if [[ ! -d "$APP" ]]; then
  echo "error: no app bundle at $APP" >&2
  exit 1
fi

ARCH="$(lipo -archs "$APP/Contents/MacOS/Blender" | tr -d ' ')"
VERSION="$("$APP/Contents/MacOS/Blender" --version 2>/dev/null | head -1 | awk '{print $2}')"
: "${VERSION:=unknown}"

DMG="$OUT_DIR/blender-${VERSION}-macos-${ARCH}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "app:     $APP"
echo "version: $VERSION"
echo "arch:    $ARCH"
echo "output:  $DMG"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "$VOLUME_NAME $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG"

echo
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
