// Entry point: boot the bridge, wire the island, start the greeting.

import "./style.css";
import { Bridge, IS_TAURI, onEvent } from "./core/bridge";
import { Sound } from "./core/sound";
import { State, type Settings } from "./core/state";
import { Island } from "./island/island";
import { registerHookHandlers } from "./island/hooks";
import { registerIntegrationHandlers, refreshConfigured } from "./island/integrations";
import { registerInboxHandlers } from "./island/inbox";
import { CI_ID, refreshCI, startCIPoller } from "./core/ciPoller";
import { dndActive } from "./core/dnd.ts";
import { setLanguage, startTranslating, t } from "./core/i18n.ts";
import { speak } from "./core/voice.ts";
import { beginCapture, captureBusy } from "./views/capture";
import { describeSource } from "./core/capture";
import { setSpeaker, setListening, setFocusCommand } from "./views/chat";
import { Focus, applyFocusSettings, registerFocus } from "./island/focus";
import { parseFocusCommand } from "./core/focus.ts";
import { parseAliCommand } from "./core/aliexpressCommand.ts";
import { applyTheme } from "./core/themes.ts";

async function main() {
  const root = document.getElementById("root");
  if (!root) return;

  void Sound.preload();

  const island = new Island(root);

  const boot = await Bridge.boot();
  if (boot) {
    State.settings = { ...State.settings, ...boot.settings };
  }
  island.applySettings();
  // Themes: colour tokens on the page; "system" follows the OS appearance.
  const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  const paint = () => applyTheme(document.documentElement, State.settings.theme, darkQuery.matches);
  paint();
  darkQuery.addEventListener("change", paint);
  State.loadIntegrationTasks();
  // Spanish or English, from Settings or the system.
  setLanguage(State.settings.language);
  startTranslating(document.body);

  await onEvent<{ x: number; y: number }>("cursor", ({ x, y }) => island.onCursor(x, y));
  // Wayland (#36): no global cursor, so the page reports the pointer. The input
  // region only covers the island, so leaving the window means leaving the island.
  if (boot?.pointer === "dom") island.useDomPointer();

  /** Pause has to reach Rust too, or the pollers keep calling out. */
  const setPaused = (on: boolean) => {
    if (State.paused === on) return;
    State.paused = on;
    void Bridge.setPaused(on);
  };

  await onEvent<string>("tray", (what) => {
    switch (what) {
      case "settings":
        setPaused(false);
        island.alert("settings");
        break;
      case "open":
        setPaused(false);
        island.alert(State.defaultView());
        break;
      case "pause":
        setPaused(!State.paused);
        if (State.paused) island.fsm.forceHidden();
        else island.reveal();
        break;
    }
  });

  await onEvent<null>("screen-changed", () => void Bridge.reposition());

  // Quick capture (#118): the global shortcut opens a one-line input for a Linear issue.
  await onEvent<null>("quick-capture", () => {
    setPaused(false);
    const typing = State.mode === "expanded" && State.view === "capture" && !captureBusy();
    if (!typing) {
      // The editor's file / selection is offered, attached only if its chip is clicked.
      const ed = State.editorContext;
      const recent = ed && Date.now() - ed.at < 10 * 60_000;
      const offer = recent && ed ? describeSource({ kind: "code", file: ed.file, line: ed.line, selection: ed.selection }) : null;
      beginCapture("", offer, false);
      Sound.play("blip");
      island.alert("capture");
    }
    island.focusView();
  });

  // The settings window writes preferences; apply them here without a restart.
  await onEvent<Settings>("settings-changed", (s) => {
    // A new language takes a fresh page.
    if (s.language && s.language !== State.settings.language) {
      window.location.reload();
      return;
    }
    const ciWasOn = State.settings.activeIntegrations.includes(CI_ID);
    State.settings = { ...State.settings, ...s };
    island.applySettings();
    paint();
    applyFocusSettings();
    State.loadIntegrationTasks();
    void refreshConfigured();
    // The CI pill just switched on: poll now rather than at the next check.
    if (!ciWasOn) refreshCI();
  });

  registerHookHandlers(island);
  registerIntegrationHandlers(island);
  registerInboxHandlers(island);
  startCIPoller(() => island.reveal());
  // Focus timer (#119): Ctrl+Alt+F, and "focus 50 min on SHO-475" in the chat.
  registerFocus(island);
  setFocusCommand((query) => {
    const command = parseFocusCommand(query);
    if (command) return Focus.run(command);
    const ali = parseAliCommand(query);
    return ali ? runAliCommand(ali) : null;
  });

  // Mochi reads replies aloud (Settings → Voice), never in Do not disturb.
  setSpeaker((text) => { if (!dndActive(State.settings.dndUntil)) speak(text); });
  setListening((await Bridge.voiceAvailable()) ?? false);

  // Do not disturb mutes every sound.
  Sound.quiet = () => dndActive(State.settings.dndUntil);

  // A newer release: the ⬇ in the header (at launch, then once a day).
  const checkUpdate = async () => {
    if (!State.settings.checkUpdates) return;
    try {
      const info = await Bridge.checkUpdate();
      const canInstall = info.newer ? (await Bridge.updateCanInstall()) ?? false : false;
      State.update = info.newer ? { latest: info.latest, url: info.url, canInstall } : null;
      State.notify();
    } catch {
      // Offline or rate limited: try again tomorrow.
    }
  };
  window.setTimeout(() => void checkUpdate(), 20_000);
  window.setInterval(() => void checkUpdate(), 24 * 60 * 60_000);

  island.launch();

  // In a plain browser there is no wake strip behind the cursor: make the whole
  // page wake the island so the visuals can be checked with `npm run dev`.
  if (!IS_TAURI) {
    document.addEventListener("click", () => Sound.resume(), { once: true });
  }
}

void main();

/** "aliexpress facturas" in the chat: the browser extension makes the files. */
function runAliCommand(command: ReturnType<typeof parseAliCommand> & object): string {
  const id = "integration_aliexpress";
  if (!State.settings.activeIntegrations.includes(id)) {
    return t("Turn on the AliExpress pill first (Settings → Integrations), then open your AliExpress orders in Chrome or Edge.");
  }
  const data = (State.integrations[id]?.data ?? {}) as Record<string, unknown>;
  const packages = (Array.isArray(data.packages) ? data.packages : []) as Record<string, unknown>[];
  if (!data.seenAt) {
    void Bridge.aliexpressSync();
    return t("Open your AliExpress orders in Chrome or Edge once: Coucou reads them from there.");
  }
  const lang = State.settings.language === "es" || (State.settings.language !== "en" && navigator.language.startsWith("es")) ? "es" : "en";
  const trackings = packages.map((p) => String(p.tracking ?? "")).filter(Boolean);
  switch (command.op) {
    case "sync": {
      void Bridge.aliexpressSync();
      const onTheWay = packages.filter((p) => !/deliver|entreg/i.test(String(p.status ?? ""))).length;
      return t(`Reading your orders again. So far: ${packages.length} packages, ${onTheWay} on the way. Type “aliexpress facturas” for one invoice per package.`);
    }
    case "invoices":
      if (!trackings.length) return t("No packages with a tracking number yet.");
      for (const tr of trackings) void Bridge.aliexpressInvoice(tr, lang).catch(() => {});
      void Bridge.aliexpressCsv();
      return t(`Making ${trackings.length} invoices (one per package) and the CSV. They go to Downloads/Coucou/AliExpress.`);
    case "invoice":
      if (!command.tracking || !trackings.includes(command.tracking)) return t("I don't see that tracking number among your packages.");
      void Bridge.aliexpressInvoice(command.tracking, lang).catch(() => {});
      return t(`Making the invoice of ${command.tracking}. It goes to Downloads/Coucou/AliExpress.`);
    case "csv":
      void Bridge.aliexpressCsv();
      return t("Exporting the CSV to Downloads/Coucou/AliExpress.");
  }
}
