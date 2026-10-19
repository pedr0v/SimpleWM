#!/usr/bin/env bash
# Interactive. Uploads the release secrets to the GitHub repo.
# Run it yourself. It asks for your Keychain password and your Apple
# app-specific password. Nothing is printed or stored on disk afterwards.
#
# Usage: scripts/setup-release-secrets.sh [owner/repo]
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
IDENTITY="$(security find-identity -v -p codesigning \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity in the keychain." >&2; exit 1; }
TEAM_ID="$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')"
echo "Repo:     $REPO"
echo "Identity: $IDENTITY"
echo "Team ID:  $TEAM_ID"
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
P12="$TMP/cert.p12"

read -r -s -p "Choose a password for the exported .p12 (stored as a GitHub secret): " P12_PASS; echo
echo "Exporting the certificate and private key. Keychain Access asks for your login password."
security export -t identities -f pkcs12 -P "$P12_PASS" -o "$P12" \
  -k "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
  || { echo "Export failed. Export '$IDENTITY' from Keychain Access as .p12 and rerun with P12_FILE=path." >&2; exit 1; }

read -r -p "Apple ID email for notarization: " APPLE_ID
read -r -s -p "App-specific password (from account.apple.com > Sign-In and Security): " APP_PASS; echo

gh secret set MACOS_CERTIFICATE_P12 --repo "$REPO" --body "$(base64 < "$P12")"
gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$REPO" --body "$P12_PASS"
gh secret set APPLE_ID --repo "$REPO" --body "$APPLE_ID"
gh secret set APPLE_TEAM_ID --repo "$REPO" --body "$TEAM_ID"
gh secret set APPLE_APP_PASSWORD --repo "$REPO" --body "$APP_PASS"
echo
echo "Done. Secrets set on $REPO:"
gh secret list --repo "$REPO"
