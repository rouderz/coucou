// What an integration's character shows on its base when it has the island to itself (design C) —
// port of RailCharts.swift: a chart for WhaTicket, the repositories for GitHub.

import { h, clear } from "./dom";
import { Bridge } from "../core/bridge";
import { duration, range, summary, type StatEvent } from "../core/whaticketStats.ts";

let events: StatEvent[] = [];
let loadedAt = 0;
async function loadEvents(): Promise<StatEvent[]> {
  if (Date.now() - loadedAt < 30_000) return events;
  loadedAt = Date.now();
  events = (await Bridge.whaticketStats().catch(() => null)) ?? events;
  return events;
}

/** The last 12 hours as bars — arrived (soft) and accepted (bright) — that grow in when shown,
 *  with today's numbers beside them. */
export function whaticketChart(): HTMLElement {
  const stats = h("div", { class: "wt-stats" });
  const bars = h("div", { class: "wt-bars" });
  const labels = h("div", { class: "wt-labels" });
  const el = h("div", { class: "wt-chart" }, stats, h("div", { class: "wt-plot" }, bars, labels));
  const now = new Date().getHours();
  const hours = Array.from({ length: 12 }, (_, i) => (now - 11 + i + 24) % 24);
  const cols = hours.map((hr, i) => {
    const arrived = h("i", { class: "wt-arrived" });
    const accepted = h("i", { class: "wt-accepted" });
    const col = h("span", { class: "wt-col" }, arrived, accepted);
    col.style.transitionDelay = `${i * 25}ms`;
    arrived.style.transitionDelay = accepted.style.transitionDelay = `${i * 25}ms`;
    bars.append(col);
    labels.append(h("span", { text: i % 3 === 0 || i === 11 ? `${hr}h` : "" }));
    return { hr, col, arrived, accepted };
  });

  function stat(label: string, value: string, color: string) {
    return h("div", { class: "wt-stat" },
      h("i", { style: `background:${color}` }), h("span", { text: label }), h("b", { text: value }));
  }

  void loadEvents().then((list) => {
    const r = range("today", Date.now());
    const s = summary(list, r.from, r.to);
    clear(stats);
    stats.append(
      stat("Arrived", String(s.arrived), "#8E939C"),
      stat("Accepted", String(s.accepted), "#25D366"),
      stat("Avg wait", s.averageWait != null ? duration(s.averageWait) : "–", "#F5A524"),
    );
    const top = Math.max(1, ...hours.map((hr) => Math.max(s.hours[hr].arrived, s.hours[hr].accepted)));
    // Next frame, so the bars grow from the bottom.
    requestAnimationFrame(() => {
      for (const c of cols) {
        const a = s.hours[c.hr].arrived / top;
        const k = s.hours[c.hr].accepted / top;
        c.arrived.style.height = `${Math.max(2, 58 * a)}px`;
        c.accepted.style.height = `${k > 0 ? Math.max(3, 58 * k) : 0}px`;
        c.col.title = `${c.hr}:00 · ↓${s.hours[c.hr].arrived} ✓${s.hours[c.hr].accepted}`;
      }
    });
  });
  return el;
}

/** The repositories pushed to last (from the GitHub poll). */
export function githubRepos(list: Record<string, unknown>[]): HTMLElement {
  const el = h("div", { class: "gh-repos" });
  for (const r of list.slice(0, 5)) {
    const row = h("button", { class: "gh-repo", title: String(r.fullName ?? ""),
      onclick: () => void Bridge.openUrl(String(r.url ?? "")) },
      h("span", { class: "gh-icon", text: r.private ? "🔒" : "▤" }),
      h("b", { text: String(r.name ?? "") }));
    if (r.language) row.append(h("span", { class: "gh-lang", text: String(r.language) }));
    row.append(h("span", { class: "gh-spacer" }));
    if (Number(r.stars) > 0) row.append(h("span", { class: "gh-stars", text: `★ ${r.stars}` }));
    if (r.pushedAt) row.append(h("span", { class: "gh-ago", text: ago(String(r.pushedAt)) }));
    el.append(row);
  }
  return el;
}

function ago(iso: string): string {
  const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  if (s < 3600) return `${Math.max(1, Math.round(s / 60))} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} d ago`;
}
