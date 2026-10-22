---
name: lumo-tauri-desktop
description: Use when writing, reviewing or fixing Lumo's Windows / Linux app in windows/ — Tauri 2 with a Rust backend (src-tauri/, hook/) and a vanilla TypeScript + Vite front end (src/, no React). Covers the bridge, pure testable logic modules, Rust as the validating network/secret layer, parity with the Swift app, and the exact check / test / build commands.
---

# Lumo — Windows / Linux app (Tauri 2 · Rust · TypeScript)

Read the repo's `CLAUDE.md` rules first; they apply here too (secrets, no telemetry, never block
Claude Code, never write `~/.claude/settings.json` without backup + diff + click).

## Layout
- `windows/src/` — front end, **plain TypeScript DOM code, no framework**. `core/` logic and
  pollers, `claude/` sessions, risk, auto-approve, timeline, `island/`, `views/`, `settings/`.
- `windows/src-tauri/src/` — Rust: one module per concern (`ci.rs`, `integrations.rs`,
  `secrets.rs`, `editor_socket.rs`, `platform/`…). Commands registered in `lib.rs`
  `tauri::generate_handler![…]`; permissions in `src-tauri/capabilities/default.json`.
- `windows/hook/` — the `coucou-hook` relay crate Claude Code spawns on every event. It must start
  fast and exit immediately when Lumo doesn't answer (300 ms budget). Keep it dependency-light.

## The split that every feature follows
1. **Decisions in pure TS** (`core/ci.ts`, `claude/risk.ts`…): parsing, state machines,
   intervals, what to show. No DOM, no `invoke`, so `node --test` can cover them.
2. **The page drives it** (`core/ciPoller.ts`): timers, calls `Bridge`, renders.
3. **Rust only does what the page can't, and refuses the rest** (`ci.rs`): attaches the secret
   (`secrets::get("…")`, OS keyring), makes the HTTP call with `reqwest` + timeout, validates
   every input (`repo_ok`, path segments, allow-listed endpoints), checks `PAUSED`. Never trust a
   string from the page to build a URL or path without validation.
4. **`core/bridge.ts` is the only place that calls `invoke` / `listen`**; every call is a no-op
   outside Tauri so `npm run dev` works in a plain browser. Add new commands there, typed.

## TypeScript rules (tsconfig is `strict` + `noUnused*` + `verbatimModuleSyntax`)
- `import type` for types; relative imports keep the `.ts` extension like the files around them.
- No `any`; parse unknown JSON into typed values with explicit checks (see `parseCheckRuns`).
- Export constants for magic numbers (`GREEN_MS`, `SLOW_MS`) so tests can import them.
- Tests sit next to the module: `x.test.ts`, `node:test` + `node:assert/strict`.

## Rust rules
- `tokio`/`tauri::async_runtime::spawn` for background work; no blocking calls on the async
  runtime. Shared state via `LazyLock<Mutex<…>>` or atomics as the existing modules do.
- No `unwrap()` on anything from the network, the user or the page; log with `crate::log::line`.
- Platform code behind `#[cfg(windows)]` / `#[cfg(target_os = "linux")]` (`platform/`). Linux
  must work on X11 and Wayland (layer-shell; no global cursor there → `pointer: "dom"`).
- Integration ids match macOS exactly: `"integration_<name>"`; pollers via
  `integrations::spawn(app, id, delay, every, poll_fn)` with the macOS delay/interval.
- Add `#[test]`s for validators and parsers.

## Commands (run from `windows/`, Node 22)
```bash
npm ci
npx tsc --noEmit                         # type check
npm test                                 # front-end logic tests
node --test ../extensions/whaticket/background.test.js ../extensions/aliexpress/aliexpress.test.js
npm run build && cargo test --workspace  # front end must exist before the app crate compiles
```
Linux needs WebKitGTK, layer-shell, tray and keyring dev packages to compile (see
`.github/workflows/desktop.yml`). If they're missing, run the TS checks and `cargo check -p
coucou-hook`, and say what wasn't run.

## Parity and strings
- Each feature mirrors the macOS one; files say "Port of X.swift" at the top — keep that comment
  and behaviour aligned. When the Swift side changes, update here or note the gap.
- User-visible English strings get their Spanish pair in the `ES` table of `src/core/i18n.ts`
  (the macOS side uses `scripts/gen-strings.py`).
- One version across platforms: `bash scripts/versions.sh set X.Y.Z`, never edit one file alone.
- UI must match `design/captures/`; the dev pages in `windows/dev/` render those captures.
