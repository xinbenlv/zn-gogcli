#!/usr/bin/env bash
# scripts/codesign-macos-local.sh
#
# Local-build code signing for `gog` on macOS.
#
# Why this exists
#   When `gog` reads/writes a token in the user's macOS Keychain (via the
#   keyring backend), securityd evaluates the requesting binary against each
#   keychain item's ACL. If `gog` is unsigned (or only ad-hoc signed via
#   `go build`'s default linker-signed mode), securityd cannot anchor a
#   stable trust decision — every invocation re-prompts the user even after
#   "Always Allow" is clicked.
#
#   Giving every local build a STABLE designated requirement (via a real
#   signing identity, even a self-signed one) lets the keychain ACL store
#   a persistent trust binding. The first prompt sticks across rebuilds.
#
# Two modes
#   1) Identity provided: if GOG_CODESIGN_IDENTITY (or CODESIGN_IDENTITY) is
#      set, sign with that identity. This is the same env var the existing
#      `scripts/codesign-macos.sh` uses for the goreleaser release flow, so
#      a developer with a real Apple Developer ID set up will get the same
#      signing for both local and release builds.
#
#   2) Auto self-signed fallback: if no identity is provided, bootstrap (on
#      first run) and use a self-signed identity stored in a dedicated
#      keychain at ~/Library/Keychains/gog-codesign.keychain-db. The cert
#      is added to the user's keychain search list with codesign access.
#
# No-ops on non-Darwin. Skip with GOG_SKIP_LOCAL_CODESIGN=1.
#
# Usage: scripts/codesign-macos-local.sh <path-to-binary>

set -euo pipefail

BIN="${1:-}"
if [[ -z "$BIN" ]]; then
  echo "usage: $0 <path-to-binary>" >&2
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  exit 0
fi

if [[ -n "${GOG_SKIP_LOCAL_CODESIGN:-}" ]]; then
  echo "codesign-local: skipped (GOG_SKIP_LOCAL_CODESIGN set)" >&2
  exit 0
fi

if ! [[ -f "$BIN" ]]; then
  echo "codesign-local: binary not found: $BIN" >&2
  exit 1
fi

BUNDLE_ID="com.openclaw.gogcli.gog"

# Mode 1: real signing identity (Developer ID, etc.) provided.
IDENTITY="${GOG_CODESIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp --options runtime \
    --identifier "$BUNDLE_ID" "$BIN"
  codesign --verify --strict --verbose=2 "$BIN" >/dev/null
  echo "codesign-local: signed with identity '$IDENTITY'" >&2
  exit 0
fi

# Mode 2: auto-self-signed identity in dedicated keychain.
LOCAL_KEYCHAIN="$HOME/Library/Keychains/gog-codesign.keychain-db"
LOCAL_IDENTITY_NAME="gog-codesign-local-$(hostname -s)"
LOCAL_PASS_FILE="$HOME/.gog-codesign-keychain-pass"

# Bootstrap if keychain or identity is missing.
need_bootstrap=0
if [[ ! -f "$LOCAL_KEYCHAIN" ]]; then
  need_bootstrap=1
elif ! security find-identity -v "$LOCAL_KEYCHAIN" 2>/dev/null | grep -q "$LOCAL_IDENTITY_NAME"; then
  need_bootstrap=1
fi

if [[ "$need_bootstrap" == "1" ]]; then
  echo "codesign-local: bootstrapping self-signed identity '$LOCAL_IDENTITY_NAME'..." >&2
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$script_dir/codesign-macos-bootstrap.sh"
fi

# Unlock dedicated keychain (idempotent).
if [[ -f "$LOCAL_PASS_FILE" ]]; then
  KEYCHAIN_PASS="$(cat "$LOCAL_PASS_FILE")"
  security unlock-keychain -p "$KEYCHAIN_PASS" "$LOCAL_KEYCHAIN" >/dev/null 2>&1 || true
fi

codesign --force --sign "$LOCAL_IDENTITY_NAME" \
  --identifier "$BUNDLE_ID" \
  --keychain "$LOCAL_KEYCHAIN" \
  "$BIN"

codesign --verify --strict --verbose=2 "$BIN" >/dev/null
echo "codesign-local: signed with self-signed identity '$LOCAL_IDENTITY_NAME'" >&2
