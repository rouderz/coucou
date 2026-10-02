// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge, type ChatContext, type SkillInfo } from "../core/bridge";
import { matchSkills, withSkill } from "../core/skills";
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
  // The skill picked with "/" — click it to drop it.
  const skillChip = h("button", { class: "chip-attach skill-chip", title: "Remove the skill" });
  skillChip.addEventListener("click", () => {
    State.chatSkill = null;
    State.notify();
  });
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
  chipRow.append(contextSlot, skillChip, attach, h("div", { style: "flex:1" }), newBtn, historyBtn);
  const log = h("div", { class: "chat-log" });
  // "/" at the start of the field lists the skills, in the log's place.
  const picker = h("div", { class: "skill-picker", style: "display:none" });
  let skills: SkillInfo[] | null = null;
  let matches: SkillInfo[] = [];
  let pickIndex = 0;

  function pickerOpen(): boolean {
    return picker.style.display !== "none";
  }

  function closePicker() {
    picker.style.display = "none";
    log.style.display = "";
  }

  function drawPicker() {
    clear(picker);
    if (!matches.length) {
      picker.append(h("div", { class: "skill-pick empty", text: skills?.length ? "No skill matches." : "No skills installed. Add some in Settings → Skills." }));
    }
    matches.forEach((s, i) => {
      const item = h("button", { class: i === pickIndex ? "skill-pick on" : "skill-pick" },
        h("b", { text: `/${s.name}` }),
        h("span", { text: s.description }),
      );
      item.addEventListener("mousedown", (e) => {
        e.preventDefault();
        choose(s);
      });
      picker.append(item);
    });
    picker.style.display = "";
    log.style.display = "none";
  }

  async function updatePicker() {
    const v = input.value;
    if (!v.startsWith("/") || v.includes(" ")) {
      if (pickerOpen()) closePicker();
      return;
    }
    if (!skills) skills = (await Bridge.skillsList()) ?? [];
    matches = matchSkills(skills, v);
    pickIndex = Math.min(pickIndex, Math.max(0, matches.length - 1));
    drawPicker();
  }

  function choose(s: SkillInfo) {
    State.chatSkill = { name: s.name, path: s.path };
    input.value = "";
    closePicker();
    State.notify();
    input.focus();
  }
  const input = h("input", {
    type: "text",
    class: "chat-input",
    placeholder: "Ask me anything…",
    spellcheck: "false",
  }) as HTMLInputElement;
  const send = h("button", { class: "send-btn", title: "Send" }, svg(ICONS.arrowUp, 11));
  // Push-to-talk (Windows): say the question; it's typed in and sent.
  const mic = h("button", { class: "mic-btn", title: "Speak your question", text: "🎙" });
  mic.addEventListener("click", async () => {
    if (sending || mic.classList.contains("on")) return;
    mic.classList.add("on");
    input.placeholder = "Listening…";
    try {
      input.value = await Bridge.voiceListen();
      void submit();
    } catch (err) {
      State.noteMessage = String(err).replace(/^Error:\s*/, "");
      State.view = "note";
      State.notify();
    } finally {
      mic.classList.remove("on");
    }
  });
  const bar = h("div", { class: "chat-bar" }, input, mic, send);

  const el = h(
    "div",
    { class: "view" },
    h("div", { class: "card wash chat-card" }, h("div", { class: "chat-body" }, chipRow, log, picker, bar)),
  );
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let sending = false;
  let renderedCount = -1;

  async function submit() {
    const query = input.value.trim();
    if (!query || sending) return;
    input.value = "";
    closePicker();
    const skill = State.chatSkill;
    State.chatSkill = null;
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
      let sent = query;
      if (skill) {
        const text = await Bridge.skillRead(skill.path);
        sent = withSkill(skill.name, text.path, text.content, query);
      }
      const reply = await Bridge.chatSend(sent, context);
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
  input.addEventListener("input", () => void updatePicker());
  input.addEventListener("keydown", (e) => {
    const key = (e as KeyboardEvent).key;
    if (pickerOpen()) {
      if (key === "ArrowDown" || key === "ArrowUp") {
        e.preventDefault();
        const n = matches.length || 1;
        pickIndex = (pickIndex + (key === "ArrowDown" ? 1 : n - 1)) % n;
        drawPicker();
      } else if ((key === "Enter" || key === "Tab") && matches[pickIndex]) {
        e.preventDefault();
        choose(matches[pickIndex]);
      } else if (key === "Escape") {
        e.preventDefault();
        input.value = "";
        closePicker();
      }
      e.stopPropagation();
      return;
    }
    if (key === "Enter") {
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
      const sk = State.chatSkill;
      skillChip.style.display = sk ? "" : "none";
      if (sk) skillChip.textContent = `✦ ${sk.name} ×`;
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

      if (!mic.classList.contains("on")) {
        input.placeholder = State.chatSkill ? "What should it do?"
          : State.chatHistory.length === 0 ? "Ask me anything… (/ for skills)" : "Continue…";
      }
      mic.style.display = canListen ? "" : "none";
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

/** Whether push-to-talk is offered (Windows' speech recognition). */
let canListen = false;
export function setListening(on: boolean) {
  canListen = on;
}
