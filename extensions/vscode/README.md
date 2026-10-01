# Coucou: Ask Mochi (VS Code · Cursor · Windsurf · VSCodium)

Gives [Coucou](https://github.com/rouderz/coucou) the exact context of what you're editing, so
questions like *"why is this red?"* get real answers:

- the file and its workspace folder
- the cursor line and the selected text
- the editor's errors and warnings for that file

Nothing leaves your Mac: the extension talks to Coucou over its local socket
(`~/Library/Application Support/NotchBuddy/nb.sock`). If Coucou isn't running, it does nothing.

## Use

- **Mochi** in the status bar, or right-click → **Ask Mochi about this**: Coucou opens its chat
  with the file, cursor, selection and problems attached.
- Coucou's global **⌃⌥M** (and dropping Mochi on the window) use this same context while the
  extension is active, instead of guessing the file from the window title.

Settings: `coucou.shareContext` (keep Coucou updated) and `coucou.showStatusBar`.

## Install (no build needed)

Link the folder into your editor's extensions and reload the window:

```bash
cd ~/code/coucou/extensions/vscode
ln -sfn "$PWD" ~/.vscode/extensions/rouderz.coucou-context-0.1.0      # VS Code
ln -sfn "$PWD" ~/.cursor/extensions/rouderz.coucou-context-0.1.0      # Cursor
ln -sfn "$PWD" ~/.windsurf/extensions/rouderz.coucou-context-0.1.0    # Windsurf
```

Or package it: `npx @vscode/vsce package`, then *Extensions → … → Install from VSIX*.
