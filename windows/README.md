<div align="center">

<img src="src-tauri/icons/128x128.png" width="96" alt="Coucou icon">

# Coucou for Windows and Linux

**Mochi doesn't get a notch on a PC — so it brings its own, at the top of your screen.**

Approve Claude Code permissions, watch your session work, drop a file, chat with Claude, keep an eye on your services — without leaving what you're doing.

![Windows 10/11](https://img.shields.io/badge/Windows-10%2F11-0078D4?logo=windows)
![Linux](https://img.shields.io/badge/Linux-X11%20%7C%20Wayland-FCC624?logo=linux&logoColor=black)
![Tauri 2](https://img.shields.io/badge/Tauri-2-FFC131?logo=tauri&logoColor=black)
![Rust](https://img.shields.io/badge/Rust-backend-000?logo=rust)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

</div>

<img src="screenshots/greeting.png" width="640" alt="Mochi waving hello at launch">

---

## Install

Every release on the [Releases](https://github.com/rouderz/coucou/releases) page has:

| | File | Notes |
|---|---|---|
| Windows 10/11 | `Coucou-<version>-Windows-setup.exe` | installs for the current user only, no admin prompt |
| Debian, Ubuntu | `Coucou-<version>-Linux-<arch>.deb` | `x86_64` or `arm64` |
| Fedora, openSUSE | `Coucou-<version>-Linux-<arch>.rpm` | |
| Any other distribution | `Coucou-<version>-Linux-<arch>.AppImage` | `chmod +x`, then run it |

The builds aren't code-signed yet (#39). On Windows, SmartScreen asks first:
**More info → Run anyway**. Microsoft Defender has wrongly flagged unsigned
builds before (`Trojan:Win32/Wacatac.H!ml`, a machine-learning false positive);
if that happens, [build it yourself](#build-it-yourself) — it takes a few minutes.

**Updates:** when a new version is out, a ⬇ appears in the island. Click it and
Coucou downloads the update, checks its signature, installs it and restarts.
The Windows installer and the AppImage update themselves; `.deb` and `.rpm`
installs (owned by the package manager) open the download instead. Turn the
check off in Settings → Updates.

## Using it

<img src="screenshots/compact.png" width="292" alt="The compact island, with the integration pills as mini Mochis">
<img src="screenshots/overview.png" width="640" alt="The overview: the focused integration on the left, the other pills on the right">
<img src="screenshots/approval.png" width="640" alt="A Claude Code permission request, with Deny and Allow">
<img src="screenshots/chat.png" width="640" alt="Chatting with Claude from the island">
<img src="screenshots/drop.png" width="640" alt="Mochi turned into a box, waiting for a file">

| What you do | What happens |
|---|---|
| Move the mouse to the small notch at the top centre of the screen | Mochi peeks out |
| Click the small island | It opens |
| Click Mochi | It gets annoyed. Three times in a row and it goes dizzy |
| Rest the pointer on Mochi for two seconds | Hearts |
| Drag a file onto the island | Mochi turns into a box, swallows it, then offers to answer questions about it |
| `Esc` | Closes the island |
| `Alt+Enter` / `Alt+Backspace` | Allow / deny the waiting approval, from any app (X11 only on Linux) |
| Tray icon | Open, Settings…, Pause, Quit |

Everything else happens on its own: a Claude Code permission request opens the
island with **Deny / Allow**, a finished session shows what it did, and
your integrations sit in the coloured pills next to Mochi.

When the island hides, a small notch stays at the top centre, like the Mac's, so
Coucou never seems gone. Coucou also keeps itself above other always-on-top
windows (the taskbar, full-screen apps). Don't want the notch? **Settings →
General → Idle notch** leaves only an invisible strip at the top edge.

## Claude Code

<img src="screenshots/settings.png" width="562" alt="The settings window">

Open **Settings… → Claude Code → Install hooks…**. You get the exact diff of what
will change in `%USERPROFILE%\.claude\settings.json`, the path of the dated backup
that will be taken, and nothing is written until you click. Your own hooks are
never touched, and uninstalling removes only Coucou's entries.

The relay is a tiny executable, `coucou-hook.exe`, copied to
`%LOCALAPPDATA%\Coucou\bin\` at launch. It is given 300 ms to reach Coucou and
exits cleanly if the app is closed, slow or crashed — **a Claude Code session is
never blocked or slowed down by Coucou.** If nobody answers a permission request
in time, Coucou stays quiet and Claude Code asks in the terminal as usual.

It works from any terminal — Windows Terminal, PowerShell, VS Code, Git Bash.

## Chat and keys

**Settings… → Chat** picks the engine: your own **Claude Code** (signed in with
your Claude plan, no key needed), an **Anthropic API key**, or an OpenAI-compatible
provider (OpenAI, Gemini, OpenRouter, Ollama, LM Studio, or any server you point
it at). Keys live in the **Windows Credential Manager** or the Linux **Secret
Service** (GNOME Keyring, KWallet), never on disk and never in the interface —
the island can only ask whether a key exists. Same for every integration key.

No telemetry. The only network requests Coucou makes are to the services you
configure yourself, and to GitHub to check for updates (Settings → Updates).

## Build it yourself

You need [Rust](https://rustup.rs), [Node 20+](https://nodejs.org), and the
**MSVC build tools** (Visual Studio Build Tools with "Desktop development with
C++"). WebView2 ships with Windows 10/11.

```powershell
cd windows
npm install
npm run tauri dev      # live-reloading development build
npm run pack           # builds the installer and drops it in windows/release/
```

`npm run dev` alone serves the front end in an ordinary browser, which is enough
to work on the island's looks. It also serves `dev/upload-preview.html`, which
replays the whole file-drop choreography on a loop — the one part of the UI that
otherwise needs a real drag from Explorer to see. Neither page ships in the app.

`npm run pack` leaves two files in `windows/release/`:

```
Coucou-Windows-X.Y.Z-setup.exe    the versioned installer
Coucou-Windows-setup.exe          the same file under the rolling name
```

Tests: `npm test` for the front-end logic, `cargo test` for the Rust side. Both
run on every pull request, on Windows and Linux
([`desktop.yml`](../.github/workflows/desktop.yml)). Releases are built by
[`release.yml`](../.github/workflows/release.yml) on `v*` tags, or by hand from
the Actions tab for a test build (`bash scripts/release.sh X.Y.Z` from the repo
root does the tagging).

Installing is optional — `target/release/coucou.exe` runs on its own. There is no
window in the taskbar and no console: the island at the top of the screen and the
Mochi in the notification area are the whole app, and Quit lives in its menu.

The 28 sounds are the macOS app's own files; they are never duplicated in this
folder. The path is declared once, in `SOUNDS_DIR` at the top of
`vite.config.ts` — when they move to `shared/sounds/`, change that one line.

The app icon and the tray icon are drawn in code, like Mochi itself:

```powershell
npm run icons          # regenerates src-tauri/icons from scripts/gen-icons.mjs
```

### Layout

```
windows/
  src/                 island front end (TypeScript, no framework)
    mochi/             Mochi and the launch greeting, in Canvas 2D
    island/            state machine, hooks, integrations
    views/             every island view
    settings/          the settings window
  src-tauri/           Rust backend: window, named pipe / socket, Claude API, pollers
    src/platform/      what differs between Windows and Linux
  hook/                coucou-hook(.exe), the Claude Code relay
  scripts/             icon generator, installer packing
```

### Log

`%LOCALAPPDATA%\Coucou\coucou.log` (Linux: `~/.local/share/coucou/coucou.log`) —
hook events, permission decisions, poller problems. It stays on your machine.

## Linux

The same app runs on Linux (#33–#37). Packages: `.deb` (Debian, Ubuntu), `.rpm`
(Fedora, openSUSE) and `.AppImage` (anything else), for x86_64 and arm64, built
by the [release workflow](../.github/workflows/release.yml) with the other
platforms. For a test build without releasing, run it by hand with
`platforms: linux` and download the run's artifacts.

What changes:

| | Windows | Linux |
|---|---|---|
| Relay | `coucou-hook.exe` over `\\.\pipe\coucou-<sid>` | `coucou-hook` over `$XDG_RUNTIME_DIR/coucou.sock` (0600, own uid only) |
| Keys | Credential Manager | Secret Service (GNOME Keyring, KWallet) |
| Settings | `%APPDATA%\Coucou` | `~/.config/coucou` |
| Relay, log, inbox | `%LOCALAPPDATA%\Coucou` | `~/.local/share/coucou` |

**X11** works like Windows: the island sits at the top centre and follows the cursor.

**Wayland** gives apps neither a global cursor nor a say in where windows go, so
there the island is a *layer-shell* surface anchored to the top edge (KDE Plasma,
Sway, Hyprland, and other wlroots compositors), and the page tracks the pointer
itself. GNOME has no layer-shell: on GNOME Coucou runs through XWayland
(`GDK_BACKEND=x11`) automatically. Set `GDK_BACKEND` yourself to override.

To build it:

```bash
# Debian/Ubuntu
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev libgtk-layer-shell-dev \
  libayatana-appindicator3-dev librsvg2-dev libdbus-1-dev libssl-dev patchelf
cd windows
npm install
npm run tauri dev       # development build
npx tauri build         # .deb, .rpm and .AppImage in target/release/bundle/
```

## What's different from the Mac version

- No notch, so the island lives at the top centre of the screen and leaves a
  small notch of its own there when it hides (Settings → General → Idle notch).
- Permission approval works from **any** terminal; the Mac build only listens to
  VS Code sessions.
- Not in this version: sending a file by email, dragging Mochi onto a window to
  attach it as context, and jumping to a specific terminal window — "Open
  terminal" opens the working folder in the editor picked in Settings (VS Code,
  Cursor, Windsurf or Zed, whichever are on your `PATH`).
- Claude Code works like on the Mac: approvals with their risk, a queue when
  several ask at once, auto-approve per project, several sessions as chips, a
  timeline per session (Copy as Markdown), the diff of an edit before you allow
  it, plan usage bars, and Codex CLI sessions (Settings → Codex CLI).
- Also like the Mac: Do not disturb (🌙: no sounds, the island never opens by
  itself), phone alerts through ntfy for approvals left waiting, an inbox (🔔)
  of GitHub and Linear notifications, a Linear card with the issue your branch
  names (and the timeline posted on it), self-updates (⬇), and Alt+Enter /
  Alt+Backspace to allow or deny from any app while a card is up (X11 only on
  Linux). Not here: Do not disturb during calendar events (needs macOS EventKit).
- Chats are saved (History, New chat); the chat can also use OpenAI, Gemini,
  OpenRouter, Ollama, LM Studio or any OpenAI-compatible server; the interface
  is in English or Spanish; Mochi can read its replies aloud, and on Windows
  you can speak your question (🎙). The VS Code / Cursor extension works here
  too ("Ask Mochi about this"). Not here: "Hey Mochi" (no on-device keyword
  detection) and speaking questions on Linux (no built-in speech recognition).
- The chat runs on an Anthropic API key or on your own Claude Code (Settings →
  Chat → Engine), signed in with your Claude plan; GitHub works with a token or
  with a signed-in GitHub CLI (`gh auth login`).
- Cal.com shows the next bookings as a list rather than the Mac's calendar.

## License

The code is [MIT](../LICENSE). The name Coucou, the Mochi character, the icons
(including the ones `scripts/gen-icons.mjs` draws) and the sounds are Louis
Raillé's and are not covered by it — see [LICENSE-ASSETS.md](../LICENSE-ASSETS.md).
The builds include open-source libraries (Tauri and its plugins, the `windows`
crate, GTK / WebKitGTK bindings and the rest of [`Cargo.lock`](Cargo.lock) and
[`package-lock.json`](package-lock.json)), each under its own license.
