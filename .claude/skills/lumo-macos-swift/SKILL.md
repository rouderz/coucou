---
name: lumo-macos-swift
description: Use when writing, reviewing or fixing Swift code in Lumo's macOS app (NotchBuddy/ — Swift 6, SwiftUI + AppKit, XcodeGen). Covers strict concurrency, the poller / PollGate / Secrets patterns, localization with L() and gen-strings.py, XCTest parsers and the exact build and test commands.
---

# Lumo — macOS app (Swift 6 · SwiftUI + AppKit)

Read the repo's `CLAUDE.md` rules first; this skill is the *how*. Code lives in
`NotchBuddy/Sources/App/` (views in `Views/`, the character engine in `Bot/`), tests in
`NotchBuddy/Tests/`, the project in `NotchBuddy/project.yml`.

## Hard rules (break one = wrong change)
- Never touch `NotchBuddy.xcodeproj`. Edit `project.yml`, then `xcodegen`.
- No third-party packages. Foundation, SwiftUI, AppKit, `os.Logger`, XCTest only.
- Swift 6 with `-strict-concurrency=complete`: CI greps for `warning: .*Sendable`. A new
  Sendable warning is a failing change, not a nit.
- Secrets only through `Secrets.store` (`Ports.swift`, Keychain), keyed like the existing ones
  (`"stripe-api-key"`, `"github-token"`). Never UserDefaults, files, logs or `print`.
- No network call except to a service the user configured; nothing at all while the island is
  hidden more than `PollGate` allows. 0 % CPU when hidden: no timers/animations running for
  hidden views (`TimelineView` only while visible).
- Keep bundle id `fr.louisraille.NotchBuddy` and the `os.Logger` subsystem as is.
- Visual changes must match `design/captures/` or update the capture in the same change.

## Patterns to copy, not reinvent
| Need | Copy from |
|---|---|
| New integration poller | `StripePoller.swift` (smallest complete one) |
| When to poll / backoff / 401 handling | `PollGate.shared.allow(id, every:)` + `.record(id, response)` |
| Shared UI state | `AppState.shared` — mutate **only** on the main thread (`DispatchQueue.main.async` / `@MainActor`) |
| Card / pill / detail views | `Views/IntegrationCardView.swift`, `IntegrationDetailViews.swift`, `OverviewViews.swift` |
| Integration ids | `"integration_<name>"` — same id string on Windows/Linux (`integrations.rs`) |

Poller shape: singleton `final class X: @unchecked Sendable` with `private init()`, a
`DispatchSourceTimer` on a background queue, `guard PollGate.shared.allow(...)`, then
`URLSession` with an explicit `timeoutInterval`. Put JSON parsing in a `static func parseX(_:
[String: Any]) -> X?` so tests can feed recorded responses. `@unchecked Sendable` is only OK when
every mutable field is touched from one queue or guarded by a lock (see `PollGate`'s `NSLock`);
say which in a comment.

## Concurrency checklist
- UI-touching types: `@MainActor`. Background work hops back with `await MainActor.run` or
  `DispatchQueue.main.async` — pick the style the file already uses.
- Closures crossing threads capture `[weak self]` and only Sendable values.
- Don't silence a warning with `nonisolated(unsafe)` or `@preconcurrency` without a comment
  explaining why it's actually safe.

## Strings (English + Spanish)
Every user-visible string goes through `L("…")`. Then add the Spanish line to the `ES` dict in
`scripts/gen-strings.py` and run `python3 scripts/gen-strings.py` (regenerates
`Resources/Localizable.xcstrings`). The Windows/Linux app needs the same English → Spanish pair
in the `ES` table of `windows/src/core/i18n.ts`.

## Tests
Add an XCTest for every parser or pure decision (see `Tests/PollerTests.swift`: recorded JSON in,
`XCTUnwrap` + asserts out). Module name is `Lumo` (`@testable import Lumo`).

## Commands (macOS only — say so if you can't run them)
```bash
cd NotchBuddy && xcodegen
xcodebuild test -scheme NotchBuddy -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcodebuild -scheme NotchBuddy -configuration Debug build
```
On Linux/cloud you cannot build Swift for AppKit: keep changes small, mirror existing code
exactly, and state that the build wasn't run.

## Parity
A feature on macOS normally exists on Windows/Linux too (README "Platforms"). When adding or
changing behaviour, check the matching Tauri file (often named the same: `CIPoller.swift` ↔
`windows/src/core/ciPoller.ts` + `windows/src-tauri/src/ci.rs`) and use the
`lumo-tauri-desktop` skill for that side, or say clearly which side is left.
