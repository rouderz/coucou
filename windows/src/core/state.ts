// App state — mirror of AppState.swift (the parts the island needs).

import { visiblePillIds, PILL_SLOTS } from "./pills";
import type { BotEmoteName, BotStateName, IslandMode, IslandViewName } from "./layout";
import type { EyeShape } from "../mochi/engine";
import type { EditPreview } from "../claude/preview.ts";
import type { CodeContext } from "./bridge";
import type { SavedChat } from "./chats";

export type AgentSource = "claudeCode" | "n8n";
export type PillBadge = "approval" | "finished" | "error";

export interface AgentTask {
  id: string;
  name: string;
  color: string;
  state: BotStateName;
  stepIndex: number;
  steps: string[];
  source: AgentSource;
  isIntegration: boolean;
  emote?: BotEmoteName | null;
  miniEye?: EyeShape | null;
  pillBadge?: PillBadge | null;
  sessionCwd?: string | null;
}

export interface ApprovalInfo {
  requestId: string;
  sessionId: string;
  tool: string;
  command: string;
  /** How risky it is, and why in a few words (#21 on macOS). */
  risk: "low" | "medium" | "high";
  riskReason: string;
  /** The session's folder: auto-approve rules are per project. */
  cwd: string;
  project: string;
  /** "claude" or "codex". */
  agent: string;
  /** The change an edit would make, shown as a diff in the review card. */
  preview: EditPreview | null;
}

/** Plan usage from Claude Code's status line (the macOS bars). */
export interface PlanUsage {
  fiveHour: { percent: number; resetsAt: number } | null;
  sevenDay: { percent: number; resetsAt: number } | null;
  context: number | null;
  model: string | null;
}

/** One Claude Code / Codex session (#24 on macOS). The focused one drives the card. */
export interface ClaudeSession {
  id: string;
  agent: string;
  project: string;
  cwd: string;
  state: BotStateName;
  steps: string[];
  updatedAt: number;
  /** Something happened here while another session was on the card. */
  unseen: boolean;
  /** The Linear issue the session's git branch names (#27 on macOS). */
  linear?: LinearIssueRef | null;
}

export interface LinearIssueRef {
  id: string;
  identifier: string;
  title: string;
  url: string;
}

/** Something that needs you: a review request, a mention, an assignment… */
export interface InboxItem {
  id: string;
  source: "github" | "linear";
  kind: "review" | "mention" | "assigned" | "comment" | "other";
  title: string;
  subtitle: string;
  actor: string | null;
  url: string;
  date: number;
}

export interface ChatMessage {
  id: number;
  role: "user" | "assistant";
  content: string;
}

export type PromptContext =
  | { kind: "window"; appName: string; title: string; url?: string }
  | { kind: "file"; name: string; path?: string };

export interface ResultItem {
  label: string;
  detail: string;
  url?: string;
}

export interface SearchResult {
  title: string;
  items: ResultItem[];
  note?: string;
}

const task = (
  id: string, name: string, color: string, source: AgentSource,
): AgentTask => ({
  id, name, color, state: "idle", stepIndex: 0, steps: [], source, isIntegration: true,
});

/** AgentTask.integrationAgents — same ids, names and colours as macOS. */
export const INTEGRATION_AGENTS: AgentTask[] = [
  task("integration_claude", "VS Code", "#F5F6F8", "claudeCode"),
  task("integration_resend", "Resend", "#22C55E", "n8n"),
  task("integration_n8n", "n8n", "#F29B38", "n8n"),
  task("integration_vercel", "Vercel", "#7C5CFF", "n8n"),
  task("integration_github", "GitHub", "#F4505E", "n8n"),
  task("integration_notion", "Notion", "#8C8C8C", "n8n"),
  task("integration_calcom", "Cal.com", "#C9956A", "n8n"),
  task("integration_stripe", "Stripe", "#0570DE", "n8n"),
  task("integration_linear", "Linear", "#5E6AD2", "n8n"),
  task("integration_whaticket", "WhaTicket", "#25D366", "n8n"),
  task("integration_gmail", "Gmail", "#EA4335", "n8n"),
];

export const TOGGLEABLE_INTEGRATION_IDS = [
  "integration_resend", "integration_n8n", "integration_vercel", "integration_github",
  "integration_notion", "integration_calcom", "integration_stripe", "integration_linear",
  "integration_whaticket", "integration_gmail",
];

/** What an integration poller last reported. */
export interface IntegrationInfo {
  data: Record<string, unknown>;
  error: string | null;
  loaded: boolean;
  configured: boolean;
}

export interface Settings {
  soundEnabled: boolean;
  soundVolume: number;
  autoCloseInterval: number;
  absenceInterval: number;
  activeIntegrations: string[];
  /** Pills that never rotate out of the island. */
  pinnedPills: string[];
  /** Seconds between pill rotations when more than 4 are active; 0 = off. */
  pillRotationSeconds: number;
  screen: "primary" | "cursor";
  autostart: boolean;
  hooksInstalled: boolean;
  /** Claude model used by the chat. */
  model: string;
  /** "api": Anthropic API key. "claude-code": the user's Claude Code subscription. "provider": OpenAI-compatible. */
  chatEngine: "api" | "claude-code" | "provider";
  providerId: string;
  providerBaseUrl: string;
  providerModel: string;
  /** "system", "en" or "es" (applied at the next launch of the window). */
  language: "system" | "en" | "es";
  /** Mochi reads its chat replies aloud. */
  speakReplies: boolean;
  /** A small notch stays at the top when the island hides (like the Mac's). */
  idleNotch: boolean;
  /** WhaTicket: accept new tickets on their own, from these queues (empty = any), in these hours. */
  whaticketAutoAccept: boolean;
  whaticketQueues: string[];
  whaticketHours: string;
  /** Google: the connected account, and the Gmail search the pill shows. */
  googleEmail: string;
  gmailQuery: string;
  /** Preferred editor command; "" = the first one installed. */
  editor: string;
  /** Auto-approve per project folder: "low" or "medium" (absent = always ask). */
  autoApprove: Record<string, string>;
  /** Do not disturb until (ms since the epoch); null = off. */
  dndUntil: number | null;
  phoneAlerts: boolean;
  ntfyServer: string;
  ntfyTopic: string;
  phoneOnlyWhenAway: boolean;
  inboxEnabled: boolean;
  inboxGithub: boolean;
  inboxLinear: boolean;
  inboxKinds: string[];
  checkUpdates: boolean;
}

export const DEFAULT_SETTINGS: Settings = {
  soundEnabled: true,
  soundVolume: 0.12,
  autoCloseInterval: 15,
  absenceInterval: 180,
  activeIntegrations: [
    "integration_resend", "integration_n8n", "integration_vercel", "integration_github",
  ],
  pinnedPills: [],
  pillRotationSeconds: 30,
  screen: "primary",
  autostart: false,
  hooksInstalled: false,
  model: "claude-opus-5-5",
  chatEngine: "api",
  editor: "",
  autoApprove: {},
  dndUntil: null,
  phoneAlerts: false,
  ntfyServer: "",
  ntfyTopic: "",
  phoneOnlyWhenAway: true,
  inboxEnabled: true,
  inboxGithub: true,
  inboxLinear: true,
  inboxKinds: ["review", "mention", "assigned", "comment", "other"],
  checkUpdates: true,
  providerId: "openai",
  providerBaseUrl: "",
  providerModel: "",
  language: "system",
  speakReplies: false,
  idleNotch: true,
  whaticketAutoAccept: false,
  whaticketQueues: [],
  whaticketHours: "",
  googleEmail: "",
  gmailQuery: "is:unread in:inbox",
};

type Listener = () => void;

class AppState {
  mode: IslandMode = "hidden";
  view: IslandViewName = "overview";

  tasks: AgentTask[] = [];
  focusId: string | null = null;

  stateOverride: BotStateName | null = null;

  private pillOffset = 0;
  private pillTimer: number | null = null;
  private pillTimerSecs = 0;

  /** Cursor in logical screen pixels, origin top-left (like AppState.mousePosition). */
  mouse = { x: 0, y: 0 };
  /** Cursor relative to the island's top-left corner. */
  mouseInIsland = { x: 0, y: 0 };

  isPinned = false;
  paused = false;

  uploadProgress = 0;
  uploadDuration = 2.4;
  fileDragOver = false;

  promptContext: PromptContext | null = null;
  droppedFile: { name: string; path: string } | null = null;
  noteMessage: string | null = null;
  searchResult: SearchResult | null = null;
  chatHistory: ChatMessage[] = [];
  pendingApproval: ApprovalInfo | null = null;
  /** Requests waiting behind the one on screen. */
  approvalQueue: ApprovalInfo[] = [];

  planUsage: PlanUsage | null = null;

  /** GitHub / Linear notifications that need you. */
  inbox: InboxItem[] = [];
  /** Saved chats, newest first, and the one on screen. */
  chats: SavedChat[] = [];
  currentChatId: string | null = null;
  /** The editor's latest context (VS Code / Cursor extension), and the one attached to the chat. */
  editorContext: (CodeContext & { at: number }) | null = null;
  codeContext: CodeContext | null = null;
  /** A skill picked with "/" in the chat; its SKILL.md goes with the next question. */
  chatSkill: { name: string; path: string } | null = null;
  /** A file attached mid-chat (a mail, a Drive file): it goes with the next question. */
  attachNext = false;

  /** A newer release, from the update check. */
  update: { latest: string; url: string; canInstall: boolean; installing?: boolean } | null = null;

  /** Claude Code / Codex sessions, and the one on the card. */
  sessions: ClaudeSession[] = [];
  focusedSession: string | null = null;

  integrations: Record<string, IntegrationInfo> = {};

  lastActivity = performance.now();

  settings: Settings = { ...DEFAULT_SETTINGS };

  private listeners = new Set<Listener>();

  subscribe(fn: Listener): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  /** Marks the UI dirty; the island re-renders on the next frame. */
  notify() {
    this.syncPillTimer();
    for (const fn of this.listeners) fn();
  }

  get focusTask(): AgentTask | null {
    return this.tasks.find((t) => t.id === this.focusId) ?? this.tasks[0] ?? null;
  }

  get effectiveState(): BotStateName {
    return this.stateOverride ?? this.focusTask?.state ?? "idle";
  }

  get otherTasks(): AgentTask[] {
    return this.tasks.filter((t) => t.id !== this.focusId);
  }

  /** The pills shown next to the focused one: up to 4, rotating through the rest (#111). */
  get visiblePills(): AgentTask[] {
    const others = this.otherTasks;
    const ids = visiblePillIds(
      others.map((t) => t.id),
      {
        pinned: this.settings.pinnedPills,
        news: others.filter((t) => t.pillBadge).map((t) => t.id),
        offset: this.pillOffset,
      },
    );
    return others.filter((t) => ids.includes(t.id));
  }

  /** Active pills that aren't in the island right now (the "+N" menu). */
  get overflowPills(): AgentTask[] {
    const shown = new Set(this.visiblePills.map((t) => t.id));
    return this.otherTasks.filter((t) => !shown.has(t.id));
  }

  togglePinned(id: string) {
    const pinned = this.settings.pinnedPills ?? [];
    this.settings.pinnedPills = pinned.includes(id) ? pinned.filter((x) => x !== id) : [...pinned, id];
    this.notify();
  }

  /** The timer exists only while the island shows and some pills don't fit: nothing runs otherwise. */
  private syncPillTimer() {
    const secs = this.settings.pillRotationSeconds ?? 0;
    const want = this.mode !== "hidden" && secs > 0 && this.otherTasks.length > PILL_SLOTS ? secs : 0;
    if (want === this.pillTimerSecs) return;
    if (this.pillTimer !== null) window.clearInterval(this.pillTimer);
    this.pillTimer = null;
    this.pillTimerSecs = want;
    if (want > 0) {
      this.pillTimer = window.setInterval(() => {
        this.pillOffset += 1;
        this.notify();
      }, want * 1000);
    }
  }

  setFocus(id: string) {
    const t = this.tasks.find((x) => x.id === id);
    if (!t) return;
    this.focusId = id;
    t.pillBadge = null;
    this.notify();
  }

  updateTask(id: string, state: BotStateName) {
    const t = this.tasks.find((x) => x.id === id);
    if (!t) return;
    t.state = state;
    this.notify();
  }

  appendStep(id: string, step: string) {
    const t = this.tasks.find((x) => x.id === id);
    if (!t) return;
    t.steps.push(step);
    if (t.steps.length > 20) t.steps.shift();
    t.stepIndex = t.steps.length - 1;
    this.notify();
  }

  setPillBadge(id: string, badge: PillBadge | null) {
    const t = this.tasks.find((x) => x.id === id);
    if (!t) return;
    t.pillBadge = badge;
    this.notify();
  }

  /** loadIntegrationTasks() — VS Code always on, the rest opt-in . */
  loadIntegrationTasks() {
    for (const proto of INTEGRATION_AGENTS) {
      const shouldLoad =
        proto.id === "integration_claude" || this.settings.activeIntegrations.includes(proto.id);
      const idx = this.tasks.findIndex((t) => t.id === proto.id);
      if (shouldLoad && idx < 0) this.tasks.push({ ...proto, steps: [] });
      if (!shouldLoad && idx >= 0) this.tasks.splice(idx, 1);
    }
    // Keep the declared order so pills never shuffle.
    const order = INTEGRATION_AGENTS.map((t) => t.id);
    this.tasks.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
    if (!this.focusId) this.focusId = "integration_claude";
    this.notify();
  }

  toggleIntegration(id: string) {
    if (id === "integration_claude") return;
    const active = this.settings.activeIntegrations;
    if (active.includes(id)) {
      this.settings.activeIntegrations = active.filter((x) => x !== id);
      if (this.focusId === id) this.focusId = "integration_claude";
    } else {
      this.settings.activeIntegrations = [...active, id];
    }
    this.loadIntegrationTasks();
  }

  defaultView(): IslandViewName {
    return this.tasks.length === 0 ? "empty" : "overview";
  }
}

export const State = new AppState();
