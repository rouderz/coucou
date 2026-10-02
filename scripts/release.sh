#!/usr/bin/env bash
# Publishes a new version of Coucou on rouderz/coucou.
#
#   bash scripts/release.sh 0.2.0
#
# Sets the version for every platform (scripts/versions.sh), commits it on main, tags v0.2.0
# and pushes. GitHub Actions (.github/workflows/release.yml) then builds macOS, Windows and
# Linux and publishes them together as the release; Coucou for Mac's update check picks it up.
# To build on this machine instead: bash scripts/build.sh
set -euo pipefail

VERSION="${1:?Usage: $0 <version>   e.g. $0 0.2.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ "$(git branch --show-current)" = "main" ] || { echo "✗ Run it on main (git checkout main && git pull)"; exit 1; }
[ -z "$(git status --porcelain -- NotchBuddy windows)" ] || { echo "✗ Commit or stash your changes in NotchBuddy/ and windows/ first"; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "✗ v$VERSION already exists"; exit 1; }

# One version for every platform (macOS, Windows, Linux).
bash scripts/versions.sh set "$VERSION"

git add NotchBuddy/project.yml windows/package.json windows/package-lock.json \
        windows/src-tauri/tauri.conf.json windows/Cargo.toml
git diff --cached --quiet || git commit -m "Release $VERSION"
git tag -a "v$VERSION" -m "Coucou $VERSION"
git push origin main "v$VERSION"

echo "✓ v$VERSION pushed. macOS, Windows and Linux builds appear in ~20 minutes at:"
echo "  https://github.com/rouderz/coucou/releases/tag/v$VERSION"
