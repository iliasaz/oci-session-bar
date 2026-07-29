#!/usr/bin/env bash
#
# setup-release-secrets.sh
#
# Populate the GitHub Actions secrets required by .github/workflows/release.yml.
# Run this once, after creating a Developer ID Application certificate and an App
# Store Connect API key with notarization permission.
#
# GitHub secrets are per-repo, so this sets them for this repo. Point the paths
# below at your local Apple signing material (a directory holding):
#   developer_id_application.p12   → DEVELOPER_ID_APPLICATION_CERT_BASE64/_PASSWORD
#   AuthKey_XXXXXXXXXX.p8          → APP_STORE_CONNECT_API_KEY/_KEY_ID
#
# Unlike a CLI release there is no Developer ID *Installer* certificate here: this
# project ships a signed, notarized, stapled .app inside a signed, notarized,
# stapled .dmg. Only the Application certificate is involved.
#
# Usage:
#   scripts/setup-release-secrets.sh [--repo iliasaz/oci-session-bar] \
#       [--p12 /path/to/developer_id_application.p12] \
#       [--p8  /path/to/AuthKey_XXXXXXXXXX.p8]
#
# Any path not provided is prompted for. Passwords and IDs are always prompted
# (never accepted as flags) so they do not leak into shell history or `ps`.

set -euo pipefail

REPO="iliasaz/oci-session-bar"
P12_PATH=""
P8_PATH=""
DEFAULT_TEAM_ID="6CGNH3LTV7"
DEFAULT_CERTS_DIR="$HOME/Documents/macintora-dev-certs"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --p12)  P12_PATH="$2"; shift 2 ;;
    --p8)   P8_PATH="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,25p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Default the cert paths to the shared certs dir if present and not overridden.
[[ -z "$P12_PATH" && -f "$DEFAULT_CERTS_DIR/developer_id_application.p12" ]] \
  && P12_PATH="$DEFAULT_CERTS_DIR/developer_id_application.p12"
[[ -z "$P8_PATH" ]] && P8_PATH="$(ls "$DEFAULT_CERTS_DIR"/AuthKey_*.p8 2>/dev/null | head -1 || true)"

command -v gh >/dev/null || { echo "gh CLI not found. Install from https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated. Run: gh auth login" >&2; exit 1; }

echo "Target repo: $REPO"
echo

prompt_path() {
  local label="$1" current="$2"
  if [[ -n "$current" ]]; then echo "$current"; return; fi
  local p
  read -r -p "Path to $label: " p
  printf '%s' "$p"
}

prompt_secret() {
  local label="$1" val
  read -r -s -p "$label: " val
  echo >&2
  printf '%s' "$val"
}

prompt_default() {
  local label="$1" default="$2" val
  read -r -p "$label [$default]: " val
  printf '%s' "${val:-$default}"
}

set_secret_from_stdin() {
  local name="$1"
  gh secret set "$name" --repo "$REPO"
}

# Verify a .p12 opens with the given password before uploading anything.
# OpenSSL 3.x disabled RC2-40-CBC (the cipher Apple's Keychain uses for .p12
# exports) by default, so retry with -legacy if the first attempt fails.
verify_p12() {
  local path="$1" pass="$2"
  openssl pkcs12 -in "$path" -nokeys -passin "pass:$pass" >/dev/null 2>&1 \
    || openssl pkcs12 -in "$path" -nokeys -passin "pass:$pass" -legacy >/dev/null 2>&1
}

# ----- Developer ID Application cert -----
P12_PATH="$(prompt_path "Developer ID Application .p12" "$P12_PATH")"
[[ -f "$P12_PATH" ]] || { echo ".p12 not found at: $P12_PATH" >&2; exit 1; }

P12_PASSWORD="$(prompt_secret "Password for $P12_PATH")"
if ! verify_p12 "$P12_PATH" "$P12_PASSWORD"; then
  echo "openssl could not open the .p12 with that password. Aborting." >&2
  exit 1
fi

echo "Uploading DEVELOPER_ID_APPLICATION_CERT_BASE64…"
base64 -i "$P12_PATH" | set_secret_from_stdin DEVELOPER_ID_APPLICATION_CERT_BASE64

echo "Uploading DEVELOPER_ID_APPLICATION_CERT_PASSWORD…"
printf '%s' "$P12_PASSWORD" | set_secret_from_stdin DEVELOPER_ID_APPLICATION_CERT_PASSWORD
unset P12_PASSWORD

# ----- App Store Connect API key -----
P8_PATH="$(prompt_path "App Store Connect .p8 private key" "$P8_PATH")"
[[ -f "$P8_PATH" ]] || { echo ".p8 not found at: $P8_PATH" >&2; exit 1; }

# Infer the key ID from the filename (AuthKey_XXXXXXXXXX.p8) and let the user confirm.
INFERRED_KEY_ID="$(basename "$P8_PATH" | sed -nE 's/^AuthKey_([A-Z0-9]+)\.p8$/\1/p')"
if [[ -n "$INFERRED_KEY_ID" ]]; then
  ASC_KEY_ID="$(prompt_default "App Store Connect API Key ID" "$INFERRED_KEY_ID")"
else
  read -r -p "App Store Connect API Key ID: " ASC_KEY_ID
fi

read -r -p "App Store Connect Issuer ID (UUID): " ASC_ISSUER_ID
[[ "$ASC_ISSUER_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "Issuer ID does not look like a UUID." >&2; exit 1; }

TEAM_ID="$(prompt_default "Apple Team ID" "$DEFAULT_TEAM_ID")"

echo "Uploading APP_STORE_CONNECT_API_KEY (.p8 contents)…"
set_secret_from_stdin APP_STORE_CONNECT_API_KEY < "$P8_PATH"

echo "Uploading APP_STORE_CONNECT_API_KEY_ID…"
printf '%s' "$ASC_KEY_ID" | set_secret_from_stdin APP_STORE_CONNECT_API_KEY_ID

echo "Uploading APP_STORE_CONNECT_ISSUER_ID…"
printf '%s' "$ASC_ISSUER_ID" | set_secret_from_stdin APP_STORE_CONNECT_ISSUER_ID

echo "Uploading APPLE_TEAM_ID…"
printf '%s' "$TEAM_ID" | set_secret_from_stdin APPLE_TEAM_ID

echo
echo "Six secrets set on $REPO. Verify with:"
echo "  gh secret list --repo $REPO"
