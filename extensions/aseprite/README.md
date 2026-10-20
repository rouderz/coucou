# Lumo for Aseprite

Ask [Lumo](https://github.com/rouderz/coucou) about your sprite. Your question goes with:

- an image of the frame you're on, or of the animation (the current tag's frames in a grid),
  scaled up by whole pixels so small art stays readable
- the canvas, color mode, frames and durations, tags, the layer tree (hidden, locked, opacity,
  blend), the active cel, the selection, the palette, the tool and colors

When the sprite lives inside a Godot project (or a git repo), Lumo's chat runs in that folder, so
it can look at the game around your art. Nothing leaves your computer: the extension talks to
Lumo over a local WebSocket (`127.0.0.1`) with a token only your user can read.

Made for the current stable Aseprite (1.3, tested against its 1.3.18 API).

## Use

- **Edit → Lumo → Ask Lumo About This**, **Ctrl+Alt+L** (**Cmd+Alt+L** on macOS), or right-click a
  cel → **Ask Lumo About This**: Lumo opens its chat with the sprite attached.
- While Lumo is open, the extension keeps it told about the sprite in front (no image), so Lumo's
  own shortcut and dropping your character on Aseprite use it too.
- **Edit → Lumo → Lumo Settings…**: attach the image or not, keep Lumo told or not.

The first time, Aseprite may ask whether the script can read Lumo's `editor-bridge.json` and write
the snapshot: allow it (or give the extension full trust).

## Install

Run `scripts/pack-editor-plugins.sh` from the repo, then double-click
`dist/lumo.aseprite-extension` (or **Edit → Preferences → Extensions → Add Extension**) and
restart Aseprite. Without the script, zip this folder's `package.json`, `lumo.lua` and
`lumo.aseprite-keys` and rename the `.zip` to `.aseprite-extension`.

## Tests

```bash
lua5.4 extensions/aseprite/tests/run.lua
```

They run `lumo.lua` against a stand-in for Aseprite's Lua API: no Aseprite needed.
