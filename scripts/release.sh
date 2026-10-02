#!/usr/bin/env bash
# Publishes a new version of Coucou on rouderz/coucou.
#
#   bash scripts/release.sh 0.2.0
#
# Sets the version in project.yml, commits it on main, tags v0.2.0 and pushes. GitHub Actions
# (.github/workflows/release.yml) then builds the DMG and attaches it to the release; Coucou's
# update check picks it up. To build a DMG locally instead: bash scripts/make-dmg.sh 0.2.0
set -euo pipefail

VERSION="${1:?Usage: $0 <version>   e.g. $0 0.2.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ "$(git branch --show-current)" = "main" ] || { echo "✗ Run it on main (git checkout main && git pull)"; exit 1; }
[ -z "$(git status --porcelain -- NotchBuddy)" ] || { echo "✗ Commit or stash your NotchBuddy changes first"; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "✗ v$VERSION already exists"; exit 1; }

# Version shown in the app (macOS target only)
python3 - "$VERSION" <<'PY'
import re, sys
v = sys.argv[1]
p = "NotchBuddy/project.yml"
s = open(p).read()
s = re.sub(r'(CFBundleShortVersionString: )"[^"]*"', rf'\g<1>"{v}"', s, count=1)
open(p, "w").write(s)
PY

git add NotchBuddy/project.yml
git diff --cached --quiet || git commit -m "Release $VERSION"
git tag -a "v$VERSION" -m "Coucou $VERSION"
git push origin main "v$VERSION"

echo "✓ v$VERSION pushed. The DMG appears in a few minutes at:"
echo "  https://github.com/rouderz/coucou/releases/tag/v$VERSION"
