<div align="center">

<img src="NotchBuddy/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="96" alt="Coucou icon">

# Coucou — rouderz fork

**A notch companion for Claude Code power users.** Watch every session, approve from the notch
(or your phone), see the diff Claude is about to write, and ask Mochi about the file you're in —
using your Claude Code subscription, no API key needed.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-native-0A84FF)
![License: MIT](https://img.shields.io/badge/code-MIT-green)
[![Build and test](https://github.com/rouderz/coucou/actions/workflows/build.yml/badge.svg)](https://github.com/rouderz/coucou/actions/workflows/build.yml)

<img src="docs/media/demo.gif" width="760" alt="Coucou in action">

</div>

> Fork of [Louis-CFM/coucou](https://github.com/Louis-CFM/coucou) by Louis Raillé. The name,
> the Mochi character, the icon and the sounds are his and are not covered by the MIT license —
> see [License](#license). This fork is for personal use until it has its own branding.

---

## What this fork adds

**Claude Code**
- **Several sessions at once** — one chip per project, coloured by state; approvals queue instead of cancelling each other.
- **Live view** — the file Claude is changing, as a diff, with its steps; approve right under the diff.
- **Session timeline** — prompts, files read, edits, commands and approvals with times and durations; copy as Markdown.
- **Safer approvals** — risk colours (red for `rm -r`, force-push, `curl | sh`…), "Always…" shows the exact rule before saving it, ⌥⏎ / ⌥⌫ from the keyboard (never ⌥⏎ on high risk).
- **Auto-approve per project** — let low (or low and medium) risk requests through on their own; high risk always asks.
- **Phone alerts** — approvals that wait while you're away go to your phone through [ntfy](https://ntfy.sh).
- **Plan usage** — 5-hour and weekly limits like claude.ai, plus the context window of the running session.

**Mochi, your assistant**
- **Chat with your Claude Code subscription** (no API key), or an Anthropic API key with streaming and clear errors. Model picker: Opus 5.5 by default.
- **Ask about the file you're editing** (⌃⌥M) — reads the project, never edits unless you turn on "Edits on"; every change is approved in the island.
- **Editor extension** for VS Code, Cursor, Windsurf and VSCodium — exact file, cursor, selection and errors. See [`extensions/vscode`](extensions/vscode).
- **Push-to-talk** (hold ⌃⌥V) — speak, Mochi answers and reads it aloud. On-device transcription when the Mac supports it.
- **Chat history** — the last 50 conversations, resumable.

**Everyday**
- **Do not disturb** — 🌙 in the island, or automatically during calendar events.
- **Spanish and English** interface.
- **GitHub through your `gh` login**, any editor for "Open in…", status lights and refresh on every integration.
- **Lighter** — the island idles at ~0.2 % CPU; integrations poll less when hidden, stop when the screen is locked and back off on errors.

## Install

**Download:** every release on the [Releases](https://github.com/rouderz/coucou/releases) page has all three:

| | File | First launch (not code-signed yet) |
|---|---|---|
| macOS | `Coucou-<version>-macOS.dmg` — drag Coucou to Applications | System Settings → Privacy & Security → **Open Anyway** |
| Windows | `Coucou-<version>-Windows-setup.exe` | SmartScreen → **More info → Run anyway** |
| Linux | `.deb`, `.rpm` or `.AppImage`, x86_64 and arm64 | — |

Coucou for Mac checks for new releases itself (Settings → Updates). To try a build without releasing, run the
[Release workflow](https://github.com/rouderz/coucou/actions/workflows/release.yml) by hand: the files stay on the run as artifacts.

**Release:** `bash scripts/release.sh 0.3.0` sets the version for every platform, tags `v0.3.0` and pushes; GitHub
Actions builds macOS, Windows and Linux and publishes them together. `bash scripts/build.sh` builds for the
system you're on, into `dist/`.

**Build from source:**
Requirements: macOS 15+, Xcode 16+ (Xcode 27 works), [XcodeGen](https://github.com/yonaskolb/XcodeGen), and
[Claude Code](https://docs.claude.com/en/docs/claude-code) signed in for the subscription chat.

```bash
brew install xcodegen
git clone https://github.com/rouderz/coucou.git
cd coucou/NotchBuddy
xcodegen
xcodebuild -scheme NotchBuddy -configuration Debug build
open "$(xcodebuild -scheme NotchBuddy -configuration Debug -showBuildSettings | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/Coucou.app"
```

Run `xcodegen` again whenever files are added. Tests: `xcodebuild test -scheme NotchBuddy -destination 'platform=macOS'`.
GitHub Actions builds (Debug and Release) and runs the tests on every PR to `main`.

## Setup

Menu bar icon → **Settings…**

| What | Why |
|---|---|
| **Claude Code Hooks → Install / Update hooks** | live sessions, approvals and plan usage. Coucou backs up `~/.claude/settings.json` and shows the diff first. |
| **Chat → Engine** | *Claude Code (subscription)* needs nothing else; *Anthropic API key* goes to the Keychain. |
| **Hotkey** | ⌃⌥M ask about the file · ⌃⌥V push-to-talk · ⌥⏎ / ⌥⌫ approvals. Grant Accessibility for ⌃⌥M. |
| **Auto-approve · Phone alerts · Do not disturb** | optional, all off by default. |
| **Integrations** | GitHub (uses `gh` if signed in), Vercel, Stripe, Resend, n8n, Notion, Cal.com — all optional. |

If Coucou isn't running, the hook exits at once: **Claude Code is never blocked.**

## Shortcuts

| Keys | Does |
|---|---|
| ⌃⌥M | ask Mochi about the file in the front editor (with the extension: exact cursor, selection and errors) |
| hold ⌃⌥V | push-to-talk |
| ⌥⏎ / ⌥⌫ | allow / deny the waiting approval (only while one is waiting) |

## Privacy

No telemetry, no account. Keys live in the macOS Keychain. Coucou talks only to the services you
configure, plus: Anthropic (`api.anthropic.com`) with your Claude Code login to read plan usage, and
your ntfy server if you turn on phone alerts (it receives the project and the command — keep the topic private).
The editor extension talks to Coucou over a local socket only.

## How it works

- **Island**: a borderless `NSPanel` hugging the notch, driven by a small state machine.
- **Claude Code**: the `nb-hook` script forwards hook events over a Unix socket; for approvals it waits for your answer. A status line script forwards plan usage and context.
- **Chat**: `claude -p --output-format stream-json` with your subscription (or the Messages API with streaming and prompt caching).
- **Views** live in `NotchBuddy/Sources/App/Views/`; tests in `NotchBuddy/Tests/`.
- Native Swift 6 / SwiftUI / AppKit, **no third-party dependencies**.

The Windows app (`windows/`) comes from upstream and hasn't received this fork's features yet.

## License

- **Code:** [MIT](LICENSE) — © Louis Raillé, and rouderz for the changes in this fork.
- **Name, Mochi character, icon, sounds and media:** © Louis Raillé, all rights reserved — see [LICENSE-ASSETS.md](LICENSE-ASSETS.md).
  Running this fork for yourself is fine; publishing builds needs its own name and artwork (tracked in #45).

Original project: built by [Louis Raillé](https://louisraille.fr) with Claude Code.
