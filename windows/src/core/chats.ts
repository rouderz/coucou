// Saved chats (macOS ChatStore): the newest 50 conversations, on this computer.
// Reopening one picks it back up in every engine — the text for the API and
// other providers, the session for Claude Code.

import { Bridge } from "./bridge";
import { State, type ChatMessage } from "./state";

export interface SavedChat {
  id: string;
  title: string;
  updatedAt: number;
  messages: { user: boolean; text: string }[];
  sessionId?: string | null;
  workDir?: string | null;
}

let loaded = false;

export async function loadChats() {
  if (loaded) return;
  loaded = true;
  const list = (await Bridge.chatsLoad()) ?? [];
  State.chats = (list as SavedChat[]).filter((c) => c && Array.isArray(c.messages));
  State.notify();
}

/** The chat's title: its first question, shortened. */
export function chatTitle(messages: { user: boolean; text: string }[]): string {
  const first = messages.find((m) => m.user)?.text.trim() ?? "Chat";
  const line = first.split("\n")[0];
  return line.length > 60 ? `${line.slice(0, 57)}…` : line;
}

/** Saves (or updates) the chat on screen, newest first. */
export async function saveCurrent() {
  if (!State.chatHistory.length) return;
  const info = (await Bridge.chatSessionInfo()) ?? { sessionId: null, workDir: null };
  const messages = State.chatHistory.map((m) => ({ user: m.role === "user", text: m.content }));
  const id = State.currentChatId ?? `${Date.now()}`;
  State.currentChatId = id;
  const chat: SavedChat = {
    id, title: chatTitle(messages), updatedAt: Date.now(), messages,
    sessionId: info.sessionId, workDir: info.workDir,
  };
  State.chats = [chat, ...State.chats.filter((c) => c.id !== id)].slice(0, 50);
  await Bridge.chatsSave(State.chats);
  State.notify();
}

/** A fresh conversation (new chat button, a dropped file, Ask Mochi from the editor). */
export function startNewChat() {
  State.chatHistory = [];
  State.currentChatId = null;
  State.codeContext = null;
  void Bridge.chatReset();
}

let nextId = 100_000;

export function openChat(chat: SavedChat) {
  startNewChat();
  State.currentChatId = chat.id;
  State.chatHistory = chat.messages.map<ChatMessage>((m) => ({
    id: nextId++, role: m.user ? "user" : "assistant", content: m.text,
  }));
  void Bridge.chatRestore(chat.messages, chat.sessionId ?? null, chat.workDir ?? null);
  State.notify();
}

export async function deleteChat(chat: SavedChat) {
  State.chats = State.chats.filter((c) => c.id !== chat.id);
  if (chat.workDir) void Bridge.chatDeleteDir(chat.workDir);
  if (State.currentChatId === chat.id) startNewChat();
  await Bridge.chatsSave(State.chats);
  State.notify();
}
