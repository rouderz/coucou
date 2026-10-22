---
name: lumo-editor-plugins
description: Use when building or changing Lumo's editor plugins in extensions/ — the Godot 4 addon (GDScript, extensions/godot/addons/lumo), the Aseprite extension (Lua, extensions/aseprite), or the VS Code extension — and the local editor bridge they talk to (EditorSocketServer.swift / editor_socket.rs). Covers the protocol, size limits, current-stable targeting, testing and packaging.
---

# Lumo — editor plugins (Godot · Aseprite · VS Code)

These plugins are Lumo's "AI side" inside the editors: they send what the user is working on to
Lumo, and Lumo's chat answers. **Target the current stable release on Steam** of Godot and
Aseprite; check what's current before relying on a version-specific API, and don't pin versions in
code or docs beyond "tested on X".

## The bridge (don't break it)
- Godot and Aseprite use a **local WebSocket**: `127.0.0.1`, preferred port 47615 or any free one.
  Port + token live in `editor-bridge.json` (macOS `~/Library/Application Support/NotchBuddy/`,
  Windows `%LOCALAPPDATA%\Coucou\`, Linux `$XDG_DATA_HOME/coucou` or `~/.local/share/coucou`).
  Re-read it on every connection (Lumo may have restarted); on a token error retry once.
- VS Code uses Lumo's pipe / Unix socket (`nb.sock`, `\\.\pipe\coucou-<SID>`) instead.
- One JSON text message per event, the hook shape plus `"token"`, `"hook_event_name"`, and for
  Godot/Aseprite `"details"` (text) and `"image"` (snapshot path). Only two events exist:
  `EditorContext` (silent "here's what's in front", newest replaces queued ones) and `EditorAsk`
  (open Lumo's chat). Answer is `{"ok":true}` or `{"ok":false,"error":…}`.
- The server refuses browser `Origin`s and anything else; **nothing from a plugin may approve a
  Claude Code permission or touch a session**. Never add such a message type.
- Changing the protocol means changing both servers (`NotchBuddy/Sources/App/EditorSocketServer.swift`
  and `windows/src-tauri/src/editor_socket.rs`) and all plugins in the same change.
- If Lumo isn't running, plugins do nothing and never block or spam errors in the editor.
- Respect the limits already defined (`MAX_DETAILS = 11000`, `MAX_SNAPSHOT_WIDTH/MAX_SNAPSHOT
  1600`, tree depth/node caps, server `MAX_MESSAGE` 1 MiB, snapshot 8 MiB). Truncate, don't fail.

## Godot (GDScript, `@tool` EditorPlugin)
- Files: `plugin.gd` (entry, toolbar, shortcut Ctrl/Cmd+Alt+L, context menus via
  `EditorContextMenuPlugin`), `lumo_client.gd` (WebSocketPeer, queue, idle close 30 s),
  `lumo_context.gd` (gathers script/scene/selection), `lumo_menu.gd`.
- Static typing everywhere (`var x := …`, typed arrays, `-> void`), tabs for indentation, `##`
  doc comments. Every script starts with `@tool` because it runs in the editor.
- Poll the socket from `_process` only while connected or connecting; disconnect when idle.
  Clean up everything in `_exit_tree` (menus, shortcuts, toolbar button, timers).
- Use `EditorInterface` (singleton) APIs, `ProjectSettings.globalize_path` for real paths, and
  Editor Settings under `lumo/…` for options (Share Context, Attach Editor Snapshot).
- No automated tests yet: verify by loading the addon in the current stable Godot, and say so.

## Aseprite (Lua extension)
- `lumo.lua` holds everything; `package.json` declares the script and `lumo.aseprite-keys`.
  Entry points `init(plugin)` / `exit(plugin)`; commands under Edit → Lumo and the cel menu.
- Use Aseprite's `WebSocket`, `Timer`, `json`, `app.fs` APIs; tiny sprites are scaled up by whole
  pixels (nearest neighbour) for the snapshot. Debounce context updates (`CONTEXT_DELAY`).
- Aseprite may prompt for file access the first time; keep reads/writes to the bridge file and
  Lumo's snapshot dir only.
- Tests run without Aseprite against a stand-in API: `lua5.4 extensions/aseprite/tests/run.lua`.
  Add a case there for every new field or behaviour, and extend the stand-in only with APIs the
  real Aseprite has.

## VS Code
`extensions/vscode/extension.js` (plain JS, no bundler, `engines.vscode ^1.80`). Keep it
dependency-free; command `coucou.ask` ids stay as they are for existing users.

## Packaging
`bash scripts/pack-editor-plugins.sh` → `dist/lumo-godot.zip` and `dist/lumo.aseprite-extension`.
Bump the plugin's own version (`plugin.cfg`, `package.json`) when its behaviour changes and update
its README.
