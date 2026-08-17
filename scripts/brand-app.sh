#!/usr/bin/env bash
# Rewrite a built Blender.app's identity so it does not present itself as an
# official Blender Foundation build.
#
# Blender hardcodes CFBundleIdentifier = org.blenderfoundation.blender in
# release/darwin/Blender.app/Contents/Info.plist, and platform_apple.cmake
# repeats it for the Xcode generator. There is no CMake option to override it,
# so this is done here rather than as a patch -- keeping it in packaging means
# the patch series stays about making x86_64 build at all, and identity stays a
# choice of whoever is distributing.
#
# Why it matters beyond politeness: an unofficial build sharing the official
# bundle identifier collides with an official install in Launch Services, and
# a signed one asserts that provenance under someone else's Developer ID.
#
# Everything is defaulted to something neutral. Nobody rebuilding this repo
# inherits the identity of whoever else has published it.
#
#   BUNDLE_ID       reverse-DNS identifier      (default: generic, unofficial)
#   BUNDLE_VENDOR   shown in Get Info           (default: none -- stays generic)
#
# This must run BEFORE codesigning: the signature seals Info.plist.

set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP="${APP:-$ROOT/build-x64/bin/Blender.app}"

# Deliberately not derived from any publisher's name or GitHub handle.
BUNDLE_ID="${BUNDLE_ID:-org.unofficial.blender-intel-x64}"
BUNDLE_VENDOR="${BUNDLE_VENDOR:-}"

if [[ ! -d "$APP" ]]; then
  echo "error: no app bundle at $APP" >&2
  exit 1
fi

PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || echo unknown)"

if [[ -n "$BUNDLE_VENDOR" ]]; then
  INFO_STRING="$VERSION - unofficial x86_64 build by $BUNDLE_VENDOR, not affiliated with or endorsed by the Blender Foundation"
else
  INFO_STRING="$VERSION - unofficial x86_64 build, not affiliated with or endorsed by the Blender Foundation"
fi

echo "=== rebranding $APP ==="
echo "bundle id: $BUNDLE_ID"
echo "get info:  $INFO_STRING"

set_key() {
  local key="$1" value="$2" plist="$3"
  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist"
  else
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
  fi
}

set_key "CFBundleIdentifier" "$BUNDLE_ID" "$PLIST"
set_key "CFBundleGetInfoString" "$INFO_STRING" "$PLIST"

# The thumbnailer extension must sit underneath the host app's identifier or
# macOS refuses to load it.
APPEX="$APP/Contents/PlugIns/blender-thumbnailer.appex"
if [[ -d "$APPEX" ]]; then
  set_key "CFBundleIdentifier" "${BUNDLE_ID}.thumbnailer" "$APPEX/Contents/Info.plist"
  echo "appex id:  ${BUNDLE_ID}.thumbnailer"
fi

# The exported .blend UTI is owned by the Blender Foundation's identifier.
# Leaving it claimed by an unofficial build would let it outrank a real install
# as the system handler for .blend files.
if /usr/libexec/PlistBuddy -c "Print :UTExportedTypeDeclarations" "$PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Delete :UTExportedTypeDeclarations" "$PLIST"
  echo "removed exported .blend UTI claim (left to official builds)"
fi

echo "done."
