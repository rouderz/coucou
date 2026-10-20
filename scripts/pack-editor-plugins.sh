#!/usr/bin/env bash
# Packs Lumo's editor plugins into dist/:
#   lumo.aseprite-extension  double-click it (or Edit → Preferences → Extensions → Add Extension)
#   lumo-godot.zip           unzip at your Godot project's root, then enable Lumo in Project Settings → Plugins
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
rm -f dist/lumo.aseprite-extension dist/lumo-godot.zip

(cd extensions/aseprite && zip -q -X ../../dist/lumo.aseprite-extension package.json lumo.lua lumo.aseprite-keys)
(cd extensions/godot && zip -q -X -r ../../dist/lumo-godot.zip addons/lumo -x '*.import' -x '*.uid')

echo "dist/lumo.aseprite-extension"
echo "dist/lumo-godot.zip"
