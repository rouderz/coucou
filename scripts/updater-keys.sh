#!/usr/bin/env bash
# One-time setup of the self-update signing keys. Run it once, on your Mac, from the repo:
#
#   bash scripts/updater-keys.sh
#
# It makes two key pairs, keeps the private halves in ~/.coucou-keys (back that folder up:
# lose it and future updates can't be signed for the copies already out there), puts them in
# the repo's GitHub secrets, and writes the public halves into the code:
#   - macOS:          Ed25519 (CryptoKit)  → MAC_UPDATE_KEY        → NotchBuddy/Sources/App/UpdateKey.swift
#   - Windows/Linux:  Tauri's updater key  → TAURI_SIGNING_PRIVATE_KEY → windows/src-tauri/tauri.conf.json
# Then commit the two changed files; releases from then on update themselves.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
KEYS="$HOME/.coucou-keys"
REPO="rouderz/coucou"
mkdir -p "$KEYS" && chmod 700 "$KEYS"

command -v gh >/dev/null || { echo "✗ GitHub CLI needed (brew install gh && gh auth login)"; exit 1; }
command -v swift >/dev/null || { echo "✗ Swift needed (Xcode or its command line tools)"; exit 1; }
command -v npx >/dev/null || { echo "✗ Node needed (brew install node)"; exit 1; }

# ── macOS ────────────────────────────────────────────────────────────────────
if [ ! -f "$KEYS/mac-update.key" ]; then
  out=$(swift scripts/update-signature.swift generate)
  echo "$out" | awk '/^PRIVATE /{print $2}' > "$KEYS/mac-update.key"
  echo "$out" | awk '/^PUBLIC /{print $2}' > "$KEYS/mac-update.pub"
  chmod 600 "$KEYS/mac-update.key"
  echo "▸ New macOS update key in $KEYS"
fi
MAC_PUB=$(cat "$KEYS/mac-update.pub")
python3 - "$MAC_PUB" <<'PY'
import re, sys
p = "NotchBuddy/Sources/App/UpdateKey.swift"
s = open(p).read()
s = re.sub(r'static let macPublicKey = "[^"]*"', f'static let macPublicKey = "{sys.argv[1]}"', s)
open(p, "w").write(s)
PY
gh secret set MAC_UPDATE_KEY --repo "$REPO" < "$KEYS/mac-update.key"

# ── Windows / Linux (Tauri) ──────────────────────────────────────────────────
if [ ! -f "$KEYS/tauri-update.key" ]; then
  (cd windows && npx --yes @tauri-apps/cli signer generate --ci -p "" -w "$KEYS/tauri-update.key")
  chmod 600 "$KEYS/tauri-update.key"
  echo "▸ New Windows/Linux update key in $KEYS"
fi
python3 - "$KEYS/tauri-update.key.pub" <<'PY'
import json, sys
pub = open(sys.argv[1]).read().strip()
p = "windows/src-tauri/tauri.conf.json"
d = json.load(open(p))
d.setdefault("plugins", {}).setdefault("updater", {})["pubkey"] = pub
open(p, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
gh secret set TAURI_SIGNING_PRIVATE_KEY --repo "$REPO" < "$KEYS/tauri-update.key"
# The key has no password: TAURI_SIGNING_PRIVATE_KEY_PASSWORD stays unset (gh refuses empty secrets).

echo
echo "✓ Keys in GitHub secrets; public keys written to:"
echo "    NotchBuddy/Sources/App/UpdateKey.swift"
echo "    windows/src-tauri/tauri.conf.json"
echo "  Commit them (a PR is fine). Back up $KEYS somewhere safe."
