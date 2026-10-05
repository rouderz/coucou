// Island views — DOM ports of IslandViewContent.swift. Paddings, font sizes,
// colours and wording are copied from the Swift views so both platforms read
// identically.

import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import { Ticker } from "./ticker";
import { State, type AgentTask } from "../core/state";
import { washRGBA, type IslandViewName, type Wash } from "../core/layout";
import { createMiniBot, pruneMiniBots } from "../mochi/minibots";
import { buildPrompt } from "./chat";
import { beginCapture, buildCapture } from "./capture";
import { buildChoose, buildUpload, buildUploading } from "./upload";
import { renderIntegrationCard, type IntegrationCardHooks } from "./integrations";
import { AUTO_LEVELS, levelFor, withLevel, type AutoLevel } from "../claude/autoApprove.ts";
import { clock, entries, icon, markdown, summary } from "../claude/timeline.ts";
import { focusSession } from "../claude/sessions.ts";
import type { EditPreview } from "../claude/preview.ts";
import { dndActive, dndStatus, FOREVER, tomorrowMorning } from "../core/dnd.ts";
import { Bridge } from "../core/bridge";
import { deleteChat, loadChats, openChat } from "../core/chats";

export interface ViewActions {
  setView(v: IslandViewName): void;
  collapse(): void;
  setFocus(id: string): void;
  openTerminal(): void;
  /** The ↗ button: opens whatever the focused pill points at. */
  openTarget(): void;
  openUrl(url: string): void;
  decide(d: "allow" | "deny"): void;
  /** Saves settings after a change made from the island (auto-approve…). */
  saveSettings(): void;
  /** Do not disturb until (ms), or null to turn it off. */
  setDnd(until: number | null): void;
  toggleSound(): void;
  setVolume(v: number): void;
  setAutoClose(seconds: number): void;
  openSettingsWindow(): void;
  blip(): void;
}

export interface ViewHost {
  el: HTMLElement;
  sync(): void;
  /** Called when the view becomes active, for views with a text field. */
  focus?(): void;
  /** Called every frame while the view is on screen. */
  tick?(nowMs: number): void;
}

// ── Shared pieces ─────────────────────────────────────────────────────────────

function card(wash: Wash, ...children: (Node | string)[]): HTMLElement {
  const el = h("div", { class: wash ? "card wash" : "card" }, ...children);
  if (wash) el.style.setProperty("--wash", washRGBA(wash));
  return el;
}

function btn(
  label: string,
  kind: "primary" | "secondary",
  onClick: () => void,
  kbd?: string,
): HTMLElement {
  return h(
    "button",
    { class: `btn ${kind}`, onclick: onClick },
    h("span", { text: label }),
    kbd ? h("span", { class: "kbd", text: kbd }) : null,
  );
}

/** AgentWho — coloured dot + task name + grey label. */
function agentWho(task: AgentTask | null, label: string): HTMLElement {
  const row = h("div", { class: "who-row" });
  if (task) {
    row.append(dot(task.color, 8), h("span", { class: "n", text: task.name }));
  }
  row.append(h("span", { text: label }));
  return row;
}

function stack(padLeft: number, padRight: number, ...children: Node[]): HTMLElement {
  const el = h("div", { class: "stack" }, ...children);
  el.style.padding = `4px ${padRight}px 4px ${padLeft}px`;
  return el;
}

// ── Header ────────────────────────────────────────────────────────────────────

export function buildHeader(actions: ViewActions): ViewHost {
  const tabHome = h("button", { class: "tab", title: "Overview", onclick: () => go("overview") }, svg(ICONS.house, 13));
  const tabChat = h("button", { class: "tab", title: "Ask", onclick: () => go("prompt") }, svg(ICONS.bubble, 13));
  const tabDrop = h("button", { class: "tab", title: "Drop", onclick: () => go("upload") }, svg(ICONS.plus, 13));

  const gearBtn = h("button", { title: "Settings", onclick: () => go("settings") }, svg(ICONS.gear, 14));
  // 🌙 Do not disturb: on → click turns it off; off → the choices (island settings).
  const dndBtn = h("button", {
    title: "Do not disturb",
    onclick: () => (dndActive(State.settings.dndUntil) ? actions.setDnd(null) : go("settings")),
  }, svg(ICONS.moon, 13));
  // 🔔 Inbox: GitHub / Linear notifications that need you.
  const inboxCount = h("span", { class: "badge-count" });
  const inboxBtn = h("button", { title: "Inbox", class: "inbox-btn", onclick: () => go("inbox") }, svg(ICONS.bell, 13), inboxCount);
  // ⬇ A newer Coucou is out.
  const updateBtn = h("button", {
    class: "update-btn",
    onclick: async () => {
      const u = State.update;
      if (!u || u.installing) return;
      if (!u.canInstall) {
        actions.openUrl(u.url);
        return;
      }
      // Updates itself: download, check the signature, install, restart.
      u.installing = true;
      State.notify();
      try {
        await Bridge.updateInstall();
      } catch (err) {
        u.installing = false;
        State.noteMessage = String(err).replace(/^Error:\s*/, "");
        actions.setView("note");
        State.notify();
      }
    },
  }, svg(ICONS.update, 13));
  const soundBtn = h("button", { title: "Mute", onclick: () => actions.toggleSound() }, svg(ICONS.speakerOn, 14));

  function go(v: IslandViewName) {
    actions.blip();
    actions.setView(v);
  }

  const el = h(
    "div",
    { id: "header" },
    h("div", { class: "tabs" }, tabHome, tabChat, tabDrop),
    h("div", { class: "header-actions" }, updateBtn, inboxBtn, dndBtn, gearBtn, soundBtn),
  );

  return {
    el,
    sync() {
      const v = State.view;
      tabHome.classList.toggle("on", v === "overview" || v === "empty");
      tabChat.classList.toggle("on", v === "prompt");
      tabDrop.classList.toggle("on", v === "upload");
      gearBtn.classList.toggle("on", v === "settings");
      clear(gearBtn);
      gearBtn.append(svg(v === "settings" ? ICONS.gearFill : ICONS.gear, 14));
      clear(soundBtn);
      soundBtn.append(svg(State.settings.soundEnabled ? ICONS.speakerOn : ICONS.speakerOff, 14));
      el.style.opacity = v === "confused" ? "0" : "1";
      const dnd = dndActive(State.settings.dndUntil);
      dndBtn.classList.toggle("on", dnd);
      dndBtn.title = dndStatus(State.settings.dndUntil) ?? "Do not disturb";
      inboxBtn.classList.toggle("on", v === "inbox");
      inboxBtn.style.display = State.settings.inboxEnabled ? "" : "none";
      inboxCount.textContent = State.inbox.length ? String(Math.min(99, State.inbox.length)) : "";
      inboxCount.style.display = State.inbox.length ? "" : "none";
      updateBtn.style.display = State.update ? "" : "none";
      const u = State.update;
      updateBtn.classList.toggle("busy", !!u?.installing);
      updateBtn.title = !u ? ""
        : u.installing ? "Updating…"
        : u.canInstall ? `Coucou ${u.latest} is out — install and restart`
        : `Coucou ${u.latest} is out — download`;
    },
  };
}

// ── Overview ──────────────────────────────────────────────────────────────────

function buildOverview(actions: ViewActions): ViewHost {
  const ticker = new Ticker();
  const who = h("div", { class: "who" });
  const chips = h("div", { class: "session-chips" });
  const usage = h("div", { class: "usage-row" });
  const tickerBody = h("div", { class: "card-body" }, who, chips, ticker.el, usage);
  const leftBody = h("div", { class: "left-body" });
  const jump = h(
    "button",
    { class: "icon-btn jump", title: "Open", onclick: () => actions.openTarget() },
    svg(ICONS.arrowUpRight, 8),
  );
  const left = card(null, leftBody, jump);
  const pills = h("div", { class: "pills" });
  const right = card(null, pills);

  const el = h("div", { class: "view overview" },
    h("div", { class: "left" }, left),
    h("div", { class: "right" }, right),
  );

  let pillIds = "";
  let detailOpen = false;
  let lastFocus: string | null = null;
  let mode: "ticker" | "card" | null = null;
  let cardKey = "";

  const hooks: IntegrationCardHooks = {
    get detailOpen() {
      return detailOpen;
    },
    openDetail() {
      detailOpen = true;
      cardKey = "";
      State.notify();
    },
    closeDetail() {
      detailOpen = false;
      cardKey = "";
      State.notify();
    },
    openSettings: () => actions.openSettingsWindow(),
    openCapture: () => {
      beginCapture();
      actions.setView("capture");
    },
  };

  return {
    el,
    tick(nowMs: number) {
      if (mode === "ticker") ticker.tick(nowMs);
    },
    sync() {
      const task = State.focusTask;
      if (task?.id !== lastFocus) {
        lastFocus = task?.id ?? null;
        detailOpen = false;
        cardKey = "";
        mode = null;
      }

      // VS Code with a live Claude Code session keeps the ticker; every other
      // pill shows its own card, exactly like IntegrationCardView.
      const sessionActive =
        task?.id === "integration_claude" && (task.state !== "idle" || task.steps.length > 0);

      if (task && sessionActive) {
        if (mode !== "ticker") {
          clear(leftBody);
          leftBody.append(tickerBody);
          mode = "ticker";
          cardKey = "";
        }
        clear(who);
        const agentName = State.sessions.find((s) => s.id === State.focusedSession)?.agent === "codex" ? "Codex" : "Claude Code";
        who.append(
          dot(task.color, 7),
          h("span", { class: "name", text: task.name }),
          h("span", { class: "tool", text: task.source === "claudeCode" ? agentName : "n8n" }),
          ...linearChip(),
          h("button", {
            class: "link-btn timeline-btn",
            title: "What this session did",
            text: "Timeline",
            onclick: () => actions.setView("timeline"),
          }),
        );
        syncSessionChips(chips);
        syncUsage(usage);
        if (task.steps.length > 1) {
          who.append(h("span", {
            class: "count",
            text: `${Math.min(task.stepIndex + 1, task.steps.length)}/${task.steps.length}`,
          }));
        }
        ticker.sync(task);
      } else if (task) {
        const info = State.integrations[task.id];
        const key = [
          task.id, detailOpen, task.state, task.steps.join("|"),
          info?.loaded, info?.error, info?.configured,
          JSON.stringify(info?.data ?? {}),
        ].join("~");
        if (key !== cardKey) {
          cardKey = key;
          mode = "card";
          clear(leftBody);
          leftBody.append(renderIntegrationCard(task, hooks));
        }
      }

      jump.style.display = detailOpen ? "none" : "";

      const others = State.visiblePills;
      const overflow = State.overflowPills;
      const pillKey = others.map((t) => `${t.id}:${t.pillBadge ?? ""}:${State.settings.pinnedPills?.includes(t.id) ? 1 : 0}`).join("|")
        + `+${overflow.map((t) => t.id).join(",")}`;
      if (pillKey !== pillIds) {
        pillIds = pillKey;
        clear(pills);
        for (const t of others) pills.append(buildPill(t, actions));
        if (overflow.length > 0) pills.append(buildMore(overflow, actions));
        pruneMiniBots();
      }
    },
  };
}

interface PillMenuItem { label: string; run: () => void }

function persistPills() {
  void Bridge.saveSettings(State.settings);
}

/** A small menu at the cursor; any click elsewhere (or Escape) closes it. */
function showPillMenu(x: number, y: number, items: PillMenuItem[]) {
  document.querySelector(".pill-menu")?.remove();
  const menu = h("div", { class: "pill-menu" });
  const close = () => {
    menu.remove();
    document.removeEventListener("pointerdown", onOutside, true);
    document.removeEventListener("keydown", onKey, true);
  };
  const onOutside = (e: Event) => { if (!menu.contains(e.target as Node)) close(); };
  const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") close(); };
  for (const item of items) {
    menu.append(h("button", { text: item.label, onclick: () => { close(); item.run(); } }));
  }
  document.body.append(menu);
  menu.style.left = `${Math.max(2, Math.min(x, window.innerWidth - menu.offsetWidth - 2))}px`;
  menu.style.top = `${Math.max(2, Math.min(y, window.innerHeight - menu.offsetHeight - 2))}px`;
  document.addEventListener("pointerdown", onOutside, true);
  document.addEventListener("keydown", onKey, true);
}

/** "+N": how many more are active; the menu brings one to the front. */
function buildMore(overflow: AgentTask[], actions: ViewActions): HTMLElement {
  return h("button", {
    class: "pills-more",
    text: `+${overflow.length}`,
    title: overflow.map((t) => t.name).join(", "),
    onclick: (e: Event) => {
      const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
      showPillMenu(r.left, r.top, overflow.map((t) => ({
        label: t.id === "integration_claude" ? "VS Code" : t.name,
        run: () => actions.setFocus(t.id),
      })));
    },
  });
}

function buildPill(task: AgentTask, actions: ViewActions): HTMLElement {
  const label = task.id === "integration_claude" ? "VS Code" : task.name;
  const canvas = createMiniBot(task, 24);
  const pill = h(
    "div",
    { class: "pill", onclick: () => actions.setFocus(task.id) },
    canvas,
    h("span", { class: "lbl", text: label }),
  );
  pill.style.borderColor = `${task.color}24`;
  pill.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    const pinned = State.settings.pinnedPills?.includes(task.id) ?? false;
    const items: PillMenuItem[] = [
      { label: pinned ? "Unpin" : "Pin (always visible)", run: () => { State.togglePinned(task.id); persistPills(); } },
    ];
    if (task.id !== "integration_claude") {
      items.push({ label: "Hide", run: () => { State.toggleIntegration(task.id); persistPills(); } });
    }
    showPillMenu(e.clientX, e.clientY, items);
  });
  pill.addEventListener("mouseenter", () => {
    pill.style.background = `${task.color}2e`;
    pill.style.borderColor = `${task.color}8c`;
    pill.style.boxShadow = `0 2px 10px ${task.color}59`;
    (pill.querySelector(".lbl") as HTMLElement).style.color = lighten(task.color, 0.3);
  });
  pill.addEventListener("mouseleave", () => {
    pill.style.background = "";
    pill.style.borderColor = `${task.color}24`;
    pill.style.boxShadow = "";
    (pill.querySelector(".lbl") as HTMLElement).style.color = "";
  });

  if (task.pillBadge) {
    const colors = { approval: "#F5A524", finished: "#22C55E", error: "#F4505E" } as const;
    const icons = { approval: ICONS.bang, finished: ICONS.check, error: ICONS.xmark } as const;
    const inner = h("i", { style: `background:${colors[task.pillBadge]}` }, svg(icons[task.pillBadge], 6, { stroke: task.pillBadge === "finished" ? 3 : 0 }));
    const badge = h("div", { class: "pill-badge" }, inner);
    badge.style.boxShadow = `0 0 4px ${colors[task.pillBadge]}99`;
    pill.append(badge);
  }
  return pill;
}

function lighten(hex: string, amount: number): string {
  const v = parseInt(hex.replace("#", ""), 16);
  const c = [(v >> 16) & 255, (v >> 8) & 255, v & 255].map((x) =>
    Math.min(255, Math.round(x + amount * 255)),
  );
  return `rgb(${c[0]},${c[1]},${c[2]})`;
}

// ── Empty ─────────────────────────────────────────────────────────────────────

function buildEmpty(actions: ViewActions): ViewHost {
  const body = h(
    "div",
    { class: "stack", style: "padding:0 18px 0 118px;flex-direction:row;align-items:center;gap:16px" },
    h(
      "div",
      { style: "display:flex;flex-direction:column;gap:5px" },
      h("div", { class: "title", text: "Nothing running right now." }),
      h("div", { class: "sub", text: "Drop a file or window, or ask me anything." }),
    ),
    h("div", { class: "grow" }),
    btn("Ask Claude", "primary", () => actions.setView("prompt")),
  );
  return { el: h("div", { class: "view" }, card(null, body)), sync() {} };
}

/** "SHO-123" next to the session's name when its branch names a Linear issue. */
function linearChip(): HTMLElement[] {
  const issue = State.sessions.find((s) => s.id === State.focusedSession)?.linear;
  if (!issue) return [];
  return [h("button", {
    class: "linear-chip",
    title: issue.title,
    text: issue.identifier,
    onclick: () => void Bridge.openUrl(issue.url),
  })];
}

// ── Review diff (the macOS live view) ─────────────────────────────────────────

function renderDiff(box: HTMLElement, preview: EditPreview) {
  clear(box);
  box.append(h("div", { class: "diff-file" },
    h("span", { class: "name", text: preview.fileName }),
    h("span", { class: "path", text: preview.file }),
    preview.note ? h("span", { class: "note", text: preview.note }) : null,
  ));
  const body = h("div", { class: "diff-body" });
  for (const line of preview.lines) {
    const sign = line.kind === "added" ? "+" : line.kind === "removed" ? "−" : " ";
    body.append(h("div", { class: `diff-line ${line.kind}` },
      h("span", { class: "sign", text: sign }), h("span", { text: line.text || " " })));
  }
  box.append(body);
}

// ── Plan usage bars ───────────────────────────────────────────────────────────

let usageKey = "";
function syncUsage(row: HTMLElement) {
  const u = State.planUsage;
  const key = JSON.stringify(u);
  if (key === usageKey) return;
  usageKey = key;
  clear(row);
  const bars: [string, number][] = [];
  if (u?.fiveHour) bars.push(["5h", u.fiveHour.percent]);
  if (u?.sevenDay) bars.push(["7d", u.sevenDay.percent]);
  if (u?.context != null) bars.push(["ctx", u.context]);
  row.style.display = bars.length ? "" : "none";
  for (const [label, pct] of bars) {
    const color = pct >= 90 ? "#F4505E" : pct >= 70 ? "#F5A524" : "#4C8DFF";
    const fill = h("i", { class: "fill" });
    fill.style.width = `${Math.max(2, Math.min(100, pct))}%`;
    fill.style.background = color;
    row.append(h("span", { class: "usage" },
      h("span", { class: "label", text: label }), h("span", { class: "bar" }, fill),
      h("span", { class: "pct", text: `${Math.round(pct)}%` })));
  }
}

// ── Sessions (#24 on macOS) ───────────────────────────────────────────────────

const STATE_COLORS: Record<string, string> = {
  working: "#4C8DFF", searching: "#4C8DFF", thinking: "#A78BFA", approval: "#F5A524", question: "#F5A524",
  error: "#F4505E", ratelimit: "#F4505E", finished: "#22C55E",
};

let chipKey = "";
function syncSessionChips(row: HTMLElement) {
  const list = State.sessions;
  const key = list.map((s) => `${s.id}:${s.state}:${s.unseen}:${s.project}:${s.agent}`).join("|") + `@${State.focusedSession}`;
  if (key === chipKey) return;
  chipKey = key;
  clear(row);
  row.style.display = list.length > 1 ? "" : "none";
  if (list.length < 2) return;
  for (const s of list) {
    const focused = s.id === State.focusedSession;
    const chip = h("button", {
      class: focused ? "session-chip on" : "session-chip",
      title: s.cwd,
      onclick: () => focusSession(s.id),
    }, dot(STATE_COLORS[s.state] ?? "#6B7079", 6));
    if (s.agent === "codex") chip.append(h("span", { class: "agent", text: "Codex" }));
    chip.append(h("span", { text: s.project }));
    if (s.unseen && !focused) chip.append(h("i", { class: "unseen" }));
    row.append(chip);
  }
}

// ── Chat history ──────────────────────────────────────────────────────────────

function buildHistory(actions: ViewActions): ViewHost {
  const list = h("div", { class: "tl-list" });
  const back = h("button", { class: "btn secondary", text: "Back", onclick: () => actions.setView("prompt") });
  const el = h("div", { class: "view" }, card(null, h("div", { class: "tl" },
    h("div", { class: "tl-head" }, h("div", { class: "tl-title", text: "Chats" }), h("div", { class: "actions" }, back)),
    list,
  )));
  let key = "";
  void loadChats();
  return {
    el,
    sync() {
      const k = State.chats.map((c) => `${c.id}:${c.updatedAt}`).join("|");
      if (k === key) return;
      key = k;
      clear(list);
      for (const chat of State.chats) {
        const when = new Date(chat.updatedAt);
        const stamp = when.toDateString() === new Date().toDateString()
          ? when.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })
          : when.toLocaleDateString(undefined, { day: "2-digit", month: "short" });
        list.append(h("div", { class: "inbox-row" },
          h("span", { class: "tl-time", text: stamp }),
          h("button", {
            class: "inbox-open",
            onclick: () => { openChat(chat); actions.setView("prompt"); },
          }, h("span", { class: "title", text: chat.title }),
            h("span", { class: "sub", text: `${chat.messages.length} messages` })),
          h("button", { class: "inbox-x", title: "Delete", text: "✕", onclick: () => void deleteChat(chat) }),
        ));
      }
      if (!State.chats.length) list.append(h("div", { class: "tl-empty", text: "No saved chats yet." }));
    },
  };
}

// ── Inbox ─────────────────────────────────────────────────────────────────────

const KIND_LABELS: Record<string, string> = {
  review: "Review requested", mention: "Mentioned you", assigned: "Assignment", comment: "New comment", other: "Update",
};

function buildInbox(actions: ViewActions): ViewHost {
  const sub = h("div", { class: "tl-sub" });
  const list = h("div", { class: "tl-list" });
  const clearAll = h("button", {
    class: "btn secondary",
    text: "Dismiss all",
    onclick: () => {
      for (const item of State.inbox) void Bridge.inboxDismiss(item.id);
      State.inbox = [];
      State.notify();
    },
  });
  const el = h("div", { class: "view" }, card(null, h("div", { class: "tl" },
    h("div", { class: "tl-head" }, h("div", {}, h("div", { class: "tl-title", text: "Inbox" }), sub),
      h("div", { class: "actions" }, clearAll)),
    list,
  )));
  let key = "";
  return {
    el,
    sync() {
      const items = State.inbox;
      const k = items.map((i) => i.id).join("|");
      if (k === key) return;
      key = k;
      sub.textContent = items.length ? `${items.length} need${items.length === 1 ? "s" : ""} you` : "All caught up";
      clearAll.style.display = items.length ? "" : "none";
      clear(list);
      for (const item of items.slice(0, 30)) {
        const open = () => {
          actions.openUrl(item.url);
          void Bridge.inboxDismiss(item.id);
          State.inbox = State.inbox.filter((i) => i.id !== item.id);
          State.notify();
        };
        list.append(h("div", { class: "inbox-row" },
          h("span", { class: `inbox-source ${item.source}`, text: item.source === "github" ? "GitHub" : "Linear" }),
          h("button", { class: "inbox-open", onclick: open, title: item.url },
            h("span", { class: "kind", text: KIND_LABELS[item.kind] ?? "Update" }),
            h("span", { class: "title", text: item.title }),
            h("span", { class: "sub", text: item.actor ? `${item.subtitle} · ${item.actor}` : item.subtitle }),
          ),
          h("button", {
            class: "inbox-x", title: "Dismiss", text: "✕",
            onclick: () => {
              void Bridge.inboxDismiss(item.id);
              State.inbox = State.inbox.filter((i) => i.id !== item.id);
              State.notify();
            },
          }),
        ));
      }
      if (!items.length) list.append(h("div", { class: "tl-empty", text: "Nothing needs you on GitHub or Linear." }));
    },
  };
}

// ── Timeline (#22 on macOS) ───────────────────────────────────────────────────

function buildTimeline(actions: ViewActions): ViewHost {
  const title = h("div", { class: "tl-title" });
  const sub = h("div", { class: "tl-sub" });
  const list = h("div", { class: "tl-list" });
  const copyBtn = h("button", { class: "btn secondary", text: "Copy as Markdown" });
  // Post the timeline on the session's Linear issue (#27 on macOS) — only from this click.
  const linearBtn = h("button", { class: "btn secondary" });
  linearBtn.addEventListener("click", async () => {
    const s = State.sessions.find((x) => x.id === State.focusedSession);
    if (!s?.linear) return;
    linearBtn.textContent = "Posting…";
    try {
      await Bridge.linearComment(s.linear.id, markdown(s.id, s.project));
      linearBtn.textContent = `Posted on ${s.linear.identifier} ✓`;
      actions.blip();
    } catch (err) {
      linearBtn.textContent = String(err).replace(/^Error:\s*/, "").slice(0, 40);
    }
    window.setTimeout(() => (linearBtn.textContent = `Post to ${s.linear?.identifier ?? "Linear"}`), 2500);
  });
  const back = h("button", { class: "btn secondary", text: "Back", onclick: () => actions.setView("overview") });
  const el = h("div", { class: "view" }, card(null, h("div", { class: "tl" },
    h("div", { class: "tl-head" }, h("div", {}, title, sub), h("div", { class: "actions" }, back, linearBtn, copyBtn)),
    list,
  )));
  let key = "";
  copyBtn.addEventListener("click", async () => {
    const id = State.focusedSession ?? "";
    const text = markdown(id, State.focusTask?.name ?? "Session");
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      const area = h("textarea", { style: "position:fixed;opacity:0" }) as HTMLTextAreaElement;
      area.value = text;
      document.body.append(area);
      area.select();
      document.execCommand("copy");
      area.remove();
    }
    copyBtn.textContent = "Copied ✓";
    actions.blip();
    window.setTimeout(() => (copyBtn.textContent = "Copy as Markdown"), 1600);
  });
  return {
    el,
    sync() {
      const id = State.focusedSession ?? "";
      const items = entries(id);
      const issue = State.sessions.find((x) => x.id === id)?.linear;
      linearBtn.style.display = issue ? "" : "none";
      if (issue && !linearBtn.textContent?.includes("…") && !linearBtn.textContent?.includes("✓")) {
        linearBtn.textContent = `Post to ${issue.identifier}`;
      }
      const k = `${id}:${items.length}`;
      if (k === key) return;
      key = k;
      title.textContent = State.focusTask?.name ?? "Session";
      sub.textContent = id ? summary(id) : "No session yet";
      clear(list);
      for (const e of items.slice(-80)) {
        list.append(h("div", { class: `tl-row ${e.kind}` },
          h("span", { class: "tl-time", text: clock(e.at) }),
          h("span", { class: "tl-icon", text: icon(e.kind) }),
          h("span", { class: "tl-text", text: e.text }),
        ));
      }
      if (!items.length) list.append(h("div", { class: "tl-empty", text: "Nothing recorded yet." }));
      list.scrollTop = list.scrollHeight;
    },
  };
}

// ── Approval ──────────────────────────────────────────────────────────────────

const RISK_COLORS = { low: "#22C55E", medium: "#F5A524", high: "#F4505E" } as const;
const RISK_TITLES = { low: "Low risk", medium: "Medium risk", high: "High risk" } as const;

/** "● High risk · deletes files recursively" (#21 on macOS). */
function riskChip(risk: "low" | "medium" | "high", reason: string): HTMLElement {
  const chip = h("span", { class: "risk-chip", title: reason },
    dot(RISK_COLORS[risk], 6), h("span", { text: `${RISK_TITLES[risk]} · ${reason}` }));
  chip.style.setProperty("--risk", RISK_COLORS[risk]);
  return chip;
}

function buildApproval(actions: ViewActions, withDiff = false): ViewHost {
  const who = h("div");
  const code = h("div", { class: "code" });
  const row = h("div", { class: "actions" });
  const auto = h("div", { class: "auto-row" });
  const diff = h("div", { class: "diff" });
  const el = withDiff
    ? h("div", { class: "view" }, card("amber", h("div", { class: "review" }, who, code, diff, row, auto)))
    : h("div", { class: "view" }, card("amber", stack(116, 16, who, code, row, auto)));
  let rowKey = "";
  let autoKey = "";
  let diffKey = "";
  return {
    el,
    sync() {
      const a = State.pendingApproval;
      clear(who);
      who.append(agentWho(State.focusTask, a?.agent === "codex" ? "· Codex needs permission" : "needs permission"));
      if (a) who.append(riskChip(a.risk, a.riskReason));
      if (withDiff && a?.preview && diffKey !== a.requestId) {
        diffKey = a.requestId;
        renderDiff(diff, a.preview);
      }
      if (State.approvalQueue.length) {
        who.append(h("span", { class: "queue", text: `+${State.approvalQueue.length} waiting` }));
      }
      // Auto-approve this project from here (#29 on macOS). High risk always asks.
      const level = a?.cwd ? levelFor(State.settings.autoApprove ?? {}, a.cwd) : "ask";
      const key = `${a?.cwd ?? ""}|${level}`;
      if (key !== autoKey) {
        autoKey = key;
        clear(auto);
        if (a?.cwd) {
          auto.append(h("span", { class: "auto-label", text: `Auto-approve in ${a.project}:` }));
          for (const opt of AUTO_LEVELS) {
            auto.append(h("button", {
              class: opt.id === level ? "auto-opt on" : "auto-opt",
              text: opt.label,
              title: opt.id === "ask" ? "Ask every time" : "Answered at once and logged in the timeline. High risk always asks.",
              onclick: () => {
                State.settings.autoApprove = withLevel(State.settings.autoApprove ?? {}, a.cwd, opt.id as AutoLevel);
                actions.saveSettings();
                State.notify();
              },
            }));
          }
        }
      }
      // The whole point of approving here rather than in the terminal: this line
      // is the command, the file path or the URL being authorised, not just the
      // name of the tool asking.
      code.textContent = State.pendingApproval?.command || State.pendingApproval?.tool || "…";
      // Two buttons, built once. Rebuilding them between a mouse-down and a
      // mouse-up would swallow the click, and there is nothing left to vary:
      // "Always" is gone until the remembered-rules list exists to back it.
      if (rowKey === "built") return;
      rowKey = "built";
      clear(row);
      row.append(
        btn("Deny", "secondary", () => actions.decide("deny"), "N"),
        btn("Allow", "primary", () => actions.decide("allow"), "Y"),
      );
    },
  };
}

// ── Question ──────────────────────────────────────────────────────────────────

function buildQuestion(): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title" });
  const row = h("div", { class: "actions" });
  const el = h("div", { class: "view" }, card("cyan", stack(116, 16, who, title, row)));
  return {
    el,
    sync() {
      clear(who);
      who.append(agentWho(State.focusTask, "Claude Code is asking a question"));
      const task = State.focusTask;
      title.textContent = task?.steps.at(-1) ?? "Claude needs an answer.";
      clear(row);
      row.append(h("div", { class: "sub", text: "Answer in your terminal — Coucou can't reply for you yet." }));
    },
  };
}

// ── Error ─────────────────────────────────────────────────────────────────────

function buildError(actions: ViewActions): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title", text: "Workflow stopped." });
  const detail = h("div", { class: "detail" });
  const row = h("div", { class: "actions" },
    btn("Retry", "primary", () => actions.setView(State.defaultView())),
    btn("Open in n8n", "secondary", () => actions.openUrl("")),
  );
  const el = h("div", { class: "view" }, card("red", stack(116, 16, who, title, detail, row)));
  return {
    el,
    sync() {
      const task = State.focusTask;
      clear(who);
      who.append(agentWho(task, task?.source === "n8n" ? "n8n" : "Claude Code"));
      title.textContent = task?.source === "n8n" ? "Workflow stopped." : "Session stopped on an error.";
      detail.textContent = task?.steps.at(-1) ?? "No detail available.";
    },
  };
}

// ── Finished ──────────────────────────────────────────────────────────────────

function buildFinished(actions: ViewActions): ViewHost {
  const who = h("div");
  const title = h("div", { class: "title" });
  const row = h("div", { class: "actions" },
    btn("Open terminal", "primary", () => actions.openTerminal()),
    btn("OK", "secondary", () => actions.collapse()),
  );
  const el = h("div", { class: "view" }, card("green", stack(116, 16, who, title, row)));
  return {
    el,
    sync() {
      clear(who);
      who.append(agentWho(State.focusTask, "Claude Code finished"));
      title.textContent = State.focusTask?.steps.at(-1) ?? "Session finished";
    },
  };
}

// ── Confused ──────────────────────────────────────────────────────────────────

function buildConfused(): ViewHost {
  const body = h(
    "div",
    { class: "stack", style: "padding:0 18px 0 128px" },
    h("div", { class: "title", text: "Too many hits at once." }),
    h("div", { class: "sub", text: "Give me a sec — back to work in three seconds." }),
  );
  return { el: h("div", { class: "view" }, card("pink", body)), sync() {} };
}

// ── Note ──────────────────────────────────────────────────────────────────────

function buildNote(): ViewHost {
  const title = h("div", { class: "title" });
  const el = h("div", { class: "view" }, card(null, h("div", { class: "stack", style: "padding:0 18px 0 98px" }, title)));
  return {
    el,
    sync() {
      title.textContent = State.noteMessage ?? "";
    },
  };
}

// ── In-island settings ────────────────────────────────────────────────────────

function buildSettings(actions: ViewActions): ViewHost {
  const soundSwitch = h("button", { class: "switch", onclick: () => actions.toggleSound() });
  const volume = h("input", {
    type: "range", min: "0", max: "0.2", step: "0.005",
    oninput: (e: Event) => actions.setVolume(Number((e.target as HTMLInputElement).value)),
  }) as HTMLInputElement;
  const autoLabel = h("span", {});
  const segButtons = [10, 15, 30].map((s) =>
    h("button", { onclick: () => actions.setAutoClose(s) }, `${s}s`),
  );
  const claudeBadge = h("span", { class: "status-badge" });
  const apiBadge = h("span", { class: "status-badge" });
  const dndLabel = h("span", {});
  const dndChoices: [string, (() => number) | null][] = [
    ["Off", null],
    ["1 h", () => Date.now() + 60 * 60_000],
    ["Until 9:00", () => tomorrowMorning()],
    ["On", () => FOREVER],
  ];
  const dndButtons = dndChoices.map(([label, until]) =>
    h("button", { onclick: () => actions.setDnd(until ? until() : null) }, label),
  );

  const rows = h(
    "div",
    { class: "settings-rows" },
    h("div", { class: "settings-row" }, soundSwitch, h("span", { text: "Sound" }), volume),
    h(
      "div",
      { class: "settings-row" },
      svg(ICONS.timer, 12),
      autoLabel,
      h("div", { class: "seg" }, ...segButtons),
    ),
    h("div", { class: "settings-row" }, svg(ICONS.moon, 12), dndLabel, h("div", { class: "seg" }, ...dndButtons)),
    h(
      "div",
      { class: "settings-row", style: "gap:14px" },
      claudeBadge,
      apiBadge,
      h("div", { class: "grow" }),
      h("button", {
        class: "link-btn",
        style: "color:#8e939c;font-size:11.5px",
        text: "Settings…",
        onclick: () => actions.openSettingsWindow(),
      }),
    ),
  );

  const el = h("div", { class: "view" },
    card(null, h("div", { class: "stack", style: "padding:14px 16px 14px 84px" }, rows)));

  return {
    el,
    sync() {
      const s = State.settings;
      soundSwitch.classList.toggle("on", s.soundEnabled);
      volume.value = String(s.soundVolume);
      volume.style.opacity = s.soundEnabled ? "1" : "0.4";
      autoLabel.textContent = `Auto-close · ${Math.round(s.autoCloseInterval)}s`;
      const status = dndStatus(s.dndUntil);
      dndLabel.textContent = status ? `Do not disturb · ${status.replace(/^On /, "")}` : "Do not disturb";
      const until = s.dndUntil;
      const forever = dndActive(until) && (until as number) >= FOREVER;
      dndButtons[0].classList.toggle("on", !dndActive(until));
      dndButtons[3].classList.toggle("on", forever);
      segButtons.forEach((b, i) => b.classList.toggle("on", s.autoCloseInterval === [10, 15, 30][i]));
      clear(claudeBadge);
      claudeBadge.append(
        dot(s.hooksInstalled ? "#22C55E" : "#F4505E", 6),
        h("span", { text: "Claude Code" }),
      );
      clear(apiBadge);
      apiBadge.append(dot("#F4505E", 6), h("span", { text: "API" }));
    },
  };
}

// ── Placeholders filled in later stages ───────────────────────────────────────

function buildPlaceholder(title: string, sub: string): ViewHost {
  const body = h(
    "div",
    { class: "stack", style: "padding:0 18px 0 118px" },
    h("div", { class: "title", text: title }),
    h("div", { class: "sub", text: sub }),
  );
  return { el: h("div", { class: "view" }, card(null, body)), sync() {} };
}

// ── Registry ──────────────────────────────────────────────────────────────────

export function buildViews(
  actions: ViewActions,
  onChatHeightChange: () => void,
): Map<IslandViewName, ViewHost> {
  const map = new Map<IslandViewName, ViewHost>();
  map.set("overview", buildOverview(actions));
  map.set("empty", buildEmpty(actions));
  map.set("approval", buildApproval(actions));
  map.set("review", buildApproval(actions, true));
  map.set("question", buildQuestion());
  map.set("error", buildError(actions));
  map.set("finished", buildFinished(actions));
  map.set("confused", buildConfused());
  map.set("note", buildNote());
  map.set("settings", buildSettings(actions));
  map.set("timeline", buildTimeline(actions));
  map.set("inbox", buildInbox(actions));
  map.set("prompt", buildPrompt(onChatHeightChange, () => actions.setView("history"), () => actions.setView("capture")));
  map.set("capture", buildCapture(actions));
  map.set("history", buildHistory(actions));
  map.set("upload", buildUpload());
  map.set("uploading", buildUploading());
  map.set("choose", buildChoose(actions));
  // Not in the Windows v1: sending a file by email, window attach + web result.
  map.set("mail", buildPlaceholder("Sending by email isn't in this version.", ""));
  map.set("searching", buildPlaceholder("Claude is searching…", ""));
  map.set("result", buildPlaceholder("Result", ""));
  return map;
}
