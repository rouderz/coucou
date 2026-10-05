// Integration cards shown in the overview's left card — DOM ports of
// IntegrationCardView and friends from IslandViewContent.swift.
//
// Cal.com is the one simplification: macOS shows a three-level calendar
// (month → day → booking); here it is the list of upcoming bookings.

import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import { State, type AgentTask } from "../core/state";
import { startNewChat } from "../core/chats";
import { Bridge } from "../core/bridge";
import { todayLine } from "../core/whaticketStats.ts";
import { CI_ID, ciLogFile, ciRerunFailed, refreshCI, type CIPr } from "../core/ciPoller";
import { checkState, durationSeconds, formatDuration, parseJobUrl, type CheckRun, type CheckState, type PillState, type PrState } from "../core/ci.ts";

/** Same shape as the Swift `timeAgo` computed properties. */
export function timeAgo(value: unknown): string {
  const date = typeof value === "number" ? new Date(value) : new Date(String(value));
  const diff = (Date.now() - date.getTime()) / 1000;
  if (!Number.isFinite(diff)) return "";
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h`;
  return `${Math.floor(diff / 86400)}d`;
}

function header(color: string, name: string, kind: string, extra?: Node): HTMLElement {
  const row = h("div", { class: "int-head" }, dot(color, 7), h("b", { text: name }), h("span", { text: kind }));
  if (extra) row.append(extra);
  return row;
}

/** Highlighted first row + plain rows, the layout every list card shares. */
function listRow(accent: string, first: boolean, ...children: Node[]): HTMLElement {
  const row = h("div", { class: first ? "int-row first" : "int-row" }, dot(accent, 5), ...children);
  if (first) row.style.background = `${accent}14`;
  return row;
}

function get(id: string): Record<string, unknown> {
  return (State.integrations[id]?.data ?? {}) as Record<string, unknown>;
}

function arr(id: string, key: string): Record<string, unknown>[] {
  const v = get(id)[key];
  return Array.isArray(v) ? (v as Record<string, unknown>[]) : [];
}

// ── Not configured / idle ─────────────────────────────────────────────────────

const OPEN_URLS: Record<string, string> = {
  integration_resend: "https://resend.com/emails",
  integration_vercel: "https://vercel.com/dashboard",
  integration_github: "https://github.com",
  integration_stripe: "https://dashboard.stripe.com/payments",
  integration_notion: "https://notion.so",
  integration_calcom: "https://app.cal.com/bookings",
  integration_whaticket: "https://app.whaticket.com/tickets",
  integration_ci: "https://github.com/pulls",
};

function idleCard(task: AgentTask, openSettings: () => void): HTMLElement {
  const info = State.integrations[task.id];
  const configured = info?.configured ?? false;
  const error = info?.error ?? null;
  // The Claude Code pill is about hooks, not a key — the macOS wording would be
  // misleading here.
  const missing = task.id === "integration_claude" ? "Hooks not installed"
    : task.id === "integration_whaticket" ? "Browser extension not set up" : "Key not configured";
  const waiting = task.id === "integration_whaticket" ? "Open whaticket.com in Chrome or Edge" : "Connected · loading…";
  const label = error ?? (configured ? waiting : missing);
  const statusColor = error || !configured ? "#F4505E" : "#22C55E";

  const actions = h("div", { class: "int-actions" });
  if (task.id === "integration_claude") {
    actions.append(
      h("button", {
        class: "link-btn",
        style: `color:${task.color}b3`,
        text: "Open Visual Studio Code",
        onclick: () => void Bridge.openInVSCode(task.sessionCwd ?? null),
      }),
    );
  } else if (task.id === "integration_n8n") {
    actions.append(
      h("button", {
        class: "link-btn",
        style: `color:${task.color}d9`,
        text: "Open n8n",
        onclick: () => void Bridge.openN8n(),
      }),
    );
  } else if (OPEN_URLS[task.id]) {
    actions.append(
      h("button", {
        class: "link-btn",
        style: `color:${task.color}d9`,
        text: `Open ${task.name}`,
        onclick: () => void Bridge.openUrl(OPEN_URLS[task.id]),
      }),
    );
  }
  // WhaTicket refreshes when the browser tab checks in; there is nothing to poll.
  if (configured && task.id !== "integration_whaticket") {
    actions.append(
      h("button", {
        class: "link-btn",
        style: `color:${task.color}d9`,
        text: "Refresh",
        // The CI pill is polled by the page (core/ciPoller.ts), not by Rust.
        onclick: () => (task.id === CI_ID ? refreshCI() : void Bridge.refreshIntegration(task.id)),
      }),
    );
  } else if (!configured) {
    actions.append(
      h("button", { class: "link-btn", style: "color:#8e939c", text: "Settings…", onclick: openSettings }),
    );
  }

  return h(
    "div",
    { class: "int-card" },
    header(task.color, task.id === "integration_claude" ? "VS Code" : task.name, "Integration"),
    h("div", { class: "int-status" }, dot(statusColor, 5), h("span", { text: label })),
    actions,
  );
}

// ── Vercel ────────────────────────────────────────────────────────────────────

function vercelCard(onDetail: () => void): HTMLElement {
  const deployments = arr("integration_vercel", "deployments");
  const rows = h("div", { class: "int-rows" });
  deployments.slice(0, 3).forEach((d, i) => {
    const accent = d.state === "READY" ? "#22C55E" : "#F4505E";
    const name = h("span", { class: "int-name", text: String(d.projectName ?? "") });
    const ago = h("span", { class: "int-ago", text: timeAgo(d.createdAt) });
    if (i === 0) {
      const more = h(
        "button",
        { class: "int-more", title: "Details", onclick: onDetail },
        svg(ICONS.ellipsis, 8),
      );
      rows.append(listRow(accent, true, name, ago, more));
    } else {
      rows.append(listRow(accent, false, name, ago));
    }
  });
  return h("div", { class: "int-card" }, header("#7C5CFF", "Vercel", "Deployments"), rows);
}

function vercelDetail(onBack: () => void): HTMLElement {
  const d = arr("integration_vercel", "deployments")[0] ?? {};
  const success = d.state === "READY";
  const accent = success ? "#22C55E" : "#F4505E";
  const status = success ? "Ready" : d.state === "CANCELED" ? "Canceled" : "Error";
  const body = h("div", { class: "int-detail-body" });
  if (d.commitMessage) body.append(h("div", { class: "int-commit", text: String(d.commitMessage) }));
  const meta = h("div", { class: "int-meta" });
  if (d.branch) meta.append(h("span", { text: String(d.branch) }));
  meta.append(h("span", { text: `${timeAgo(d.createdAt)} ago` }));
  body.append(meta);
  if (d.url) {
    body.append(
      h("button", {
        class: "int-link",
        text: String(d.url),
        onclick: () => void Bridge.openUrl(`https://${d.url}`),
      }),
    );
  }
  return h(
    "div",
    { class: "int-card detail" },
    h(
      "div",
      { class: "int-detail-head" },
      h("button", { class: "int-back", onclick: onBack }, svg(ICONS.chevronLeft, 10, { stroke: 2.4 })),
      dot(accent, 6),
      h("b", { text: String(d.projectName ?? "Deployment") }),
      h("span", { class: "int-badge", style: `color:${accent};background:${accent}24`, text: status }),
    ),
    body,
  );
}

// ── Resend ────────────────────────────────────────────────────────────────────

function resendCard(): HTMLElement {
  const emails = arr("integration_resend", "emails");
  const total = get("integration_resend").total;
  const extra =
    total != null
      ? h("span", { class: "int-total" }, h("i", { class: "pulse" }), h("span", { text: String(total) }))
      : undefined;
  const rows = h("div", { class: "int-rows" });
  emails.slice(0, 3).forEach((e, i) => {
    const delivered = e.lastEvent === "delivered";
    const accent = delivered ? "#22C55E" : "#F4505E";
    const to = Array.isArray(e.to) ? String(e.to[0] ?? "?") : "?";
    const short = to.split("@")[0];
    const cells: Node[] = [
      h("span", { class: "int-name", text: short }),
      h("span", { class: "int-ago", text: timeAgo(e.createdAt) }),
    ];
    if (i === 0 && e.subject) cells.push(h("span", { class: "int-sub", text: String(e.subject) }));
    rows.append(listRow(accent, i === 0, ...cells));
  });
  return h("div", { class: "int-card" }, header("#22C55E", "Resend", "Emails", extra), rows);
}

// ── GitHub ────────────────────────────────────────────────────────────────────

function statRow(icon: string, color: string, label: string, value: string): HTMLElement {
  return h(
    "div",
    { class: "int-stat" },
    h("i", { class: "int-stat-icon", style: `color:${color}` }, svg(icon, 10)),
    h("span", { class: "int-stat-label", text: label }),
    h("span", { class: "int-stat-value", text: value }),
  );
}

function githubCard(): HTMLElement {
  const d = get("integration_github");
  const stars = Number(d.totalStars ?? 0);
  const repos = Number(d.totalRepos ?? 0);
  const fmt = (n: number) => (n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n));
  return h(
    "div",
    { class: "int-card" },
    header("#F4505E", "GitHub", "Overview"),
    h(
      "div",
      { class: "int-stats" },
      statRow(ICONS.star, "#F5A524", "Total stars", fmt(stars)),
      statRow(ICONS.stack, "#6B7079", "Repositories", String(repos)),
    ),
  );
}

// ── Stripe ────────────────────────────────────────────────────────────────────

function stripeCard(): HTMLElement {
  const d = get("integration_stripe");
  const balance = (Number(d.balance ?? 0) / 100).toFixed(2);
  const currency = String(d.currency ?? "eur").toUpperCase();
  const rows = h("div", { class: "int-rows tight" });
  for (const p of arr("integration_stripe", "payments")) {
    const success = p.status === "succeeded";
    const accent = success ? "#22C55E" : "#F4505E";
    rows.append(
      h(
        "div",
        { class: "int-row" },
        dot(accent, 5),
        h("span", { class: "int-name", text: String(p.description ?? "Payment") }),
        h("span", {
          class: "int-amount",
          style: "color:#22c55e",
          text: `+${(Number(p.amount ?? 0) / 100).toFixed(2)}`,
        }),
        h("span", { class: "int-ago", text: timeAgo(p.createdAt) }),
      ),
    );
  }
  return h(
    "div",
    { class: "int-card" },
    header("#0570DE", "Stripe", "Payments"),
    h("div", { class: "int-balance" }, h("span", { text: balance }), h("i", { text: currency })),
    rows,
  );
}

// ── Notion ────────────────────────────────────────────────────────────────────

function notionCard(): HTMLElement {
  const rows = h("div", { class: "int-rows tight" });
  for (const p of arr("integration_notion", "pages").slice(0, 3)) {
    rows.append(
      h(
        "button",
        {
          class: "int-page",
          onclick: () => {
            if (typeof p.url === "string") void Bridge.openUrl(p.url);
          },
        },
        p.emoji
          ? h("span", { class: "int-emoji", text: String(p.emoji) })
          : h("i", { class: "int-emoji" }, svg(ICONS.doc, 9)),
        h("span", { class: "int-name", text: String(p.title ?? "Untitled") }),
        h("span", { class: "int-ago", text: timeAgo(p.lastEditedAt) }),
      ),
    );
  }
  return h("div", { class: "int-card" }, header("#E8E8E8", "Notion", "Recent"), rows);
}

// ── Cal.com ───────────────────────────────────────────────────────────────────

function calcomCard(): HTMLElement {
  const bookings = arr("integration_calcom", "bookings")
    .slice()
    .sort((a, b) => new Date(String(a.start)).getTime() - new Date(String(b.start)).getTime());
  const rows = h("div", { class: "int-rows tight" });
  if (bookings.length === 0) {
    rows.append(h("div", { class: "int-empty", text: "No calls scheduled" }));
  }
  for (const b of bookings.slice(0, 3)) {
    const when = new Date(String(b.start));
    const day = when.toLocaleDateString(undefined, { day: "2-digit", month: "2-digit" });
    const time = when.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
    rows.append(
      h(
        "div",
        { class: "int-row" },
        dot("#C9956A", 4),
        h("span", { class: "int-time", text: `${day} ${time}` }),
        h("span", { class: "int-name", text: String(b.title ?? "Meeting") }),
      ),
    );
  }
  return h("div", { class: "int-card" }, header("#C9956A", "Cal.com", "Schedule"), rows);
}

// ── Linear (#26 on macOS) ─────────────────────────────────────────────────────

function linearCard(): HTMLElement {
  const issues = arr("integration_linear", "issues");
  const linked = new Set(State.sessions.map((s) => s.linear?.identifier).filter(Boolean));
  const rows = h("div", { class: "int-rows tight" });
  if (!issues.length) rows.append(h("div", { class: "int-empty", text: "Nothing open is assigned to you." }));
  for (const issue of issues.slice(0, 4)) {
    const id = String(issue.identifier ?? "");
    rows.append(h("button", {
      class: "int-page",
      title: String(issue.stateName ?? ""),
      onclick: () => { if (typeof issue.url === "string") void Bridge.openUrl(issue.url); },
    },
      dot(String(issue.stateColor ?? "#8E939C"), 6),
      h("span", { class: "int-time", text: id }),
      h("span", { class: "int-name", text: String(issue.title ?? "") }),
      linked.has(id) ? h("span", { class: "int-ago", text: "● session" }) : null,
    ));
  }
  const count = issues.length ? `Assigned to you · ${issues.length}` : "Assigned to you";
  return h("div", { class: "int-card" }, header("#5E6AD2", "Linear", count), rows);
}

// ── WhaTicket ─────────────────────────────────────────────────────────────────

/** The extension checks in every ~15 s; past this the tab is closed or asleep. */
const WHATICKET_STALE_MS = 60_000;

function whaticketCard(): HTMLElement {
  const d = get("integration_whaticket");
  const pending = arr("integration_whaticket", "pending");
  const mine = arr("integration_whaticket", "mine");
  const accepting = new Set(Array.isArray(d.accepting) ? (d.accepting as unknown[]).map(String) : []);
  const stale = Date.now() - Number(d.seenAt ?? 0) > WHATICKET_STALE_MS;
  const rows = h("div", { class: "int-rows tight" });

  if (stale) {
    rows.append(h("button", {
      class: "int-page",
      onclick: () => void Bridge.whaticketOpen(null),
    },
      dot("#F5A524", 6),
      h("span", { class: "int-name", text: "Open whaticket.com in Chrome or Edge" }),
    ));
  }
  if (!pending.length && !mine.length) rows.append(h("div", { class: "int-empty", text: "No tickets waiting." }));
  for (const t of pending.slice(0, 3)) {
    const id = String(t.id);
    const busy = accepting.has(id);
    const accept = h("button", { class: "int-mini", text: busy ? "…" : "Accept" }) as HTMLButtonElement;
    accept.disabled = busy || stale;
    accept.addEventListener("click", async (e) => {
      e.stopPropagation();
      accept.textContent = "…";
      accept.disabled = true;
      try {
        await Bridge.whaticketAccept(id);
      } catch (err) {
        accept.textContent = "Accept";
        accept.disabled = false;
        State.noteMessage = String(err).replace(/^Error:\s*/, "");
        State.view = "note";
        State.notify();
      }
    });
    rows.append(h("div", {
      class: "int-page",
      title: String(t.lastMessage ?? ""),
      onclick: () => void Bridge.whaticketOpen(id),
    },
      dot(String(t.queueColor || "#F5A524"), 6),
      h("span", { class: "int-name", text: String(t.name ?? "") }),
      h("span", { class: "int-ago", text: [t.queue, timeAgo(t.updatedAt)].filter(Boolean).join(" · ") }),
      accept,
    ));
  }
  const left = 3 - Math.min(3, pending.length);
  for (const t of mine.slice(0, left)) {
    rows.append(h("button", {
      class: "int-page",
      title: String(t.lastMessage ?? ""),
      onclick: () => void Bridge.whaticketOpen(String(t.id)),
    },
      dot("#25D366", 6),
      h("span", { class: "int-name", text: String(t.name ?? "") }),
      Number(t.unread) > 0 ? h("span", { class: "int-ago", text: `${t.unread} new` }) : h("span", { class: "int-ago", text: timeAgo(t.updatedAt) }),
    ));
  }
  const kind = `Waiting ${Number(d.pendingCount ?? 0)} · Mine ${Number(d.mineCount ?? 0)}${d.autoAccept ? " · Auto" : ""}`;
  // "Today · Arrived 23 · Accepted 18 (5 auto)" — the rest is in Settings → WhaTicket → Stats.
  const today = h("div", { class: "int-status", text: todayLine(d.today as Record<string, unknown> | undefined) });
  return h("div", { class: "int-card" }, header("#25D366", "WhaTicket", kind), today, rows);
}

// ── Gmail ─────────────────────────────────────────────────────────────────────

/** Puts a file (a mail, a Drive file) in the chat; it goes with the next question. */
export function attachToChat(file: { name: string; path: string }, fresh: boolean) {
  if (fresh) startNewChat();
  State.droppedFile = { name: file.name, path: file.path };
  State.promptContext = { kind: "file", name: file.name, path: file.path };
  State.attachNext = true;
  State.view = "prompt";
  State.notify();
}

function gmailCard(): HTMLElement {
  const d = get("integration_gmail");
  const mails = arr("integration_gmail", "mails");
  const rows = h("div", { class: "int-rows tight" });
  if (!mails.length) rows.append(h("div", { class: "int-empty", text: "Nothing new in your inbox." }));
  for (const m of mails.slice(0, 3)) {
    const ask = h("button", { class: "int-mini mail", text: "Ask" });
    ask.addEventListener("click", async (e) => {
      e.stopPropagation();
      ask.textContent = "…";
      try {
        attachToChat(await Bridge.gmailAttach(String(m.id)), true);
      } catch (err) {
        ask.textContent = "Ask";
        State.noteMessage = String(err).replace(/^Error:\s*/, "");
        State.view = "note";
        State.notify();
      }
    });
    rows.append(h("div", {
      class: "int-page",
      title: String(m.snippet ?? ""),
      onclick: () => void Bridge.openUrl(`https://mail.google.com/mail/u/0/#inbox/${String(m.threadId ?? m.id)}`),
    },
      dot("#EA4335", 6),
      h("span", { class: "int-time", text: String(m.from ?? "") }),
      h("span", { class: "int-name", text: String(m.subject || "(no subject)") }),
      ask,
    ));
  }
  const total = Number(d.total ?? 0);
  return h("div", { class: "int-card" }, header("#EA4335", "Gmail", total ? `Unread · ${total}` : "Inbox"), rows);
}

// ── CI (#115) ─────────────────────────────────────────────────────────────────

const CI_COLOR: Record<CheckState | PrState, string> = {
  failed: "#F4505E", running: "#4C8DFF", passed: "#22C55E", cancelled: "#6B7079", neutral: "#6B7079", skipped: "#6B7079",
};
const CI_SYMBOL: Record<CheckState, string> = {
  failed: "✗", running: "●", passed: "✓", cancelled: "–", neutral: "–", skipped: "–",
};

/** Duration when known; otherwise what the check is doing. */
function ciStatusText(run: CheckRun): string {
  const s = checkState(run);
  const duration = formatDuration(durationSeconds(run));
  if (s === "running") return run.startedAt ? duration : "queued";
  if (s === "skipped") return "skipped";
  if (s === "cancelled") return "cancelled";
  if (s === "neutral") return duration || "neutral";
  return duration;
}

/** Re-runs asked for since the card was built (a run id), so the button says so. */
const ciRerunning = new Set<number>();

function ciShowError(err: unknown) {
  State.noteMessage = String(err).replace(/^Error:\s*/, "");
  State.view = "note";
  State.notify();
}

function ciAction(label: string, title: string, run: () => Promise<void> | void): HTMLButtonElement {
  const b = h("button", { class: "int-mini mail", text: label, title }) as HTMLButtonElement;
  b.addEventListener("click", async (e) => {
    e.stopPropagation();
    b.textContent = "…";
    b.disabled = true;
    try {
      await run();
    } catch (err) {
      ciShowError(err);
    } finally {
      b.textContent = label;
      b.disabled = false;
    }
  });
  return b;
}

function ciRunRows(pr: CIPr, run: CheckRun): HTMLElement[] {
  const s = checkState(run);
  const rows: HTMLElement[] = [h("div", { class: "ci-run" },
    h("span", { class: "ci-sym", style: `color:${CI_COLOR[s]}`, text: CI_SYMBOL[s] }),
    h("span", { class: "int-name", text: run.name }),
    h("span", { class: "int-ago", style: "margin-left:auto", text: ciStatusText(run) }),
  )];
  if (s !== "failed") return rows;
  const acts = h("div", { class: "ci-acts" });
  if (run.htmlUrl) {
    const url = run.htmlUrl;
    acts.append(ciAction("Open log", "Open log", () => void Bridge.openUrl(url)));
  }
  acts.append(ciAction("Ask Mochi why", "Ask Mochi why", async () => attachToChat(await ciLogFile(pr, run), true)));
  const job = parseJobUrl(run.htmlUrl);
  if (job) {
    const label = ciRerunning.has(job.runId) ? "Re-running…" : "Re-run";
    const b = ciAction(label, "Re-run failed jobs", async () => {
      ciRerunning.add(await ciRerunFailed(pr, run));
    });
    if (ciRerunning.has(job.runId)) b.disabled = true;
    acts.append(b);
  }
  rows.push(acts);
  return rows;
}

function ciCard(): HTMLElement {
  const d = get(CI_ID);
  const prs = (Array.isArray(d.prs) ? d.prs : []) as CIPr[];
  const pill = (d.pill ?? { color: "idle", count: 0 }) as PillState;
  const rows = h("div", { class: "int-rows tight ci-rows" });
  if (!prs.length) rows.append(h("div", { class: "int-empty", text: "No open pull requests." }));
  for (const pr of prs) {
    rows.append(h("button", {
      class: "int-page",
      title: pr.summary.total ? pr.title : "No checks on this commit",
      onclick: () => void Bridge.openUrl(pr.url),
    },
      dot(CI_COLOR[pr.summary.state], 6),
      h("span", { class: "int-time", style: "color:#8e939c", text: `${pr.repo.split("/")[1] ?? pr.repo}#${pr.number}` }),
      h("span", { class: "int-name", text: pr.title }),
      pr.summary.total ? h("span", { class: "int-ago", style: "margin-left:auto", text: `${pr.summary.passed}/${pr.summary.total}` }) : null,
    ));
    for (const run of pr.runs) rows.append(...ciRunRows(pr, run));
  }
  const kind = pill.color === "failed" ? `Failing · ${pill.count}`
    : pill.color === "running" ? `Running · ${pill.count}`
    : prs.length ? `Open PRs · ${prs.length}` : "Your open PRs";
  return h("div", { class: "int-card" }, header("#2F81F7", "CI", kind), rows);
}

// ── n8n ───────────────────────────────────────────────────────────────────────

function n8nCard(task: AgentTask, onDetail: () => void, openSettings: () => void): HTMLElement {
  const hasActivity = task.steps.length > 0 && (task.state === "finished" || task.state === "error");
  if (!hasActivity) return idleCard(task, openSettings);
  const success = task.state === "finished";
  const accent = success ? "#22C55E" : "#F4505E";
  return h(
    "div",
    { class: "int-card" },
    header("#F29B38", "n8n", "Workflow"),
    h(
      "div",
      { class: "int-actions" },
      h(
        "button",
        {
          class: "int-pill",
          style: `background:${accent}1a;border-color:${accent}38`,
          onclick: onDetail,
        },
        dot(accent, 5),
        h("span", { class: "int-name", text: task.steps[0] ?? "Workflow" }),
        svg(ICONS.ellipsis, 8),
      ),
    ),
  );
}

function n8nDetail(task: AgentTask, onBack: () => void): HTMLElement {
  const success = task.state === "finished";
  const accent = success ? "#22C55E" : "#F4505E";
  const detail = task.steps[1];
  return h(
    "div",
    { class: "int-card detail" },
    h(
      "div",
      { class: "int-detail-head" },
      h("button", { class: "int-back", onclick: onBack }, svg(ICONS.chevronLeft, 10, { stroke: 2.4 })),
      dot(accent, 6),
      h("b", { text: task.steps[0] ?? "Workflow" }),
      h("span", {
        class: "int-badge",
        style: `color:${accent};background:${accent}24`,
        text: success ? "Success" : "Failed",
      }),
    ),
    detail
      ? h("pre", { class: "int-detail-text", text: detail })
      : h("div", {
          class: "int-status",
          text: success ? "Completed successfully." : "No error details available.",
        }),
  );
}

// ── Dispatch ──────────────────────────────────────────────────────────────────

export interface IntegrationCardHooks {
  detailOpen: boolean;
  openDetail(): void;
  closeDetail(): void;
  openSettings(): void;
}

/** True when this integration has data worth showing instead of the idle card. */
export function hasIntegrationData(id: string): boolean {
  const info = State.integrations[id];
  if (!info || info.error) return false;
  switch (id) {
    case "integration_vercel":
      return arr(id, "deployments").length > 0;
    case "integration_resend":
      return arr(id, "emails").length > 0;
    case "integration_github":
      return get(id).totalRepos != null;
    case "integration_stripe":
      return info.loaded;
    case "integration_notion":
      return arr(id, "pages").length > 0;
    case "integration_calcom":
      return info.loaded;
    case "integration_linear":
    case "integration_whaticket":
    case "integration_gmail":
    case CI_ID:
      return info.loaded;
    default:
      return false;
  }
}

export function renderIntegrationCard(task: AgentTask, hooks: IntegrationCardHooks): HTMLElement {
  if (task.id === "integration_n8n") {
    const hasActivity = task.steps.length > 0 && (task.state === "finished" || task.state === "error");
    return hooks.detailOpen && hasActivity
      ? n8nDetail(task, hooks.closeDetail)
      : n8nCard(task, hooks.openDetail, hooks.openSettings);
  }
  if (task.id === "integration_vercel" && hasIntegrationData(task.id)) {
    return hooks.detailOpen ? vercelDetail(hooks.closeDetail) : vercelCard(hooks.openDetail);
  }
  if (!hasIntegrationData(task.id)) return idleCard(task, hooks.openSettings);

  switch (task.id) {
    case "integration_resend":
      return resendCard();
    case "integration_github":
      return githubCard();
    case "integration_stripe":
      return stripeCard();
    case "integration_notion":
      return notionCard();
    case "integration_calcom":
      return calcomCard();
    case "integration_linear":
      return linearCard();
    case "integration_whaticket":
      return whaticketCard();
    case "integration_gmail":
      return gmailCard();
    case CI_ID:
      return ciCard();
    default:
      return idleCard(task, hooks.openSettings);
  }
}

export { clear };
