---
name: lumo-add-integration
description: Use when adding a new service integration to Lumo (a poller + pill + card + detail + settings key) or changing an existing one, on macOS and Windows/Linux together. A file-by-file checklist so nothing is missed on either platform.
---

# Add (or change) a Lumo integration on every platform

An integration = a poller, a pill on the island, a card, a detail view, a key in Settings. The
id is `integration_<name>` and must be **identical** everywhere. Use `lumo-macos-swift` and
`lumo-tauri-desktop` for the coding rules; this is the map. Vercel is a good model to `grep -rn
integration_vercel` for when in doubt.

Before coding: which endpoint(s), the auth (header vs Basic), the interval (30 s fast, 300 s
slow), what the pill shows, and the secret's key name (`<service>-api-key` or `<service>-token`).
Network only to that service; nothing while the pill is off, Lumo is paused or the screen is off.

## macOS (`NotchBuddy/Sources/App/`)
1. `<Name>Poller.swift` — copy `StripePoller.swift`: singleton, `PollGate.shared.allow/record`,
   `Secrets.store.get("<key>")`, `static func parse…` for each response, state pushed to
   `AppState` on the main thread, error strings through `L()`.
2. `AppState.swift` — the published fields the views read (data, `…Error`, `…Loaded`).
3. `Ports.swift` — `extension <Name>Poller: IntegrationSource { var integrationID … }` and add
   `.shared` to `Integrations.all`.
4. `IslandTypes.swift` — the task entry `.init(id: "integration_<name>", name:, color:)`.
5. Views: card in `Views/IntegrationCardView.swift`, detail in `Views/IntegrationDetailViews.swift`,
   pill/overview in `Views/OverviewViews.swift`.
6. `SettingsView.swift` — the key field (saved to the Keychain) and its help text.
7. `Tests/PollerTests.swift` — recorded JSON → parser asserts, including a malformed case.
8. Strings → `scripts/gen-strings.py` `ES` + `python3 scripts/gen-strings.py`.

## Windows / Linux (`windows/`)
1. `src-tauri/src/secrets.rs` — add the key to `KNOWN_KEYS` (anything else is refused).
2. `src-tauri/src/integrations.rs` — `poll_<name>` (reqwest + timeout, `secrets::get`), register
   it in `start()` with `spawn(app, "integration_<name>", delay, every, poll_<name>)` using the
   macOS delay/interval, and in the manual-refresh `match`.
3. `src/core/state.ts` — `task("integration_<name>", "<Name>", "<color>", …)` and
   `TOGGLEABLE_INTEGRATION_IDS` (and the defaults only if it should be on out of the box —
   then also `settings.rs` defaults).
4. `src/island/integrations.ts` — id → secret key map.
5. `src/views/integrations.ts` — dashboard URL, `<name>Card`, `<name>Detail`, and the `switch`.
6. `src/settings/main.ts` — the key field.
7. Pure parsing/decision logic in a `src/core/<name>.ts` with `<name>.test.ts` when it's more than
   trivial.
8. Spanish strings in `src/core/i18n.ts` `ES`.

## Then
- Same colour, name, interval and wording on both platforms.
- Docs: a line in the README's feature list; `docs/INTEGRATIONS.md` if behaviour is notable.
- New visuals: update `design/captures/` via the `windows/dev/` pages if the island looks different.
- Run each platform's checks (see the two platform skills) and list what you couldn't run.
