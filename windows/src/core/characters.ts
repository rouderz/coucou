// The character rail (island design C) — port of NotchBuddy/Sources/App/Views/CharacterRail.swift.
//
// Once an integration has its own character, the island's left side lists the characters: the
// main one (Claude Code, Chat and Code) on top, then one per integration. Picking one shows its
// base; an integration's character also has its own chat about what it handles, kept apart from
// the main character's conversations.

import { CRITTER_INFO, assignments, currentCritter, tintFor, type CritterId } from "../mochi/critters";
import { openChat, saveCurrent, startNewChat } from "./chats";
import type { IslandViewName } from "./layout";
import { State } from "./state";

/** Where the rail shows: the overview and the chat. */
export const RAIL_VIEWS = new Set<IslandViewName>(["overview", "empty", "prompt", "searching", "result"]);

/** Integrations on screen with their own character, in task order. */
export function assignedTaskIds(): string[] {
  const own = assignments(State.settings.critterAssignments);
  return State.tasks.filter((t) => t.id !== "integration_claude" && own[t.id]).map((t) => t.id);
}

export function railShown(): boolean {
  return State.mode === "expanded" && RAIL_VIEWS.has(State.view) && assignedTaskIds().length > 0;
}

/** The character in charge of a task: its own, or the main one. */
export function characterFor(taskId: string | null): CritterId {
  return (taskId && assignments(State.settings.critterAssignments)[taskId]) || currentCritter();
}

/** That character's colour (the user's, or its own when the same character is used twice). */
export function characterTint(taskId: string | null): string | null {
  if (!taskId) return null;
  return tintFor(taskId, assignments(State.settings.critterAssignments), State.settings.critterColors, currentCritter());
}

/** "Pip" for the character in charge of this task. */
export function characterName(taskId: string | null): string {
  return CRITTER_INFO[characterFor(taskId)].name;
}

/** Picks whose island this is: the main character (null) or an integration with its own. */
export function selectCharacter(taskId: string | null) {
  if (taskId) {
    State.soloTaskId = taskId;
    State.focusId = taskId;
    return;
  }
  State.soloTaskId = null;
  const own = assignments(State.settings.critterAssignments);
  // With the rail, the main character's base is Claude Code.
  if (assignedTaskIds().length && State.tasks.some((t) => t.id === "integration_claude")) {
    State.focusId = "integration_claude";
    return;
  }
  if (State.focusId && !own[State.focusId]) return;
  const first = State.tasks.find((t) => !own[t.id]);
  if (first) State.focusId = first.id;
}

/** The island's height while the rail shows (design C). */
export const RAIL_HEIGHT = 236;

/** The main character's base shows Claude Code unless one of its integrations was picked. */
export function showsClaude(): boolean {
  const task = State.focusTask;
  return !task || task.id === "integration_claude" || (!task.isIntegration && task.source === "claudeCode");
}

/** What an integration's base tab is called: its mail, its tickets, its orders… */
export function baseTab(taskId: string): string {
  switch (taskId) {
    case "integration_gmail": case "integration_resend": return "Mail";
    case "integration_whaticket": return "Tickets";
    case "integration_aliexpress": return "Orders";
    case "integration_github": return "PRs";
    case "integration_linear": return "Issues";
    case "integration_calcom": return "Calendar";
    default: return "Home";
  }
}

/** The main character's mode when a character's chat took over, to come back to it. */
let returnMode: "chat" | "code" = "chat";

async function stashOwner() {
  const owner = State.chatOwner;
  if (!owner) return;
  await saveCurrent();
  if (State.currentChatId) State.stashedCharacterChats[owner] = State.currentChatId;
  State.chatOwner = null;
  State.characterPreamble = null;
}

/** An integration's character's own chat, about what that integration shows. */
export async function openCharacterChat(taskId: string) {
  const task = State.tasks.find((t) => t.id === taskId);
  if (!task) return;
  if (State.chatOwner !== taskId) {
    if (State.chatOwner) {
      await stashOwner();
    } else {
      await saveCurrent();
      State.stashedChatIds[State.chatMode] = State.currentChatId;
      returnMode = State.chatMode;
    }
    const id = State.stashedCharacterChats[taskId];
    const chat = id ? State.chats.find((c) => c.id === id) : undefined;
    if (chat) {
      openChat(chat);
    } else {
      startNewChat();
    }
    State.chatMode = "chat";
    State.promptContext = null;
    State.droppedFile = null;
    const lines = [
      `You are ${characterName(taskId)}, the character in charge of ${task.name} in Coucou.`,
      `Answer questions about ${task.name} using what it shows right now:`,
      ...(task.steps.length ? task.steps.map((s) => `- ${s}`) : ["(nothing to show yet)"]),
    ];
    State.characterPreamble = chat ? null : lines.join("\n");
    State.chatOwner = taskId;
  }
  State.soloTaskId = taskId;
  State.view = "prompt";
  State.notify();
}

/** Back to the main character: the character's chat is kept for later, the main one's
 *  conversation comes back. */
export async function leaveCharacterChat() {
  if (!State.chatOwner) return;
  await stashOwner();
  const id = State.stashedChatIds[returnMode];
  const chat = id ? State.chats.find((c) => c.id === id) : undefined;
  if (chat) openChat(chat);
  else startNewChat();
  State.chatMode = returnMode;
}

/** "Ask Pip about Gmail…" while a character's chat is empty. */
export function characterPlaceholder(): string | null {
  const owner = State.chatOwner;
  if (!owner) return null;
  const task = State.tasks.find((t) => t.id === owner);
  if (!task) return null;
  return `Ask ${characterName(owner)} about ${task.name}…`;
}

