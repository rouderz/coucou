# Lumo: Ask about your code (VS Code · Cursor · Windsurf · VSCodium)

Gives [Lumo](https://github.com/rouderz/coucou) the exact context of what you're editing, so
questions like *"why is this red?"* get real answers:

- the file and its workspace folder
- the cursor line and the selected text
- the editor's errors and warnings for that file

Nothing leaves your computer: the extension talks to Lumo over its local connection — on macOS
`~/Library/Application Support/NotchBuddy/nb.sock`, on Windows the named pipe `\\.\pipe\coucou-<your SID>`,
on Linux `$XDG_RUNTIME_DIR/coucou.sock`. If Lumo isn't running, it does nothing.

## Use

- **Lumo** in the status bar, or right-click → **Ask Lumo about this**: Lumo opens its chat
  with the file, cursor, selection and problems attached.
- On macOS, Lumo's global **⌃⌥M** (and dropping your character on the window) use this same context while
  the extension is active, instead of guessing the file from the window title.

Settings: `coucou.shareContext` (keep Lumo updated) and `coucou.showStatusBar`.

## Install (no build needed)

Link the folder into your editor's extensions and reload the window:

```bash
cd ~/code/coucou/extensions/vscode
ln -sfn "$PWD" ~/.vscode/extensions/rouderz.coucou-context-0.1.0      # VS Code
ln -sfn "$PWD" ~/.cursor/extensions/rouderz.coucou-context-0.1.0      # Cursor
ln -sfn "$PWD" ~/.windsurf/extensions/rouderz.coucou-context-0.1.0    # Windsurf
```

On Windows (PowerShell), copy it instead:

```powershell
Copy-Item -Recurse "$HOME\code\coucou\extensions\vscode" "$HOME\.vscode\extensions\rouderz.coucou-context-0.1.0"
```

Or package it: `npx @vscode/vsce package`, then *Extensions → … → Install from VSIX*.

On Windows and Linux, **Ask Lumo about this** opens the island's chat with the code attached, and
the chat offers to attach the file you were last in (`+ app.ts:42`).
