#!/usr/bin/env bash
# scripts/codesign-macos-bootstrap.sh
#
# One-time bootstrap of a self-signed code signing identity for local
# `gog` builds. Idempotent: safe to re-run.
#
# Output state:
#   ~/Library/Keychains/gog-codesign.keychain-db   — dedicated keychain
#   ~/.gog-codesign-keychain-pass                  — keychain unlock password (mode 600)
#   identity CN: gog-codesign-local-<hostname>
#   private key allowed for: /usr/bin/codesign, /usr/bin/security
#
# Why a dedicated keychain instead of the login keychain
#   `security import` into login.keychain-db over a non-GUI shell raises
#   "User interaction is not allowed" because there is no auth context
#   to prompt the user. A dedicated keychain that the script creates and
#   unlocks itself sidesteps this entirely.
#
# Why a self-signed cert is OK here
#   This identity is local-only and never used to distribute software.
#   Its purpose is purely to give `gog` a STABLE designated requirement
#   so the user's macOS Keychain ACL (for the gogcli token entries) can
#   anchor a persistent trust decision.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "codesign-bootstrap: not macOS, nothing to do" >&2
  exit 0
fi

CERT_NAME="gog-codesign-local-$(hostname -s)"
KEYCHAIN="$HOME/Library/Keychains/gog-codesign.keychain-db"
PASS_FILE="$HOME/.gog-codesign-keychain-pass"

# If keychain and identity already exist, we're done.
if [[ -f "$KEYCHAIN" ]] \
  && security find-identity -v "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "codesign-bootstrap: identity '$CERT_NAME' already present, skipping" >&2
  exit 0
fi

WORKDIR="$(mktemp -d -t gog-codesign-bootstrap)"
trap 'rm -rf "$WORKDIR"' EXIT

P12_PASS="$(openssl rand -hex 16)"
KEYCHAIN_PASS="$(openssl rand -hex 16)"

KEY="$WORKDIR/key.pem"
CSR_CONF="$WORKDIR/csr.cnf"
CERT="$WORKDIR/cert.pem"
P12="$WORKDIR/identity.p12"

cat > "$CSR_CONF" <<EOF
[ req ]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_ext

[ req_dn ]
CN = $CERT_NAME

[ v3_ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "codesign-bootstrap: generating RSA-2048 keypair" >&2
openssl genrsa -out "$KEY" 2048 2>/dev/null

echo "codesign-bootstrap: self-signing certificate (10 years)" >&2
openssl req -new -x509 -key "$KEY" -out "$CERT" -days 3650 -config "$CSR_CONF" 2>/dev/null

echo "codesign-bootstrap: bundling into legacy PKCS12 for security import" >&2
openssl pkcs12 -export -legacy -in "$CERT" -inkey "$KEY" \
  -out "$P12" -name "$CERT_NAME" \
  -passout "pass:$P12_PASS"

if [[ -f "$KEYCHAIN" ]]; then
  echo "codesign-bootstrap: removing pre-existing keychain for clean state" >&2
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
fi

echo "codesign-bootstrap: creating dedicated keychain" >&2
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"

echo "codesign-bootstrap: adding to user keychain search list" >&2
EXISTING_LIST="$(security list-keychains -d user \
  | sed 's/"//g' | tr -s ' ' '\n' | grep -v '^$' | grep -v "$KEYCHAIN" | tr '\n' ' ')"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN" $EXISTING_LIST

echo "codesign-bootstrap: importing identity" >&2
security import "$P12" \
  -k "$KEYCHAIN" \
  -P "$P12_PASS" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

echo "codesign-bootstrap: setting key partition list (allow codesign without prompts)" >&2
security set-key-partition-list \
  -S apple-tool:,apple:,codesign:,security: \
  -s -k "$KEYCHAIN_PASS" \
  "$KEYCHAIN"

echo "codesign-bootstrap: saving keychain unlock password to $PASS_FILE (mode 600)" >&2
printf '%s' "$KEYCHAIN_PASS" > "$PASS_FILE"
chmod 600 "$PASS_FILE"

echo "codesign-bootstrap: done. identity = '$CERT_NAME'" >&2
