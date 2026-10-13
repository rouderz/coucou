// The free-floating character (Settings → General → Where it lives → Free). Its own small
// window (src-tauri/src/buddy.rs): drag it anywhere, click it to open the island next to
// it, right-click for options. The island window tells it which state to show.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { BotEngine } from "../mochi/engine";
import { DEFAULT_CRITTER, assignments, isCritter } from "../mochi/critters";
import type { BotStateName } from "../core/layout";
import type { Settings } from "../core/state";

const W = 104;
const H = 112;
const IS_TAURI = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

const canvas = document.getElementById("buddy") as HTMLCanvasElement;
const dpr = Math.min(2, window.devicePixelRatio || 1);
canvas.width = Math.round(W * dpr);
canvas.height = Math.round(H * dpr);
canvas.style.width = `${W}px`;
canvas.style.height = `${H}px`;
const ctx = canvas.getContext("2d")!;

const engine = new BotEngine();
engine.setState("idle", true);

/** "main" (Claude Code) or the id of the integration this character handles (#151). */
let key = "main";
let settings: Partial<Settings> = {};

function applySettings(s: Partial<Settings> | null | undefined) {
  if (s) settings = s;
  const main = isCritter(settings.critter) ? settings.critter : DEFAULT_CRITTER;
  engine.critter = key === "main" ? main : assignments(settings.critterAssignments)[key] ?? main;
}

// ── Frame loop (~30 fps: breathing, blinking, extras) ─────────────────────────

let last = performance.now();
let acc = 0;
function frame(now: number) {
  const dt = Math.min(0.05, (now - last) / 1000);
  last = now;
  acc += dt;
  if (acc >= 1 / 30) {
    engine.update(acc);
    acc = 0;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);
    engine.draw(ctx, W, H);
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

// Looks at the pointer while it is over the window, else straight ahead.
canvas.addEventListener("mousemove", (e) => {
  engine.lookX = Math.tanh((e.offsetX - W / 2) / 60);
  engine.lookY = -Math.tanh((e.offsetY - H / 2) / 50);
});
canvas.addEventListener("mouseleave", () => { engine.lookX = 0; engine.lookY = 0; });

// ── Click vs drag ─────────────────────────────────────────────────────────────

let down: { x: number; y: number } | null = null;
let dragging = false;

canvas.addEventListener("mousedown", (e) => {
  if (e.button !== 0) return;
  down = { x: e.screenX, y: e.screenY };
  dragging = false;
});

canvas.addEventListener("mousemove", (e) => {
  if (!down || dragging || (e.buttons & 1) === 0) return;
  if (Math.hypot(e.screenX - down.x, e.screenY - down.y) < 4) return;
  dragging = true;
  canvas.classList.add("dragging");
  // The OS moves the window from here; the drop is saved from onMoved below.
  if (IS_TAURI) void getCurrentWindow().startDragging().catch(() => {});
});

window.addEventListener("mouseup", (e) => {
  if (e.button !== 0) return;
  const wasClick = down && !dragging;
  down = null;
  dragging = false;
  canvas.classList.remove("dragging");
  if (wasClick && IS_TAURI) void invoke("buddy_clicked").catch(() => {});
});

canvas.addEventListener("contextmenu", (e) => {
  e.preventDefault();
  if (IS_TAURI) void invoke("buddy_menu").catch(() => {});
});

// ── Wiring ────────────────────────────────────────────────────────────────────

async function boot() {
  if (!IS_TAURI) return;
  const info = await invoke<{ settings: Settings }>("boot").catch(() => null);
  applySettings(info?.settings);

  const refreshKey = async () => {
    key = (await invoke<string>("buddy_key").catch(() => null)) ?? "main";
    applySettings(null);
  };
  await refreshKey();
  await listen<Settings>("settings-changed", (e) => applySettings(e.payload));
  await listen("buddy-keys", () => void refreshKey());
  await listen<Record<string, string>>("buddy-state", (e) => {
    const s = e.payload[key];
    if (s) engine.setState(s as BotStateName);
  });

  // Remember where it was dropped (logical px), once the window stops moving.
  const win = getCurrentWindow();
  let saveTimer: number | null = null;
  await win.onMoved(({ payload }) => {
    if (saveTimer != null) window.clearTimeout(saveTimer);
    saveTimer = window.setTimeout(async () => {
      saveTimer = null;
      const scale = await win.scaleFactor();
      void invoke("buddy_moved", { x: payload.x / scale, y: payload.y / scale }).catch(() => {});
    }, 350);
  });
}
void boot();
