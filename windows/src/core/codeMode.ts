// Chat / Code (#149, #152) — port of NotchBuddy/Sources/App/CodeMode.swift.
//
// Chat: the conversation with the engine picked in Settings, about anything.
// Code: Claude Code at work in a folder you pick — it reads and searches the project, and with
// edits on it changes files and runs commands, each one approved in the island. Each mode keeps
// its own conversation: switching saves the one on screen and brings back the other's.

import { Bridge } from "./bridge";
import { openChat, saveCurrent, startNewChat } from "./chats";
import { State } from "./state";
import { leaveCharacterChat, selectCharacter } from "./characters";

const MAX_RECENT = 6;

/** "coucou" for "C:\\code\\coucou" or "/home/me/code/coucou". */
export function folderName(path: string): string {
  return path.split(/[\\/]/).filter(Boolean).pop() ?? path;
}

/** Shows Chat or Code, each with its own conversation. */
export async function showMode(mode: "chat" | "code") {
  // Back from an integration character's own chat to the main character's.
  if (State.chatOwner || State.soloTaskId) {
    await leaveCharacterChat();
    selectCharacter(null);
  }
  if (mode !== State.chatMode) {
    await saveCurrent();
    State.stashedChatIds[State.chatMode] = State.currentChatId;
    State.chatMode = mode;
    const id = State.stashedChatIds[mode];
    const chat = id ? State.chats.find((c) => c.id === id) : undefined;
    if (chat) {
      openChat(chat);
      State.chatMode = mode;
    } else {
      startNewChat();
    }
  }
  State.notify();
}

/** Code mode starts working in this folder; a conversation about another folder is kept in
 *  the history and a new one starts. */
export async function useFolder(folder: string) {
  if (State.settings.codeFolder !== folder && State.chatHistory.length) {
    await saveCurrent();
    startNewChat();
  }
  State.settings.codeFolder = folder;
  const atHand = State.settings.codeFolders ?? [];
  if (!atHand.includes(folder)) State.settings.codeFolders = [...atHand, folder];
  State.settings.recentCodeFolders = [folder, ...(State.settings.recentCodeFolders ?? []).filter((f) => f !== folder)]
    .slice(0, MAX_RECENT);
  State.codeEdits = true;
  void Bridge.saveSettings(State.settings);
  State.notify();
}

/** The system's folder picker. */
export async function pickFolder() {
  const folder = await Bridge.pickFolder(State.settings.codeFolder ?? null);
  if (folder) await useFolder(folder);
}

/** Code mode, working in that folder (the folder chips on the main character's base). */
export async function workIn(folder: string) {
  await showMode("code");
  await useFolder(folder);
}

/** Adds a folder to the ones kept at hand, and works in it. */
export async function addFolder() {
  const folder = await Bridge.pickFolder(State.settings.codeFolder ?? null);
  if (folder) await workIn(folder);
}

/** Drops a folder from the ones kept at hand. */
export function removeFolder(folder: string) {
  State.settings.codeFolders = (State.settings.codeFolders ?? []).filter((f) => f !== folder);
  void Bridge.saveSettings(State.settings);
  State.notify();
}

/** Folders worth offering: the recent ones, then the folders of live Claude Code sessions. */
export function folderSuggestions(): string[] {
  const all = [...(State.settings.recentCodeFolders ?? []), ...State.sessions.map((s) => s.cwd)];
  return [...new Set(all.filter(Boolean))].slice(0, 8);
}
