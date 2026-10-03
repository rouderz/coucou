// Quick capture (#118): one line becomes a Linear issue. Pure logic only (no DOM,
// no network): the line parser, the preview chip, the issueCreate request and
// response, and the two-step Enter flow. Mirrored in NotchBuddy/Sources/App/QuickCapture.swift.
//
//   Fix the cart total rounding #SHO p2 @me !fri
//
// Nothing is created until the second Enter / click on the preview: `reduce`
// only emits a "create" effect from the "preview" phase, and any edit goes back
// to "editing".

export interface ParsedCapture {
  title: string;
  /** Team key as typed, upper-cased ("SHO"); null = the default team. */
  teamKey: string | null;
  /** Linear priority: 1 urgent, 2 high, 3 medium, 4 low; 0 = none. */
  priority: number;
  assignToMe: boolean;
  /** "YYYY-MM-DD" (local calendar day), or null. */
  dueDate: string | null;
}

export interface TeamInfo { id: string; key: string; name: string }

const WEEKDAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
const WEEKDAY_LONG = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

export function isoDay(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** "today", "tomorrow", a weekday ("fri", "friday": the next one, never today) or "YYYY-MM-DD". */
export function parseDue(word: string, now: Date): string | null {
  const w = word.toLowerCase();
  const day = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  if (w === "today" || w === "tod") return isoDay(day);
  if (w === "tomorrow" || w === "tom") {
    day.setDate(day.getDate() + 1);
    return isoDay(day);
  }
  let wd = WEEKDAYS.indexOf(w);
  if (wd < 0) wd = WEEKDAY_LONG.indexOf(w);
  if (wd >= 0) {
    const ahead = ((wd - day.getDay() + 6) % 7) + 1; // 1…7
    day.setDate(day.getDate() + ahead);
    return isoDay(day);
  }
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(w);
  if (m) {
    const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
    const check = new Date(y, mo - 1, d);
    if (check.getFullYear() === y && check.getMonth() === mo - 1 && check.getDate() === d) return w;
  }
  return null;
}

/**
 * Splits the line into words; a word is a token only when it matches exactly
 * (`#SHO`, `p2`, `@me`, `!fri`), otherwise it stays in the title. If a token
 * kind appears twice the last one wins.
 */
export function parseCapture(line: string, now: Date = new Date()): ParsedCapture {
  const out: ParsedCapture = { title: "", teamKey: null, priority: 0, assignToMe: false, dueDate: null };
  const kept: string[] = [];
  for (const word of line.trim().split(/\s+/)) {
    if (!word) continue;
    let m: RegExpExecArray | null;
    if ((m = /^#([A-Za-z][A-Za-z0-9]{1,9})$/.exec(word))) out.teamKey = m[1].toUpperCase();
    else if ((m = /^[pP]([1-4])$/.exec(word))) out.priority = Number(m[1]);
    else if (/^@me$/i.test(word)) out.assignToMe = true;
    else if (word.startsWith("!") && parseDue(word.slice(1), now)) out.dueDate = parseDue(word.slice(1), now);
    else kept.push(word);
  }
  out.title = kept.join(" ");
  return out;
}

export const PRIORITY_LABEL = ["No priority", "Urgent", "High", "Medium", "Low"];

export type ChipProblem = "empty-title" | "unknown-team" | "no-team" | "no-teams-loaded";

export interface PreviewChip {
  team: TeamInfo | null;
  title: string;
  priority: number;
  priorityLabel: string;
  /** "Me" when assigned to you, else null (unassigned). */
  assignee: string | null;
  dueDate: string | null;
  problems: ChipProblem[];
  /** True only when the issue could be created as shown. */
  ready: boolean;
}

/** The team: the `#KEY` typed, else the default team from Settings, else (when there is only one) that one. */
export function buildChip(p: ParsedCapture, teams: TeamInfo[], defaultTeamKey: string | null): PreviewChip {
  const problems: ChipProblem[] = [];
  let team: TeamInfo | null = null;
  const wanted = p.teamKey ?? (defaultTeamKey ? defaultTeamKey.toUpperCase() : null);
  if (teams.length === 0) problems.push("no-teams-loaded");
  else if (wanted) {
    team = teams.find((t) => t.key.toUpperCase() === wanted) ?? null;
    if (!team) problems.push("unknown-team");
  } else if (teams.length === 1) team = teams[0];
  else problems.push("no-team");
  if (!p.title) problems.push("empty-title");
  return {
    team, title: p.title, priority: p.priority, priorityLabel: PRIORITY_LABEL[p.priority],
    assignee: p.assignToMe ? "Me" : null, dueDate: p.dueDate, problems, ready: problems.length === 0,
  };
}

// MARK: Linear requests

export const TEAMS_QUERY = "query { viewer { id } teams(first: 100) { nodes { id key name } } }";

export const ISSUE_CREATE_MUTATION =
  "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier title url branchName } } }";

export function parseTeams(data: any): { viewerId: string | null; teams: TeamInfo[] } {
  const nodes: any[] = data?.teams?.nodes ?? [];
  const teams = nodes
    .filter((n) => typeof n?.id === "string" && typeof n?.key === "string")
    .map((n) => ({ id: n.id, key: n.key, name: typeof n.name === "string" ? n.name : n.key }));
  return { viewerId: typeof data?.viewer?.id === "string" ? data.viewer.id : null, teams };
}

/** The `variables` for ISSUE_CREATE_MUTATION. Throws if the chip isn't ready, or "@me" has no viewer id. */
export function buildIssueCreateVariables(chip: PreviewChip, viewerId: string | null): { input: Record<string, unknown> } {
  if (!chip.ready || !chip.team) throw new Error("The issue isn't ready to create");
  const input: Record<string, unknown> = { teamId: chip.team.id, title: chip.title };
  if (chip.priority > 0) input.priority = chip.priority;
  if (chip.assignee) {
    if (!viewerId) throw new Error("Can't tell who you are in Linear");
    input.assigneeId = viewerId;
  }
  if (chip.dueDate) input.dueDate = chip.dueDate;
  return { input };
}

export interface CreatedIssue { id: string; identifier: string; title: string; url: string; branchName: string | null }

/** `data` of the issueCreate response; null when Linear didn't accept it. */
export function parseIssueCreate(data: any): CreatedIssue | null {
  const r = data?.issueCreate;
  const i = r?.issue;
  if (r?.success !== true || typeof i?.id !== "string" || typeof i?.identifier !== "string") return null;
  return {
    id: i.id, identifier: i.identifier, title: typeof i.title === "string" ? i.title : "",
    url: typeof i.url === "string" ? i.url : "https://linear.app",
    branchName: typeof i.branchName === "string" ? i.branchName : null,
  };
}

// MARK: Two-step flow

export type CaptureState =
  | { phase: "editing"; line: string }
  | { phase: "preview"; line: string; chip: PreviewChip }
  | { phase: "creating"; line: string; chip: PreviewChip }
  | { phase: "done"; line: string; issue: CreatedIssue }
  | { phase: "failed"; line: string; chip: PreviewChip; message: string };

export type CaptureEvent =
  | { type: "type"; line: string }
  | { type: "enter" }       // the Enter key or the Create button, the same thing
  | { type: "escape" }
  | { type: "created"; issue: CreatedIssue }
  | { type: "failed"; message: string };

/** What the caller must do after a transition. Only "create" touches Linear. */
export type CaptureEffect = { type: "create"; chip: PreviewChip } | { type: "close" } | null;

export interface CaptureContext { teams: TeamInfo[]; defaultTeamKey: string | null; now: Date }

export const initialCapture: CaptureState = { phase: "editing", line: "" };

export function reduce(s: CaptureState, e: CaptureEvent, ctx: CaptureContext): { state: CaptureState; effect: CaptureEffect } {
  const same = (state: CaptureState) => ({ state, effect: null as CaptureEffect });
  switch (e.type) {
    case "type":
      // Typing never creates; any edit (even during a preview) goes back to editing.
      if (s.phase === "creating" || s.phase === "done") return same(s);
      return same({ phase: "editing", line: e.line });
    case "escape":
      if (s.phase === "preview" || s.phase === "failed") return same({ phase: "editing", line: s.line });
      return { state: s, effect: { type: "close" } };
    case "enter":
      if (s.phase === "editing" || s.phase === "failed") {
        const line = s.line;
        if (!line.trim()) return same(s);
        return same({ phase: "preview", line, chip: buildChip(parseCapture(line, ctx.now), ctx.teams, ctx.defaultTeamKey) });
      }
      if (s.phase === "preview") {
        if (!s.chip.ready) return same(s); // problems shown on the chip; nothing is sent
        return { state: { phase: "creating", line: s.line, chip: s.chip }, effect: { type: "create", chip: s.chip } };
      }
      if (s.phase === "done") return { state: s, effect: { type: "close" } };
      return same(s); // creating: a repeated Enter never sends twice
    case "created":
      return s.phase === "creating" ? same({ phase: "done", line: s.line, issue: e.issue }) : same(s);
    case "failed":
      return s.phase === "creating" ? same({ phase: "failed", line: s.line, chip: s.chip, message: e.message }) : same(s);
  }
}

/** Branch to copy for "Start a Claude Code session on it": Linear's own name, else the identifier. */
export function branchToCopy(issue: CreatedIssue): string {
  return issue.branchName ?? issue.identifier.toLowerCase();
}
