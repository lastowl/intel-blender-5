#!/usr/bin/env bash
# Configure the GitHub secrets that turn on signed, notarized CI releases.
#
# Nothing in this repository needs these. They are opt-in: with the secrets
# absent, CI still produces a working unsigned .dmg, which is the expected
# outcome for anyone who forks this. Only whoever publishes releases runs this.
#
#   ./scripts/setup-signing-secrets.sh --check
#   ./scripts/setup-signing-secrets.sh <developer-id.p12> [asc-key.p8]
#
# The .p12 must be exported by hand -- a private key cannot be pulled out of the
# keychain non-interactively, and it should not be. In Keychain Access:
#
#   1. Select "Developer ID Application: <your org>" under My Certificates
#   2. Expand it and select BOTH the certificate and its private key
#   3. Right click -> Export 2 items... -> Personal Information Exchange (.p12)
#   4. Set an export password; you will be asked for it below
#
# The optional second argument is an App Store Connect API key (.p8) for
# notarization. It is preferred over an Apple ID and app-specific password:
# it is scoped, revocable, and no account password ever reaches the runner.
# Create one at App Store Connect -> Users and Access -> Integrations -> Keys.
#
# Secrets are piped to `gh` on stdin rather than passed as arguments, because
# arguments are visible in the process list to any other user on the machine.

set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO="${REPO:-}"

if [[ -z "$REPO" ]]; then
  REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null |
    sed -E 's#^git@github\.com:##; s#^https://([^@/]+@)?github\.com/##; s#\.git$##')"
fi

die() { echo "error: $*" >&2; exit 1; }

# Anything sensitive lands here and is shredded on exit, including on failure.
WORK=""
cleanup() {
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    find "$WORK" -type f -exec rm -f {} + 2>/dev/null || true
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
command -v gh >/dev/null || die "the gh CLI is required"
command -v openssl >/dev/null || die "openssl is required"
[[ -n "$REPO" ]] || die "could not determine the repository; set REPO=owner/name"

gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"

echo "repository: $REPO"
echo

if [[ "${1:-}" == "--check" ]]; then
  echo "=== currently configured ==="
  echo "--- secrets ---"
  gh secret list --repo "$REPO" 2>/dev/null || echo "  (none, or no access)"
  echo "--- variables ---"
  gh variable list --repo "$REPO" 2>/dev/null || echo "  (none)"
  echo
  echo "--- local signing identities available for export ---"
  security find-identity -v -p codesigning 2>/dev/null | grep -i "developer id application" ||
    echo "  no Developer ID Application identity found in the keychain"
  exit 0
fi

P12="${1:-}"
P8="${2:-}"
[[ -n "$P12" ]] || die "usage: $(basename "$0") [--check] <developer-id.p12> [asc-key.p8]"
[[ -f "$P12" ]] || die "no such file: $P12"

WORK="$(mktemp -d)"
chmod 700 "$WORK"

# --------------------------------------------------------------------------
# Certificate: validate, then derive the identity string from the cert itself
# so it cannot be mistyped.
# --------------------------------------------------------------------------
printf 'Password for %s: ' "$(basename "$P12")" >&2
read -r -s P12_PASS
echo >&2

if ! openssl pkcs12 -in "$P12" -nokeys -passin pass:"$P12_PASS" \
     -legacy -out "$WORK/cert.pem" 2>/dev/null &&
   ! openssl pkcs12 -in "$P12" -nokeys -passin pass:"$P12_PASS" \
     -out "$WORK/cert.pem" 2>/dev/null; then
  die "could not open the .p12 -- wrong password, or not a PKCS#12 file"
fi

IDENTITY="$(openssl x509 -in "$WORK/cert.pem" -noout -subject 2>/dev/null |
  sed -n 's/.*CN[ ]*=[ ]*\([^,/]*\).*/\1/p' | head -1 | sed 's/[[:space:]]*$//')"
[[ -n "$IDENTITY" ]] || die "could not read the certificate common name"

case "$IDENTITY" in
  "Developer ID Application:"*) ;;
  *) echo "warning: '$IDENTITY' is not a Developer ID Application certificate." >&2
     echo "         Distribution outside the App Store needs that type." >&2 ;;
esac

# Warn early rather than after a 40-minute CI run.
NOT_AFTER="$(openssl x509 -in "$WORK/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)"
if ! openssl x509 -in "$WORK/cert.pem" -noout -checkend 0 >/dev/null 2>&1; then
  die "this certificate has EXPIRED ($NOT_AFTER)"
fi

echo "identity: $IDENTITY"
echo "expires:  $NOT_AFTER"
echo

# --------------------------------------------------------------------------
# Upload
# --------------------------------------------------------------------------
set_secret() {
  local name="$1" value="$2"
  printf '%s' "$value" | gh secret set "$name" --repo "$REPO"
  echo "  set $name"
}

echo "=== setting signing secrets ==="
set_secret MACOS_CERT_P12 "$(base64 < "$P12" | tr -d '\n')"
set_secret MACOS_CERT_PASSWORD "$P12_PASS"
set_secret MACOS_CODESIGN_IDENTITY "$IDENTITY"

if [[ -n "$P8" ]]; then
  [[ -f "$P8" ]] || die "no such file: $P8"
  echo
  echo "=== notarization (App Store Connect API key) ==="
  # Key ID is in the filename Apple gives you: AuthKey_XXXXXXXXXX.p8
  suggested="$(basename "$P8" | sed -n 's/^AuthKey_\(.*\)\.p8$/\1/p')"
  printf 'Key ID%s: ' "${suggested:+ [$suggested]}" >&2
  read -r KEY_ID
  KEY_ID="${KEY_ID:-$suggested}"
  [[ -n "$KEY_ID" ]] || die "a key ID is required"
  printf 'Issuer ID (UUID from App Store Connect): ' >&2
  read -r ISSUER
  [[ -n "$ISSUER" ]] || die "an issuer ID is required"

  set_secret APPLE_API_KEY_P8 "$(base64 < "$P8" | tr -d '\n')"
  set_secret APPLE_API_KEY_ID "$KEY_ID"
  set_secret APPLE_API_ISSUER "$ISSUER"
else
  echo
  echo "note: no App Store Connect key given, so builds will be signed but NOT"
  echo "      notarized. A signed-but-unnotarized .dmg is still blocked by"
  echo "      Gatekeeper when downloaded. Re-run with the .p8 to finish the job."
fi

echo
echo "=== configured ==="
gh secret list --repo "$REPO"

cat <<EOF

Done. The next workflow run will sign, because scripts/sign-app.sh switches on
MACOS_CODESIGN_IDENTITY being non-empty.

Optional, if you want to override the neutral defaults in brand-app.sh:

  gh variable set BUNDLE_ID     --repo $REPO --body "org.example.blender"
  gh variable set BUNDLE_VENDOR --repo $REPO --body "Your Org"

To revoke everything again:

  for s in MACOS_CERT_P12 MACOS_CERT_PASSWORD MACOS_CODESIGN_IDENTITY \\
           APPLE_API_KEY_P8 APPLE_API_KEY_ID APPLE_API_ISSUER; do
    gh secret delete "\$s" --repo $REPO
  done
EOF
