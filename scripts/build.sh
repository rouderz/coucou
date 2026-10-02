#!/usr/bin/env bash
# Builds Coucou for the system you run it on, into dist/:
#   macOS   → dist/Coucou-<version>-macOS.dmg           (scripts/make-dmg.sh)
#   Linux   → dist/Coucou-<version>-Linux-<arch>.deb / .rpm / .AppImage
#   Windows → dist/Coucou-<version>-Windows-setup.exe   (run it from Git Bash)
#
#   bash scripts/build.sh            the version in scripts/versions.sh
#
# The other systems are built by GitHub Actions on every push to main (artifacts)
# and on every v* tag (the release): .github/workflows/release.yml.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION=$(awk -F'"' '/CFBundleShortVersionString/ {print $2; exit}' NotchBuddy/project.yml)
mkdir -p dist

tauri_build() {
  command -v cargo >/dev/null || { echo "✗ Rust is needed: https://rustup.rs"; exit 1; }
  command -v npm >/dev/null || { echo "✗ Node 20+ is needed: https://nodejs.org"; exit 1; }
  (cd windows && npm ci && npx tauri build)
}

case "$(uname -s)" in
  Darwin)
    bash scripts/make-dmg.sh "$VERSION"
    mv -f "dist/Coucou-$VERSION.dmg" "dist/Coucou-$VERSION-macOS.dmg"
    echo "✓ dist/Coucou-$VERSION-macOS.dmg"
    ;;
  Linux)
    ARCH=$(uname -m); [ "$ARCH" = "aarch64" ] && ARCH=arm64
    tauri_build
    shopt -s nullglob
    for f in windows/target/release/bundle/deb/*.deb; do cp "$f" "dist/Coucou-$VERSION-Linux-$ARCH.deb"; done
    for f in windows/target/release/bundle/rpm/*.rpm; do cp "$f" "dist/Coucou-$VERSION-Linux-$ARCH.rpm"; done
    for f in windows/target/release/bundle/appimage/*.AppImage; do cp "$f" "dist/Coucou-$VERSION-Linux-$ARCH.AppImage"; done
    ls -1 dist/Coucou-"$VERSION"-Linux-* 2>/dev/null | sed 's/^/✓ /'
    ;;
  MINGW*|MSYS*|CYGWIN*)
    tauri_build
    cp windows/target/release/bundle/nsis/*-setup.exe "dist/Coucou-$VERSION-Windows-setup.exe"
    echo "✓ dist/Coucou-$VERSION-Windows-setup.exe"
    ;;
  *)
    echo "✗ Unknown system $(uname -s)"; exit 1 ;;
esac
