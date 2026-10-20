# Lumo for Godot

Ask [Lumo](https://github.com/rouderz/coucou) about what you're doing in Godot. Your question goes
with:

- the script in front, the cursor line, the selected text and the script editor's errors and warnings
- the open scene and its tree, the selected nodes and the properties you changed on them
- a snapshot of the editor window, so Lumo sees what you see

Lumo's chat runs in your project folder, so it can read your other scripts and scenes too.
Nothing leaves your computer: the plugin talks to Lumo over a local WebSocket (`127.0.0.1`) with a
token only your user can read. If Lumo isn't running, it does nothing.

Made for the current stable Godot 4 (tested on 4.7.2).

## Use

- **Lumo** in the editor toolbar, **Ctrl+Alt+L** (**Cmd+Alt+L** on macOS), the command palette, or
  right-click code / a node → **Ask Lumo about this**: Lumo opens its chat with all of the above.
- While Lumo is open, the plugin keeps it told about the script or scene in front (no snapshot), so
  Lumo's own shortcut and dropping your character on Godot use it too.

Editor Settings → **Lumo**: *Share Context* (keep Lumo told) and *Attach Editor Snapshot*.

## Install

Copy `addons/lumo` into your project's `addons/` folder, then **Project → Project Settings →
Plugins** and enable **Lumo**.

```bash
cp -r ~/code/coucou/extensions/godot/addons/lumo ~/my-game/addons/
```

Or grab `lumo-godot.zip` from `scripts/pack-editor-plugins.sh` and unzip it at your project's root.

## How it finds Lumo

Lumo writes its port and token at launch in `editor-bridge.json`:
macOS `~/Library/Application Support/NotchBuddy/`, Windows `%LOCALAPPDATA%\Coucou\`,
Linux `~/.local/share/coucou/` (`$XDG_DATA_HOME/coucou`). The plugin reads it on each connection,
so restarting Lumo is fine.
