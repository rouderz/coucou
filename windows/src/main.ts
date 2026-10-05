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
import { setLanguage, startTranslating } from "./core/i18n.ts";
import { speak } from "./core/voice.ts";
import { setSpeaker, setListening } from "./views/chat";

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
    State.loadIntegrationTasks();
    void refreshConfigured();
    // The CI pill just switched on: poll now rather than at the next check.
    if (!ciWasOn) refreshCI();
  });

  registerHookHandlers(island);
  registerIntegrationHandlers(island);
  registerInboxHandlers(island);
  startCIPoller(() => island.reveal());

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
