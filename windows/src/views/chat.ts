// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge, type ChatContext } from "../core/bridge";
import { saveCurrent, startNewChat } from "../core/chats";
import { Sound } from "../core/sound";
import { State, type ChatMessage } from "../core/state";
import type { ViewHost } from "./views";

let nextId = 1;

function bubble(message: ChatMessage): HTMLElement {
  if (message.role === "user") {
    return h(
      "div",
      { class: "chat-row user" },
      h("div", { class: "bubble", text: message.content }),
    );
  }
  return h("div", { class: "chat-row" }, h("div", { class: "reply", text: message.content }));
}

function typingDots(): HTMLElement {
  return h(
    "div",
    { class: "chat-row" },
    h("div", { class: "typing" }, h("i"), h("i"), h("i")),
  );
}

/** The coloured chip showing what the question is about (a dropped file). */
function contextChip(label: string): HTMLElement {
  const chip = h("div", { class: "chip" }, h("i", { class: "chip-dot" }), h("span", { text: label }));
  requestAnimationFrame(() => chip.classList.add("settled"));
  return chip;
}

/** "app.ts:42" for an editor context. */
function codeLabel(file: string, line?: number): string {
  const name = file.split(/[\\/]/).pop() ?? file;
  return line ? `${name}:${line}` : name;
}

export function buildPrompt(onHeightChange: () => void, openHistory: () => void = () => {}): ViewHost {
  const chipRow = h("div", { class: "chip-row" });
  const contextSlot = h("div", { class: "chip-slot" });
  // Attach the editor's file (VS Code / Cursor extension) when it was used lately.
  const attach = h("button", { class: "chip-attach" });
  attach.addEventListener("click", () => {
    const ctx = State.editorContext;
    if (!ctx) return;
    const { at: _at, ...code } = ctx;
    State.codeContext = code;
    State.notify();
  });
  const newBtn = h("button", { class: "chip-action", text: "New chat", onclick: () => {
    startNewChat();
    State.droppedFile = null;
    State.notify();
    onHeightChange();
  } });
  const historyBtn = h("button", { class: "chip-action", text: "History", onclick: () => openHistory() });
  chipRow.append(contextSlot, attach, h("div", { style: "flex:1" }), newBtn, historyBtn);
  const log = h("div", { class: "chat-log" });
  const input = h("input", {
    type: "text",
    class: "chat-input",
    placeholder: "Ask me anything…",
    spellcheck: "false",
  }) as HTMLInputElement;
  const send = h("button", { class: "send-btn", title: "Send" }, svg(ICONS.arrowUp, 11));
  const bar = h("div", { class: "chat-bar" }, input, send);

  const el = h(
    "div",
    { class: "view" },
    h("div", { class: "card wash chat-card" }, h("div", { class: "chat-body" }, chipRow, log, bar)),
  );
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let sending = false;
  let renderedCount = -1;

  async function submit() {
    const query = input.value.trim();
    if (!query || sending) return;
    input.value = "";
    sending = true;
    Sound.play("send");

    State.chatHistory.push({ id: nextId++, role: "user", content: query });
    State.stateOverride = "thinking";
    State.notify();
    onHeightChange();

    const file = State.droppedFile;
    const code = State.codeContext;
    const first = State.chatHistory.length === 1;
    const context: ChatContext | null =
      first && code ? { kind: "code", ...code }
      : first && file ? { kind: "file", name: file.name, path: file.path }
      : null;

    try {
      const reply = await Bridge.chatSend(query, context);
      State.chatHistory.push({ id: nextId++, role: "assistant", content: reply.text });
      State.stateOverride = null;
      Sound.play("finish");
      void saveCurrent();
      speak(reply.text);
    } catch (err) {
      State.stateOverride = null;
      State.noteMessage = String(err).replace(/^Error:\s*/, "");
      State.view = "note";
      Sound.play("error");
    } finally {
      sending = false;
      State.notify();
      onHeightChange();
      input.focus();
    }
  }

  send.addEventListener("click", () => void submit());
  input.addEventListener("keydown", (e) => {
    if ((e as KeyboardEvent).key === "Enter") {
      e.preventDefault();
      void submit();
    }
    e.stopPropagation(); // Escape closes the island, not the chat
  });

  return {
    el,
    sync() {
      const file = State.droppedFile;
      const code = State.codeContext;
      const wantChip = code ? codeLabel(code.file, code.line) : file?.name ?? "";
      if (contextSlot.dataset.label !== wantChip) {
        contextSlot.dataset.label = wantChip;
        clear(contextSlot);
        if (wantChip) contextSlot.append(contextChip(wantChip));
      }
      const editor = State.editorContext;
      const offer = !code && !file && State.chatHistory.length === 0 && editor && Date.now() - editor.at < 10 * 60_000;
      attach.style.display = offer ? "" : "none";
      if (offer && editor) attach.textContent = `+ ${codeLabel(editor.file, editor.line)}`;
      newBtn.style.display = State.chatHistory.length ? "" : "none";
      historyBtn.style.display = State.chats.length ? "" : "none";

      const thinking = State.stateOverride === "thinking";
      const count = State.chatHistory.length + (thinking ? 0.5 : 0);
      if (count !== renderedCount) {
        renderedCount = count;
        clear(log);
        for (const m of State.chatHistory) log.append(bubble(m));
        if (thinking) log.append(typingDots());
        log.scrollTop = log.scrollHeight;
      }

      input.placeholder = State.chatHistory.length === 0 ? "Ask me anything…" : "Continue…";
      input.disabled = sending;
    },
    focus() {
      input.focus();
      input.select();
    },
  };
}

/** Mochi reads the reply aloud (Settings → Voice); see src/core/voice.ts. */
let speakHook: (text: string) => void = () => {};
export function setSpeaker(fn: (text: string) => void) {
  speakHook = fn;
}
function speak(text: string) {
  speakHook(text);
}
