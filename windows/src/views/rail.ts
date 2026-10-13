// The character rail (island design C) — port of CharacterRail.swift. The main character on top,
// then one per integration with its own character, each in its own colours and showing its
// task's state. Picking one shows its base.

import { h, clear, svg } from "./dom";
import { ICONS } from "./icons";
import { BotEngine } from "../mochi/engine";
import { PALETTES, tintedPalette } from "../mochi/critters";
import { State } from "../core/state";
import type { BotStateName } from "../core/layout";
import { assignedTaskIds, characterFor, characterName, characterTint } from "../core/characters";

// The engine draws the body 60 % of the canvas width; the rest is room for sprouts, steam,
// tentacles and hands, so the character is never cut off.
const CW = 40;
const CH = 40;

interface Item {
  taskId: string | null;
  button: HTMLButtonElement;
  canvas: HTMLCanvasElement;
  label: HTMLElement;
  engine: BotEngine;
}

export interface Rail {
  el: HTMLElement;
  sync(mainState: BotStateName): void;
  tick(dt: number): void;
}

const css = (c: readonly [number, number, number]) =>
  `rgb(${Math.round(c[0] * 255)}, ${Math.round(c[1] * 255)}, ${Math.round(c[2] * 255)})`;

/** The gear at the bottom of the rail opens the settings window. */
export interface RailTools {
  settings(): void;
}

export function buildRail(pick: (taskId: string | null) => void, tools: RailTools): Rail {
  const list = h("div", { class: "rail-list" });
  const gearBtn = h("button", { class: "rail-gear", title: "Settings", "aria-label": "Settings", onclick: () => tools.settings() },
    svg(ICONS.gear, 14));
  const el = h("div", { id: "rail" }, list, gearBtn);
  let items: Item[] = [];
  let ids = "";

  function make(taskId: string | null): Item {
    const canvas = h("canvas", {});
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    canvas.width = Math.round(CW * dpr);
    canvas.height = Math.round(CH * dpr);
    canvas.style.width = `${CW}px`;
    canvas.style.height = `${CH}px`;
    const label = h("span", { class: "rail-name" });
    const button = h("button", { class: "rail-item", onclick: () => pick(taskId) }, canvas, label) as HTMLButtonElement;
    const engine = new BotEngine();
    engine.setState("idle", true);
    return { taskId, button, canvas, label, engine };
  }

  return {
    el,
    sync(mainState: BotStateName) {
      const want = [null, ...assignedTaskIds()];
      const key = want.join("|");
      if (key !== ids) {
        ids = key;
        items = want.map(make);
        clear(list);
        for (const it of items) list.append(it.button);
      }
      for (const it of items) {
        const task = it.taskId ? State.tasks.find((t) => t.id === it.taskId) : null;
        const critter = characterFor(it.taskId);
        const tint = characterTint(it.taskId);
        it.engine.critter = critter;
        it.engine.userTint = tint;
        it.engine.setState(task?.state ?? mainState);
        const selected = State.soloTaskId === it.taskId;
        const pal = tint ? tintedPalette(critter, tint) : PALETTES[critter];
        it.button.classList.toggle("on", selected);
        it.button.style.setProperty("--ring", css(pal.top));
        it.button.classList.toggle("news", !selected && !!task?.pillBadge);
        // The same character twice: the label says which integration each one handles.
        const twice = items.filter((o) => characterFor(o.taskId) === critter).length > 1;
        it.label.textContent = twice ? task?.name ?? "Claude" : characterName(it.taskId);
        const label = `${characterName(it.taskId)} · ${task?.name ?? "Claude Code"}`;
        it.button.title = label;
        it.button.setAttribute("aria-label", label);
      }
    },
    tick(dt: number) {
      if (!el.isConnected || el.offsetParent === null) return;
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      for (const it of items) {
        const ctx = it.canvas.getContext("2d");
        if (!ctx) continue;
        it.engine.update(dt);
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.clearRect(0, 0, CW, CH);
        it.engine.draw(ctx, CW, CH);
      }
    },
  };
}
