// Thin wrapper over the Tauri commands/events. Every call is a no-op when the
// page is opened in a plain browser, so the island can be iterated on with
// `npm run dev` alone.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import type { Settings } from "./state";

export const IS_TAURI =
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

async function call<T>(cmd: string, args?: Record<string, unknown>): Promise<T | null> {
  if (!IS_TAURI) return null;
  try {
    return await invoke<T>(cmd, args);
  } catch (err) {
    console.error(`[coucou] ${cmd} failed`, err);
    return null;
  }
}

export interface BootInfo {
  settings: Settings;
  /** Logical screen rect of the monitor the island lives on. */
  screen: { x: number; y: number; width: number; height: number; scale: number };
  version: string;
  hookPath: string;
  /** "windows" or "linux". */
  platform?: "windows" | "linux";
  /**
   * "poll": Rust sends `cursor` events from the global cursor. "dom": there is no
   * global cursor (Wayland), so the page reports the pointer itself.
   */
  pointer?: "poll" | "dom";
}

export const Bridge = {
  boot: () => call<BootInfo>("boot"),

  saveSettings: (settings: Settings) => call<void>("save_settings", { settings }),

  /** Shrink the window down to the invisible wake strip (hidden) or back to full. */
  setCollapsed: (collapsed: boolean) => call<void>("set_collapsed", { collapsed }),

  /**
   * Pushes the island shape in window coordinates. Rust flips click-through from
   * its own cursor poll, so the flag is never a frame behind a click.
   */
  setIslandRect: (x: number, y: number, width: number, height: number) =>
    call<void>("set_island_rect", { x, y, width, height }),

  /** Give the window keyboard focus (chat field) and take it away again. */
  focusWindow: (focused: boolean) => call<void>("focus_window", { focused }),

  reposition: () => call<void>("reposition"),

  openUrl: (url: string) => call<void>("open_url", { url }),

  /** "Open terminal" → opens the folder in the editor picked in Settings. */
  openInVSCode: (path: string | null) => call<boolean>("open_in_vscode", { path }),
  /** VS Code, Cursor, Windsurf, Zed — the ones installed. */
  editorsInstalled: () => call<{ id: string; name: string }[]>("editors_installed"),
  /** Is `claude` installed, for the subscription chat? */
  claudeCodeStatus: () => call<{ installed: boolean; path: string | null }>("claude_code_status"),
  // ── Linear, inbox, phone alerts, updates, shortcuts ─────────────────────────
  linearIssueForFolder: (cwd: string) =>
    call<{ id: string; identifier: string; title: string; url: string } | null>("linear_issue_for_folder", { cwd }),
  /** Posts Markdown on the issue — only ever from a click. */
  linearComment: (issueId: string, body: string) => callOrThrow<void>("linear_comment", { issueId, body }),
  inboxRefresh: () => call<void>("inbox_refresh"),
  inboxDismiss: (id: string) => call<void>("inbox_dismiss", { id }),
  /** True when the phone was told (set up, and away when that's asked for). */
  phoneAlert: (title: string, message: string, urgent: boolean) =>
    call<boolean>("phone_alert", { title, message, urgent }),
  phoneTest: (server: string, topic: string) => callOrThrow<void>("phone_test", { server, topic }),
  newNtfyTopic: () => call<string>("new_ntfy_topic"),
  checkUpdate: () => callOrThrow<{ current: string; latest: string; newer: boolean; url: string }>("check_update"),
  /** This copy can update itself (signed releases; Windows, or Linux as an AppImage). */
  updateCanInstall: () => call<boolean>("update_can_install"),
  /** Downloads, checks the signature, installs and restarts. */
  updateInstall: () => callOrThrow<void>("update_install"),
  /** Alt+Enter / Alt+Backspace answer the card from any app, only while it's up. */
  approvalShortcuts: (armed: boolean) => call<void>("approval_shortcuts", { armed }),

  // ── Saved chats, other providers ────────────────────────────────────────────
  chatRestore: (messages: { user: boolean; text: string }[], sessionId: string | null, workDir: string | null) =>
    call<void>("chat_restore", { messages, sessionId, workDir }),
  chatSessionInfo: () => call<{ sessionId: string | null; workDir: string | null }>("chat_session_info"),
  chatsLoad: () => call<unknown[]>("chats_load"),
  chatsSave: (chats: unknown[]) => call<void>("chats_save", { chats }),
  chatDeleteDir: (dir: string) => call<void>("chat_delete_dir", { dir }),
  providerPresets: () => call<{ id: string; name: string; baseUrl: string; needsKey: boolean; defaultModel: string; keyHint: string }[]>("provider_presets"),
  providerModels: () => callOrThrow<string[]>("provider_models"),
  /** Push-to-talk: one spoken question, as text (Windows). */
  voiceListen: () => callOrThrow<string>("voice_listen"),
  voiceAvailable: () => call<boolean>("voice_available"),

  // ── Skills (Claude Code / Codex) ────────────────────────────────────────────
  skillsList: () => call<SkillInfo[]>("skills_list"),
  /** Where a new skill can go: "personal", "codex" or a project folder. */
  skillsTargets: () => call<{ id: string; label: string }[]>("skills_targets"),
  skillRead: (path: string) => callOrThrow<SkillText>("skill_read", { path }),
  skillSetEnabled: (path: string, enabled: boolean) => callOrThrow<void>("skill_set_enabled", { path, enabled }),
  /** Stages a folder, .zip / .skill file or GitHub link; nothing is installed yet. */
  skillsPreview: (source: string, target: string) => callOrThrow<SkillPreview>("skills_preview", { source, target }),
  skillsInstall: (token: string, replace: boolean) => callOrThrow<string[]>("skills_install", { token, replace }),
  skillCreate: (name: string, target: string) => callOrThrow<string>("skill_create", { name, target }),
  skillReveal: (path: string) => call<void>("skill_reveal", { path }),

  /** Codex CLI hooks in ~/.codex/hooks.json. */
  codexStatus: () => call<{ found: boolean; installed: boolean; hooksPath: string }>("codex_status"),
  codexInstall: (install: boolean) => callOrThrow<void>("codex_install", { install }),
  /** GitHub without a token: the GitHub CLI's own sign-in. */
  githubCliStatus: () => call<{ installed: boolean; signedIn: boolean; user: string | null }>("github_cli_status"),

  quit: () => call<void>("quit_app"),

  openSettingsWindow: () => call<void>("open_settings_window"),

  /** Writes to coucou.log in the app's local folder, next to the Rust lines. */
  log: (message: string) => call<void>("log_line", { message }),

  // ── Claude Code hooks ─────────────────────────────────────────────────────
  hooksStatus: () => call<HookStatus>("hooks_status"),
  /** Diff to show before anything is written. `install: false` previews removal. */
  hooksPreview: (install: boolean) => callOrThrow<HookPreview>("hooks_preview", { install }),
  /**
   * Writes ~/.claude/settings.json — only ever after an explicit click, and only
   * when the file still matches the preview the user looked at.
   */
  hooksApply: (install: boolean, fingerprint: string) =>
    callOrThrow<string>("hooks_apply", { install, fingerprint }),

  approvalDecision: (requestId: string, decision: "allow" | "deny") =>
    call<void>("approval_decision", { requestId, decision }),
  /** "The card is up" — until this lands the relay only waits a moment. */
  approvalAck: (requestId: string) => call<void>("approval_ack", { requestId }),
  /** "Nobody can act on this" — Claude Code asks in the terminal right away. */
  approvalDecline: (requestId: string) => call<void>("approval_decline", { requestId }),

  // ── Chat, files, secrets ──────────────────────────────────────────────────
  /** One chat turn. The API key and any file bytes never leave Rust. */
  chatSend: (query: string, context: ChatContext | null) =>
    callOrThrow<{ text: string }>("chat_send", { query, context }),
  chatReset: () => call<void>("chat_reset"),
  /** Copies a dropped file into the inbox. */
  ingestFile: (path: string) => callOrThrow<DroppedFile>("ingest_file", { path }),
  /** Only ever tells you whether a key exists — never its value. */
  secretPresent: (key: string) => call<boolean>("secret_present", { key }),
  secretSet: (key: string, value: string) => callOrThrow<void>("secret_set", { key, value }),
  secretClear: (key: string) => callOrThrow<void>("secret_clear", { key }),

  // ── Integrations ──────────────────────────────────────────────────────────
  refreshIntegration: (id: string) => call<void>("refresh_integration", { id }),
  /** Opens the configured n8n instance in the browser. */
  openN8n: () => call<void>("open_n8n"),

  /** Tray → Pause. Stops the integration pollers, not just the island. */
  setPaused: (paused: boolean) => call<void>("set_paused", { paused }),
};

export interface IntegrationUpdate {
  id: string;
  data: Record<string, unknown>;
  error: string | null;
  event: { success: boolean; label: string; detail: string | null } | null;
}

export type ChatContext =
  | { kind: "file"; name: string; path: string }
  | { kind: "window"; appName: string; title: string; url?: string }
  | ({ kind: "code" } & CodeContext);

/** What the VS Code / Cursor extension says about the active editor. */
export interface CodeContext {
  file: string;
  workspace?: string;
  language?: string;
  line?: number;
  selection?: string;
  diagnostics?: { line: number; severity: string; message: string; source?: string }[];
  appName?: string;
}

export interface SkillInfo {
  name: string;
  description: string;
  source: "personal" | "project" | "plugin" | "codex";
  /** The project folder, or the plugin's name. */
  origin: string | null;
  path: string;
  enabled: boolean;
  /** Plugin skills can't be turned off one by one. */
  editable: boolean;
  hasScripts: boolean;
  modified: number;
}

export interface SkillText {
  name: string;
  path: string;
  content: string;
  files: string[];
}

export interface SkillPreview {
  token: string;
  skills: { name: string; description: string; files: string[]; hasScripts: boolean; dest: string; exists: boolean }[];
}

export interface DroppedFile {
  name: string;
  path: string;
  size: number;
}

export interface HookStatus {
  installed: boolean;
  /** Installed, but not what this version writes: offer an update. */
  outdated?: boolean;
  settingsPath: string;
  hookPath: string;
  hookReady: boolean;
}

export interface HookPreview {
  diff: string;
  backup: string;
  settingsPath: string;
  /** Hand back to hooksApply so only the reviewed diff is ever written. */
  fingerprint: string;
}

/** Same as `call`, but surfaces the error so the UI can show what went wrong. */
async function callOrThrow<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  if (!IS_TAURI) throw new Error("not running inside Coucou");
  return invoke<T>(cmd, args);
}

export type BridgeEvent =
  | { name: "cursor"; payload: { x: number; y: number } }
  | { name: "tray"; payload: string }
  | { name: "hook"; payload: Record<string, unknown> }
  | { name: "screen-changed"; payload: null };

export interface DragDropPayload {
  type: "enter" | "over" | "drop" | "leave";
  paths?: string[];
  /** Physical pixels in the window, when the platform reports it (Linux). */
  position?: { x: number; y: number };
}

/** Files dragged onto the island. Only reaches us when the window takes the mouse. */
export async function onDragDrop(handler: (e: DragDropPayload) => void) {
  if (!IS_TAURI) return () => {};
  return getCurrentWebview().onDragDropEvent((event) => {
    handler(event.payload as DragDropPayload);
  });
}

export async function onEvent<T>(name: string, handler: (payload: T) => void) {
  if (!IS_TAURI) return () => {};
  return listen<T>(name, (e) => handler(e.payload));
}
