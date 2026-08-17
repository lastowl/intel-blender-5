#!/usr/bin/env bash
# Submit a signed .dmg to Apple for notarization and staple the ticket.
#
# OPTIONAL AND OFF BY DEFAULT, like signing. With no credentials configured
# this prints why and exits 0.
#
# Credentials, in order of preference:
#
#   NOTARY_PROFILE     a profile stored by `xcrun notarytool store-credentials`
#                      (best for a local machine -- nothing lands in the repo)
#
#   APPLE_API_KEY_P8 + APPLE_API_KEY_ID + APPLE_API_ISSUER
#                      App Store Connect API key. Best for CI: it is scoped,
#                      revocable, and needs no Apple ID password. The .p8 is
#                      passed as a path.
#
#   APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD
#                      app-specific password fallback.
#
# Notarization only proves Apple scanned it; the ticket still has to be
# stapled, or an offline first launch re-checks online and fails.

set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DMG="${DMG:-}"

if [[ -z "$DMG" ]]; then
  DMG="$(find "$ROOT" -maxdepth 1 -name "*.dmg" -print -quit)"
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APPLE_API_KEY_P8="${APPLE_API_KEY_P8:-}"
APPLE_API_KEY_ID="${APPLE_API_KEY_ID:-}"
APPLE_API_ISSUER="${APPLE_API_ISSUER:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_PASSWORD="${APPLE_APP_PASSWORD:-}"

AUTH=()
if [[ -n "$NOTARY_PROFILE" ]]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "$APPLE_API_KEY_P8" && -n "$APPLE_API_KEY_ID" && -n "$APPLE_API_ISSUER" ]]; then
  AUTH=(--key "$APPLE_API_KEY_P8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
elif [[ -n "$APPLE_ID" && -n "$APPLE_TEAM_ID" && -n "$APPLE_APP_PASSWORD" ]]; then
  AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
else
  cat <<'EOF'
note: no notarization credentials configured -- skipping.

  The .dmg is still valid; it is simply not notarized. If it was also not
  signed, that is the normal outcome for a rebuild and nothing is wrong.

  A signed-but-not-notarized .dmg will still be blocked by Gatekeeper when
  downloaded, so for published releases set one of:

    NOTARY_PROFILE
    APPLE_API_KEY_P8 + APPLE_API_KEY_ID + APPLE_API_ISSUER
    APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD
EOF
  exit 0
fi

if [[ ! -f "$DMG" ]]; then
  echo "error: no .dmg found (set DMG=/path/to.dmg)" >&2
  exit 1
fi

# Notarizing an unsigned image always fails, with a worse error than this one.
if ! codesign -dv "$DMG" >/dev/null 2>&1; then
  echo "error: $DMG is not signed; notarization would be rejected." >&2
  echo "Run scripts/sign-app.sh with CODESIGN_IDENTITY set before packaging." >&2
  exit 1
fi

echo "=== notarizing $DMG ==="
xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait

echo "=== stapling ==="
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "Gatekeeper assessment:"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 || true
