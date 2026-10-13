// The character rail (island design C) — port of CharacterRail.swift. The main character on top,
// then one per integration with its own character, each in its own colours and showing its
// task's state. Picking one shows its base.

import { h, clear } from "./dom";
import { BotEngine } from "../mochi/engine";
import { PALETTES, tintedPalette } from "../mochi/critters";
import { State } from "../core/state";
import type { BotStateName } from "../core/layout";
import { assignedTaskIds, characterFor, characterName } from "../core/characters";

const BODY = 25;              // the character's body, CSS px
const CANVAS = BODY / 0.6;    // the engine draws the body at 60 % of its canvas

interface Item {
  taskId: string | null;
  button: HTMLButtonElement;
  canvas: HTMLCanvasElement;
  engine: BotEngine;
}

export interface Rail {
  el: HTMLElement;
  sync(mainState: BotStateName): void;
  tick(dt: number): void;
}

const css = (c: readonly [number, number, number]) =>
  `rgb(${Math.round(c[0] * 255)}, ${Math.round(c[1] * 255)}, ${Math.round(c[2] * 255)})`;

export function buildRail(pick: (taskId: string | null) => void): Rail {
  const el = h("div", { id: "rail" });
  let items: Item[] = [];
  let ids = "";

  function make(taskId: string | null): Item {
    const canvas = h("canvas", {});
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    canvas.width = Math.round(CANVAS * dpr);
    canvas.height = Math.round(CANVAS * dpr);
    canvas.style.width = `${CANVAS}px`;
    canvas.style.height = `${CANVAS}px`;
    const button = h("button", { class: "rail-item", onclick: () => pick(taskId) }, canvas) as HTMLButtonElement;
    const engine = new BotEngine();
    engine.isMini = true;
    engine.setState("idle", true);
    return { taskId, button, canvas, engine };
  }

  return {
    el,
    sync(mainState: BotStateName) {
      const want = [null, ...assignedTaskIds()];
      const key = want.join("|");
      if (key !== ids) {
        ids = key;
        items = want.map(make);
        clear(el);
        for (const it of items) el.append(it.button);
      }
      const own = State.settings.critterColors ?? {};
      for (const it of items) {
        const task = it.taskId ? State.tasks.find((t) => t.id === it.taskId) : null;
        const critter = characterFor(it.taskId);
        const tint = it.taskId ? own[it.taskId] ?? null : null;
        it.engine.critter = critter;
        it.engine.userTint = tint;
        it.engine.setState(task?.state ?? mainState);
        const selected = State.soloTaskId === it.taskId;
        const pal = tint ? tintedPalette(critter, tint) : PALETTES[critter];
        it.button.classList.toggle("on", selected);
        it.button.style.setProperty("--ring", css(pal.top));
        it.button.classList.toggle("news", !selected && !!task?.pillBadge);
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
        ctx.clearRect(0, 0, CANVAS, CANVAS);
        it.engine.draw(ctx, CANVAS, CANVAS);
      }
    },
  };
}
