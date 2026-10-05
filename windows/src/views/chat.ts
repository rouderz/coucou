// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge, type ChatContext, type DriveFile, type SkillInfo } from "../core/bridge";
import { attachToChat } from "./integrations";
import { matchSkills, withSkill } from "../core/skills";
import { saveCurrent, startNewChat } from "../core/chats";
import { Sound } from "../core/sound";
import { State, type ChatMessage } from "../core/state";
import type { ViewHost } from "./views";
import { beginCapture } from "./capture";
import { draftFromAnswer } from "../core/capture";

let nextId = 1;

/** "focus 50 min on SHO-475": answered here, never sent to the model (#119). Set by main.ts. */
let focusCommand: (query: string) => string | null = () => null;

export function setFocusCommand(fn: (query: string) => string | null) {
  focusCommand = fn;
}

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

export function buildPrompt(
  onHeightChange: () => void,
  openHistory: () => void = () => {},
  openCapture: () => void = () => {},
): ViewHost {
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
  // "Make this a Linear issue" (#118): the last answer as a draft, same preview and Enter twice.
  const linearBtn = h("button", { class: "chip-action", text: "→ Linear", title: "Make this a Linear issue" });
  linearBtn.addEventListener("click", () => {
    const last = State.chatHistory[State.chatHistory.length - 1];
    const draft = last?.role === "assistant" ? draftFromAnswer(last.content) : null;
    if (!draft) return;
    beginCapture(draft.line, { label: "Chat answer", text: draft.description }, true);
    openCapture();
  });
  chipRow.append(contextSlot, skillChip, attach, h("div", { style: "flex:1" }), linearBtn, newBtn, historyBtn);
  const log = h("div", { class: "chat-log" });
  // "/" at the start of the field lists the skills, "@" searches Google Drive —
  // both in the log's place.
  const picker = h("div", { class: "skill-picker", style: "display:none" });
  interface PickItem { label: string; detail: string; run: () => void }
  let skills: SkillInfo[] | null = null;
  let googleOn: boolean | null = null;
  let matches: PickItem[] = [];
  let emptyText = "";
  let pickIndex = 0;
  let driveTimer: number | null = null;
  let driveQuery = "";

  function pickerOpen(): boolean {
    return picker.style.display !== "none";
  }

  function closePicker() {
    picker.style.display = "none";
    log.style.display = "";
  }

  function drawPicker() {
    clear(picker);
    if (!matches.length) picker.append(h("div", { class: "skill-pick empty", text: emptyText }));
    matches.forEach((m, i) => {
      const item = h("button", { class: i === pickIndex ? "skill-pick on" : "skill-pick" },
        h("b", { text: m.label }),
        h("span", { text: m.detail }),
      );
      item.addEventListener("mousedown", (e) => {
        e.preventDefault();
        m.run();
      });
      picker.append(item);
    });
    picker.style.display = "";
    log.style.display = "none";
  }

  function skillItem(s: SkillInfo): PickItem {
    return {
      label: `/${s.name}`,
      detail: s.description,
      run: () => {
        State.chatSkill = { name: s.name, path: s.path };
        input.value = "";
        closePicker();
        State.notify();
        input.focus();
      },
    };
  }

  function driveItem(f: DriveFile): PickItem {
    return {
      label: f.name,
      detail: f.mimeType.includes("spreadsheet") ? "Sheet" : f.mimeType.includes("document") ? "Doc"
        : f.mimeType.includes("presentation") ? "Slides" : (f.modified || "").slice(0, 10),
      run: async () => {
        input.value = "";
        emptyText = "Downloading…";
        matches = [];
        drawPicker();
        try {
          attachToChat(await Bridge.driveAttach(f.id, f.name, f.mimeType), false);
          closePicker();
        } catch (err) {
          emptyText = String(err).replace(/^Error:\s*/, "");
          drawPicker();
        }
        input.focus();
      },
    };
  }

  async function searchDrive(text: string) {
    driveQuery = text;
    emptyText = "Searching Drive…";
    try {
      const files = await Bridge.driveSearch(text);
      if (driveQuery !== text || !input.value.startsWith("@")) return;
      matches = files.map(driveItem);
      emptyText = "No Drive file with that name.";
    } catch (err) {
      matches = [];
      emptyText = String(err).replace(/^Error:\s*/, "");
    }
    pickIndex = 0;
    drawPicker();
  }

  async function updatePicker() {
    const v = input.value;
    if (v.startsWith("@")) {
      if (googleOn === null) googleOn = (await Bridge.googleConnected()) ?? false;
      if (!googleOn) {
        matches = [];
        emptyText = "Connect Google in Settings → Google to search your Drive.";
        drawPicker();
        return;
      }
      if (driveTimer != null) window.clearTimeout(driveTimer);
      if (!pickerOpen()) {
        matches = [];
        emptyText = "Searching Drive…";
        drawPicker();
      }
      driveTimer = window.setTimeout(() => void searchDrive(v.slice(1).trim()), 350);
      return;
    }
    if (!v.startsWith("/") || v.includes(" ")) {
      if (pickerOpen()) closePicker();
      return;
    }
    if (!skills) skills = (await Bridge.skillsList()) ?? [];
    matches = matchSkills(skills, v).map(skillItem);
    emptyText = skills.length ? "No skill matches." : "No skills installed. Add some in Settings → Skills.";
    pickIndex = Math.min(pickIndex, Math.max(0, matches.length - 1));
    drawPicker();
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
    if (!State.chatSkill) {
      const answer = focusCommand(query);
      if (answer !== null) {
        Sound.play("send");
        State.chatHistory.push({ id: nextId++, role: "user", content: query });
        State.chatHistory.push({ id: nextId++, role: "assistant", content: answer });
        State.notify();
        onHeightChange();
        input.focus();
        return;
      }
    }
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
    // A mail or a Drive file attached mid-chat goes with this question.
    const fileNow = first || State.attachNext;
    State.attachNext = false;
    const context: ChatContext | null =
      first && code ? { kind: "code", ...code }
      : fileNow && file ? { kind: "file", name: file.name, path: file.path }
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
        matches[pickIndex].run();
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
      const lastMsg = State.chatHistory[State.chatHistory.length - 1];
      const linearOn = State.integrations.integration_linear?.configured ?? false;
      linearBtn.style.display = linearOn && lastMsg?.role === "assistant" && State.stateOverride !== "thinking" ? "" : "none";

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
          : State.chatHistory.length === 0 ? "Ask me anything… (/ skills, @ Drive)" : "Continue…";
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
