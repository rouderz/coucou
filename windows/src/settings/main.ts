// Settings window — the place where anything that writes to disk is confirmed.
// Stage 2 covers the Claude Code hooks and the general preferences; API keys and
// integrations land here too in a later stage.

import "./settings.css";
import { setLanguage, startTranslating } from "../core/i18n.ts";
import { Bridge, onDragDrop, onEvent, type BrowserStatus, type HookStatus, type SkillInfo, type SkillPreview } from "../core/bridge";
import { DEFAULT_SETTINGS, type Settings } from "../core/state";
import { parseTeams, type TeamInfo } from "../core/capture";
import { h, clear } from "../views/dom";
import { THEMES, applyTheme } from "../core/themes.ts";
import { dayKey as wtDayKey, duration, range, summary, toCsv as wtToCsv, type Period, type StatEvent } from "../core/whaticketStats.ts";
import {
  addAdjustment, dayKey, formatDuration, formatHours, groupPeriod, parseStore, recentPeriods, rowsFromStore,
  serializeStore, toCsv, toText, type DayRow, type TimeStore,
} from "../core/timetrack.ts";

let settings: Settings = { ...DEFAULT_SETTINGS };
let version = "";
/** Where keys are kept, named the way the user knows it. */
let keychainName = "the Windows Credential Manager";

const root = document.getElementById("settings-root")!;

async function save() {
  await Bridge.saveSettings(settings);
}

// ── Reusable bits ─────────────────────────────────────────────────────────────

function toggle(on: boolean, onChange: (v: boolean) => void): HTMLElement {
  const el = h("button", { class: on ? "switch on" : "switch", "aria-pressed": on });
  el.addEventListener("click", () => {
    const next = !el.classList.contains("on");
    el.classList.toggle("on", next);
    onChange(next);
  });
  return el;
}

function statusDot(ok: boolean): HTMLElement {
  return h("i", { class: "dot", style: `background:${ok ? "#22c55e" : "#f4505e"}` });
}

function renderDiff(text: string): HTMLElement {
  const box = h("div", { class: "diff" });
  for (const line of text.split("\n")) {
    const cls = line.startsWith("+") ? "add" : line.startsWith("-") ? "del" : "ctx";
    box.append(h("div", { class: cls, text: line }));
  }
  return box;
}

// ── Claude Code section ───────────────────────────────────────────────────────

function claudeSection(status: HookStatus): HTMLElement {
  const body = h("div", { style: "display:flex;flex-direction:column;gap:12px" });
  const section = h(
    "section",
    {},
    h("h2", {}, statusDot(status.installed), h("span", { text: "Claude Code" })),
    body,
  );

  const rebuild = async () => {
    const fresh = await Bridge.hooksStatus();
    if (fresh) Object.assign(status, fresh);
    clear(body);
    draw();
    const head = section.querySelector("h2")!;
    clear(head);
    head.append(statusDot(status.installed), h("span", { text: "Claude Code" }));
  };

  function draw() {
    body.append(
      h("div", {
        class: "hint",
        text: status.outdated
          ? "Coucou's hooks are installed but out of date. Update them to get every event and approvals that don't time out."
          : status.installed
          ? "Coucou is hooked into your Claude Code sessions. Tool calls, questions and permission requests show up in the island, and you can answer them there."
          : "Install the hooks to see your Claude Code sessions in the island and approve permissions without leaving what you are doing.",
      }),
      h("div", {
        class: "hint",
        text: "The plan usage bars come from Claude Code's status line: the hooks add Coucou's, unless you already have your own (then it stays, and the bars stay empty).",
      }),
      h("div", { class: "row" },
        h("label", { text: "settings.json" }),
        h("span", { class: "path", text: status.settingsPath }),
      ),
      h("div", { class: "row" },
        h("label", { text: "Relay" }),
        h("span", { class: "path", text: status.hookPath }),
        statusDot(status.hookReady),
      ),
    );

    if (!status.hookReady) {
      body.append(h("div", {
        class: "notice warn",
        text: "The relay (coucou-hook) is not in place yet. Restart Coucou; if it still fails, build it with `cargo build -p coucou-hook`.",
      }));
    }

    const actions = h("div", { class: "row" });
    const install = h("button", {
      class: "primary",
      text: status.outdated ? "Update hooks…" : status.installed ? "Reinstall hooks…" : "Install hooks…",
      onclick: () => showPreview(true),
    });
    // Writing hook commands that point at a relay which isn't there would give
    // every Claude Code session a broken hook and nothing to show for it.
    if (!status.hookReady) {
      install.disabled = true;
      install.title = "The relay isn't installed yet.";
    }
    actions.append(install);
    if (status.installed) {
      actions.append(h("button", {
        class: "danger",
        text: "Uninstall hooks…",
        onclick: () => showPreview(false),
      }));
    }
    body.append(actions);
  }

  async function showPreview(install: boolean) {
    let preview;
    try {
      preview = await Bridge.hooksPreview(install);
    } catch (err) {
      // An unreadable or invalid settings.json stops here rather than being
      // treated as empty and written over.
      clear(body);
      body.append(
        h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }),
        h("div", { class: "row" }, h("button", {
          text: "Back",
          onclick: () => { clear(body); draw(); },
        })),
      );
      return;
    }
    if (!preview) return;
    clear(body);
    body.append(
      h("div", {
        class: "hint",
        text: install
          ? "This is exactly what will change in your settings.json. Your own hooks are left untouched."
          : "This removes Coucou's entries only. Your own hooks are left untouched.",
      }),
      renderDiff(preview.diff),
      h("div", { class: "row" },
        h("span", { class: "path", text: `Backup → ${preview.backup}` }),
      ),
    );
    const confirm = h("button", {
      class: install ? "primary" : "danger",
      text: install ? "Back up and write" : "Back up and remove",
    });
    confirm.addEventListener("click", async () => {
      confirm.disabled = true;
      try {
        const backup = await Bridge.hooksApply(install, preview.fingerprint);
        clear(body);
        body.append(h("div", {
          class: "notice ok",
          text: `Done. Previous settings saved as ${backup}. Open a new Claude Code session to pick the hooks up.`,
        }));
        window.setTimeout(() => void rebuild(), 2600);
      } catch (err) {
        confirm.disabled = false;
        body.append(h("div", { class: "notice err", text: `Could not write: ${String(err)}` }));
      }
    });
    body.append(h("div", { class: "row" }, confirm, h("button", {
      text: "Cancel",
      onclick: () => { clear(body); draw(); },
    })));
  }

  draw();
  return section;
}

// ── Codex CLI section (#44 on macOS) ──────────────────────────────────────────

function codexSection(initial: { found: boolean; installed: boolean; hooksPath: string }): HTMLElement {
  const body = h("div", { style: "display:flex;flex-direction:column;gap:10px" });
  const head = h("h2", {});
  const section = h("section", {}, head, body);
  let status = initial;

  function draw() {
    clear(head);
    head.append(statusDot(status.installed), h("span", { text: "Codex CLI" }));
    clear(body);
    body.append(h("div", {
      class: "hint",
      text: !status.found
        ? "Codex CLI isn't set up here yet. Install it and run it once to follow its sessions and approve them from the island too."
        : status.installed
        ? "Coucou's hooks are in Codex. Run /hooks in Codex once to review and trust them; its sessions then show up next to Claude Code's."
        : "Coucou can follow Codex CLI sessions and approve them from the island. Codex is never blocked if Coucou isn't running.",
    }));
    if (status.found) {
      body.append(h("div", { class: "row" },
        h("label", { text: "hooks.json" }), h("span", { class: "path", text: status.hooksPath })));
      const row = h("div", { class: "row" });
      const run = async (install: boolean) => {
        try {
          await Bridge.codexInstall(install);
        } catch (err) {
          body.append(h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }));
          return;
        }
        status = (await Bridge.codexStatus()) ?? status;
        draw();
      };
      row.append(h("button", {
        class: "primary",
        text: status.installed ? "Reinstall Codex hooks" : "Install Codex hooks",
        onclick: () => void run(true),
      }));
      if (status.installed) {
        row.append(h("button", { class: "danger", text: "Uninstall", onclick: () => void run(false) }));
      }
      body.append(row);
    }
  }
  draw();
  return section;
}

// ── Claude API section ────────────────────────────────────────────────────────

// Same list as the macOS app (Settings → Model).
const MODELS: [string, string][] = [
  ["claude-opus-5-5", "Claude Opus 5.5"],
  ["claude-fable-5-1", "Claude Fable 5.1"],
  ["claude-sonnet-5-5", "Claude Sonnet 5.5"],
  ["claude-haiku-4-5", "Claude Haiku 4.5"],
];

type Preset = { id: string; name: string; baseUrl: string; needsKey: boolean; defaultModel: string; keyHint: string };

/** "Other provider": OpenAI, Gemini, OpenRouter, Ollama, LM Studio or any OpenAI-compatible server. */
function providerBlock(presets: Preset[], present: Record<string, boolean>): HTMLElement {
  const box = h("div", { style: "display:flex;flex-direction:column;gap:10px" });
  const pick = h("select", {}) as HTMLSelectElement;
  for (const p of presets) pick.append(h("option", { value: p.id, text: p.name }));
  pick.value = settings.providerId || "openai";
  const server = h("input", { type: "text", spellcheck: "false", style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
  const modelInput = h("input", { type: "text", spellcheck: "false", style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
  const models = h("datalist", { id: "provider-models" });
  modelInput.setAttribute("list", "provider-models");
  const key = h("input", { type: "password", autocomplete: "off", spellcheck: "false", style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
  const keyDot = statusDot(false);
  const note = h("div", {});
  const current = () => presets.find((p) => p.id === pick.value) ?? presets[0];
  function fill() {
    const p = current();
    server.placeholder = p.baseUrl || "https://your-server/v1";
    server.value = settings.providerBaseUrl ?? "";
    modelInput.placeholder = p.defaultModel || "model name";
    modelInput.value = settings.providerModel ?? "";
    const k = `provider-key-${p.id}`;
    key.placeholder = present[k] ? "••••••••  (stored)" : p.keyHint || "not needed";
    keyDot.style.background = present[k] ? "#22c55e" : p.needsKey ? "#f4505e" : "#8e939c";
  }
  pick.addEventListener("change", () => {
    settings.providerId = pick.value;
    settings.providerBaseUrl = "";
    settings.providerModel = "";
    void save();
    fill();
  });
  server.addEventListener("change", () => { settings.providerBaseUrl = server.value.trim(); void save(); });
  modelInput.addEventListener("change", () => { settings.providerModel = modelInput.value.trim(); void save(); });
  const saveKey = h("button", { text: "Save", onclick: async () => {
    const k = `provider-key-${current().id}`;
    try {
      await Bridge.secretSet(k, key.value.trim());
      present[k] = key.value.trim().length > 0;
      key.value = "";
      fill();
    } catch (err) {
      clear(note);
      note.append(h("div", { class: "notice err", text: String(err) }));
    }
  } });
  const load = h("button", { text: "Load models", onclick: async () => {
    clear(note);
    try {
      const list = await Bridge.providerModels();
      clear(models);
      for (const m of list) models.append(h("option", { value: m }));
      note.append(h("div", { class: "hint", text: `${list.length} models — pick one in the field.` }));
    } catch (err) {
      note.append(h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }));
    }
  } });
  fill();
  box.append(
    h("div", { class: "row" }, h("label", { text: "Provider" }), pick),
    h("div", { class: "row" }, h("label", { text: "Server" }), server),
    h("div", { class: "row" }, h("label", { text: "Model" }), modelInput, load, models),
    h("div", { class: "row" }, h("label", { text: "API key" }), key, saveKey, keyDot),
    note,
  );
  return box;
}

function apiSection(
  hasKey: boolean,
  claudeCode: { installed: boolean; path: string | null },
  presets: Preset[],
  present: Record<string, boolean>,
): HTMLElement {
  const dot = statusDot(hasKey);
  const state = h("span", { class: "hint", text: hasKey ? `Key saved in ${keychainName}.` : "No key yet — the chat needs one." });

  const field = h("input", {
    type: "password",
    placeholder: hasKey ? "••••••••••••  (stored)" : "sk-ant-...",
    style: "flex:1 1 auto;min-width:0",
    autocomplete: "off",
    spellcheck: "false",
  }) as HTMLInputElement;

  const saveBtn = h("button", { class: "primary", text: "Save key" });
  const clearBtn = h("button", { class: "danger", text: "Remove" });
  const feedback = h("div", {});

  async function refresh() {
    const present = (await Bridge.secretPresent("anthropic-api-key")) ?? false;
    dot.style.background = present ? "#22c55e" : "#f4505e";
    state.textContent = present
      ? `Key saved in ${keychainName}.`
      : "No key yet — the chat needs one.";
    field.placeholder = present ? "••••••••••••  (stored)" : "sk-ant-...";
    clearBtn.style.display = present ? "" : "none";
  }

  saveBtn.addEventListener("click", async () => {
    const value = field.value.trim();
    if (!value) return;
    clear(feedback);
    try {
      await Bridge.secretSet("anthropic-api-key", value);
      field.value = "";
      feedback.append(h("div", { class: "notice ok", text: "Saved. It never touches disk." }));
      await refresh();
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: `Could not save: ${String(err)}` }));
    }
  });

  clearBtn.addEventListener("click", async () => {
    clear(feedback);
    try {
      await Bridge.secretClear("anthropic-api-key");
      feedback.append(h("div", { class: "notice ok", text: "Key removed." }));
      await refresh();
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: `Could not remove: ${String(err)}` }));
    }
  });

  const model = h("select", {}) as HTMLSelectElement;
  for (const [id, label] of MODELS) model.append(h("option", { value: id, text: label }));
  if (!MODELS.some(([id]) => id === settings.model)) {
    model.append(h("option", { value: settings.model, text: settings.model }));
  }
  model.value = settings.model;
  model.addEventListener("change", () => {
    settings.model = model.value;
    void save();
  });

  clearBtn.style.display = hasKey ? "" : "none";

  // Engine (#75): the user's Claude Code subscription, or an API key.
  const engine = h("select", {}) as HTMLSelectElement;
  engine.append(
    h("option", { value: "api", text: "Anthropic API key" }),
    h("option", { value: "claude-code", text: "Claude Code (your subscription)" }),
    h("option", { value: "provider", text: "Other provider (OpenAI, Gemini, Ollama…)" }),
    h("option", { value: "codex", text: "Codex (ChatGPT plan)" }),
    h("option", { value: "gemini", text: "Gemini CLI" }),
  );
  // Codex / Gemini CLI (#108): found? signed in? and the model to ask for.
  const cliNote = h("div", { class: "hint" });
  const cliModel = h("input", { type: "text", placeholder: "Default of the CLI", style: "width:220px" }) as HTMLInputElement;
  const cliRow = h("div", { class: "row" }, h("label", { text: "Model" }), cliModel);
  cliModel.addEventListener("change", () => {
    if (engine.value === "codex") settings.codexModel = cliModel.value.trim();
    else settings.geminiModel = cliModel.value.trim();
    void save();
  });
  async function showCli(id: "codex" | "gemini") {
    cliModel.value = (id === "codex" ? settings.codexModel : settings.geminiModel) ?? "";
    const name = id === "codex" ? "Codex" : "Gemini CLI";
    cliNote.className = "hint";
    cliNote.textContent = "Checking…";
    const st = await Bridge.cliChatStatus(id);
    if (engine.value !== id) return;
    if (!st?.path) {
      cliNote.className = "notice warn";
      cliNote.textContent = `${name} not found. Install it and sign in, then check again.`;
    } else if (st.signedIn === false) {
      cliNote.className = "notice warn";
      cliNote.textContent = `${name} isn't signed in · run codex login`;
    } else {
      cliNote.textContent = id === "codex"
        ? `Uses ${st.path} with your ChatGPT plan. It runs in its read-only sandbox in an empty folder: it can't touch your files.`
        : `Uses ${st.path} with your Google account. It runs in an empty folder, never in your projects.`;
    }
    dot.style.background = st?.path && st.signedIn !== false ? "#22c55e" : "#f4505e";
  }
  const providerBox = providerBlock(presets, present);
  engine.value = settings.chatEngine ?? "api";
  const keyRow = h("div", { class: "row" }, h("label", { text: "API key" }), field, saveBtn, clearBtn);
  const codeNote = h("div", {
    class: claudeCode.installed ? "hint" : "notice warn",
    text: claudeCode.installed
      ? `Uses ${claudeCode.path}, signed in with your Claude plan. No key needed; nothing about your sign-in is read or stored.`
      : "Claude Code isn't installed (or not on PATH). Install it and sign in with `claude`, then reopen Settings.",
  });
  const modelRow = h("div", { class: "row" }, h("label", { text: "Model" }), model);
  function showEngine() {
    const code = engine.value === "claude-code";
    const other = engine.value === "provider";
    const cli = engine.value === "codex" || engine.value === "gemini";
    keyRow.style.display = code || other || cli ? "none" : "";
    state.style.display = code || other || cli ? "none" : "";
    codeNote.style.display = code ? "" : "none";
    providerBox.style.display = other ? "" : "none";
    modelRow.style.display = other || cli ? "none" : "";
    cliNote.style.display = cli ? "" : "none";
    cliRow.style.display = cli ? "" : "none";
    if (cli) void showCli(engine.value as "codex" | "gemini");
    dot.style.background = code ? (claudeCode.installed ? "#22c55e" : "#f4505e") : dot.style.background;
  }
  engine.addEventListener("change", () => {
    settings.chatEngine = engine.value as Settings["chatEngine"];
    void save();
    if (engine.value === "api") void refresh();
    showEngine();
  });
  showEngine();

  return h(
    "section",
    {},
    h("h2", {}, dot, h("span", { text: "Chat" })),
    h("div", { class: "row" }, h("label", { text: "Engine" }), engine),
    state,
    codeNote,
    cliNote,
    cliRow,
    h("div", { class: "row" },
      h("label", { text: "Fallback" }),
      toggle(settings.chatFallback !== false, (v) => { settings.chatFallback = v; void save(); }),
      h("span", { class: "hint", text: "when the engine runs out of quota, the next one answers (Claude Code → Codex → Gemini → API)" })),
    keyRow,
    modelRow,
    providerBox,
    feedback,
  );
}

// ── Integrations section ──────────────────────────────────────────────────────

interface IntegrationDef {
  id: string;
  name: string;
  color: string;
  /** Credential Manager keys, in the order they are shown. */
  fields: { key: string; label: string; placeholder: string; secret: boolean }[];
  /** A line under the name when there is nothing to fill in. */
  hint?: string;
}

const INTEGRATIONS: IntegrationDef[] = [
  { id: "integration_stripe", name: "Stripe", color: "#0570DE",
    fields: [{ key: "stripe-api-key", label: "Secret key", placeholder: "sk_live_…", secret: true }] },
  { id: "integration_github", name: "GitHub", color: "#F4505E",
    fields: [{ key: "github-token", label: "Token", placeholder: "ghp_…  (or sign in with gh)", secret: true }] },
  { id: "integration_vercel", name: "Vercel", color: "#7C5CFF",
    fields: [{ key: "vercel-token", label: "Token", placeholder: "…", secret: true }] },
  { id: "integration_n8n", name: "n8n", color: "#F29B38",
    fields: [
      { key: "n8n-url", label: "Instance URL", placeholder: "https://n8n.example.com", secret: false },
      { key: "n8n-api-key", label: "API key", placeholder: "…", secret: true },
    ] },
  { id: "integration_resend", name: "Resend", color: "#22C55E",
    fields: [{ key: "resend-api-key", label: "API key", placeholder: "re_…", secret: true }] },
  { id: "integration_notion", name: "Notion", color: "#8C8C8C",
    fields: [{ key: "notion-api-key", label: "Integration token", placeholder: "ntn_…", secret: true }] },
  { id: "integration_calcom", name: "Cal.com", color: "#C9956A",
    fields: [{ key: "calcom-api-key", label: "API key", placeholder: "cal_…", secret: true }] },
  { id: "integration_linear", name: "Linear", color: "#5E6AD2",
    fields: [{ key: "linear-api-key", label: "API key", placeholder: "lin_api_…", secret: true }] },
  // No key: set up with the browser extension in the WhaTicket section below.
  { id: "integration_whaticket", name: "WhaTicket", color: "#25D366", fields: [] },
  // Connected in the Google section below.
  { id: "integration_gmail", name: "Gmail", color: "#EA4335", fields: [] },
  // GitHub Actions on your open PRs (#115): no key of its own.
  { id: "integration_ci", name: "CI", color: "#2F81F7", fields: [],
    hint: "GitHub Actions on your open PRs. Uses the GitHub connection above (gh or the token)." },
];

function integrationsSection(present: Record<string, boolean>): HTMLElement {
  const note = h("div", { class: "hint" });
  const list = h("div", { style: "display:flex;flex-direction:column;gap:14px" });

  function updateNote() {
    const used = settings.activeIntegrations.length;
    note.textContent = `${used} active — the island shows 4 at a time and rotates the rest. Keys are stored in ${keychainName}, never on disk.`;
  }

  for (const def of INTEGRATIONS) {
    const active = settings.activeIntegrations.includes(def.id);
    const sw = h("button", { class: active ? "switch on" : "switch" });
    sw.addEventListener("click", () => {
      const on = settings.activeIntegrations.includes(def.id);
      if (on) {
        settings.activeIntegrations = settings.activeIntegrations.filter((x) => x !== def.id);
      } else {
        settings.activeIntegrations = [...settings.activeIntegrations, def.id];
      }
      sw.classList.toggle("on", !on);
      updateNote();
      void save();
    });

    const rows = h("div", { style: "display:flex;flex-direction:column;gap:6px;flex:1 1 auto;min-width:0" });
    if (def.hint) rows.append(h("div", { class: "hint", style: "padding-top:4px", text: def.hint }));
    for (const field of def.fields) {
      const input = h("input", {
        type: field.secret ? "password" : "text",
        placeholder: present[field.key] ? "••••••••  (stored)" : field.placeholder,
        autocomplete: "off",
        spellcheck: "false",
        style: "flex:1 1 auto;min-width:0",
      }) as HTMLInputElement;
      const saveBtn = h("button", { text: "Save" });
      const dotEl = statusDot(present[field.key] ?? false);
      saveBtn.addEventListener("click", async () => {
        const value = input.value.trim();
        try {
          await Bridge.secretSet(field.key, value);
          present[field.key] = value.length > 0;
          input.value = "";
          input.placeholder = value ? "••••••••  (stored)" : field.placeholder;
          dotEl.style.background = value ? "#22c55e" : "#f4505e";
        } catch {
          dotEl.style.background = "#f5a524";
        }
      });
      rows.append(
        h("div", { class: "row" },
          h("label", { style: "min-width:104px", text: field.label }),
          input, saveBtn, dotEl,
        ),
      );
    }

    list.append(
      h("div", { style: "display:flex;gap:12px;align-items:flex-start" },
        h("div", { style: "display:flex;align-items:center;gap:8px;min-width:132px;padding-top:4px" },
          sw,
          h("i", { class: "dot", style: `background:${def.color}` }),
          h("span", { style: "font-size:12.5px", text: def.name }),
        ),
        rows,
      ),
    );
  }

  // How often the pills that don't fit in the island rotate in (#111).
  const rotation = h("select", {}) as HTMLSelectElement;
  for (const [secs, label] of [[0, "Off"], [10, "Every 10 s"], [30, "Every 30 s"], [60, "Every minute"]] as const) {
    rotation.append(h("option", { value: String(secs), text: label }));
  }
  rotation.value = String(settings.pillRotationSeconds ?? 30);
  rotation.addEventListener("change", () => {
    settings.pillRotationSeconds = Number(rotation.value);
    void save();
  });
  const rotationRow = h("div", { style: "display:flex;align-items:center;gap:10px;margin:8px 0" },
    h("label", { text: "Rotate the rest" }), rotation);

  updateNote();
  return h("section", {}, h("h2", {}, h("span", { text: "Integrations" })), note, rotationRow, list);
}

// ── Phone alerts (#31 on macOS) ───────────────────────────────────────────────

function phoneSection(): HTMLElement {
  const server = h("input", { type: "text", placeholder: "https://ntfy.sh", value: settings.ntfyServer ?? "",
    style: "flex:1 1 auto;min-width:0", spellcheck: "false" }) as HTMLInputElement;
  const topic = h("input", { type: "text", value: settings.ntfyTopic ?? "", style: "flex:1 1 auto;min-width:0",
    spellcheck: "false", placeholder: "coucou-…" }) as HTMLInputElement;
  const feedback = h("div", {});
  server.addEventListener("change", () => { settings.ntfyServer = server.value.trim(); void save(); });
  topic.addEventListener("change", () => { settings.ntfyTopic = topic.value.trim(); void save(); });
  const fresh = h("button", { text: "New topic", onclick: async () => {
    const t = await Bridge.newNtfyTopic();
    if (!t) return;
    topic.value = t;
    settings.ntfyTopic = t;
    void save();
  } });
  const testBtn = h("button", { text: "Send a test", onclick: async () => {
    clear(feedback);
    try {
      await Bridge.phoneTest(server.value.trim(), topic.value.trim());
      feedback.append(h("div", { class: "notice ok", text: "Sent. Check your phone." }));
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }));
    }
  } });
  return h("section", {},
    h("h2", {}, statusDot(settings.phoneAlerts && !!settings.ntfyTopic), h("span", { text: "Phone alerts" })),
    h("div", { class: "hint", text: "An approval still waiting after 20 seconds goes to your phone through ntfy (free app, no account). Subscribe to the topic in the app; it carries the project and the command, so keep it private." }),
    h("div", { class: "row" }, h("label", { text: "Alerts" }),
      toggle(settings.phoneAlerts, (v) => { settings.phoneAlerts = v; if (v && !topic.value) fresh.click(); void save(); })),
    h("div", { class: "row" }, h("label", { text: "Only when away" }),
      toggle(settings.phoneOnlyWhenAway, (v) => { settings.phoneOnlyWhenAway = v; void save(); }),
      h("span", { class: "hint", text: "no keyboard or mouse for 2 min (Windows)" })),
    h("div", { class: "row" }, h("label", { text: "Topic" }), topic, fresh),
    h("div", { class: "row" }, h("label", { text: "Server" }), server, testBtn),
    feedback,
  );
}

// ── Inbox ─────────────────────────────────────────────────────────────────────

function inboxSection(): HTMLElement {
  const kinds: [string, string][] = [
    ["review", "Review requests"], ["mention", "Mentions"], ["assigned", "Assignments"],
    ["comment", "Comments"], ["other", "Other updates"],
  ];
  const kindRow = h("div", { class: "row", style: "flex-wrap:wrap;gap:6px 14px" });
  for (const [id, label] of kinds) {
    kindRow.append(h("span", { style: "display:inline-flex;gap:6px;align-items:center" },
      toggle(settings.inboxKinds.includes(id), (v) => {
        settings.inboxKinds = v ? [...new Set([...settings.inboxKinds, id])] : settings.inboxKinds.filter((k) => k !== id);
        void save();
      }), h("span", { text: label })));
  }
  return h("section", {},
    h("h2", {}, statusDot(settings.inboxEnabled), h("span", { text: "Inbox" })),
    h("div", { class: "hint", text: "GitHub (your token, or a signed-in gh) and Linear notifications that need you, behind the 🔔. Mochi peeks out when something new arrives." }),
    h("div", { class: "row" }, h("label", { text: "Inbox" }),
      toggle(settings.inboxEnabled, (v) => { settings.inboxEnabled = v; void save(); })),
    h("div", { class: "row" }, h("label", { text: "GitHub" }),
      toggle(settings.inboxGithub, (v) => { settings.inboxGithub = v; void save(); }),
      h("label", { text: "Linear", style: "min-width:0;margin-left:16px" }),
      toggle(settings.inboxLinear, (v) => { settings.inboxLinear = v; void save(); })),
    kindRow,
  );
}

// ── Time per Linear issue (#114) ──────────────────────────────────────────────

const MINUTE_MS = 60_000;

function timeSection(): HTMLElement {
  let store: TimeStore = parseStore("");
  let mode: "day" | "period" = "day";
  const periods = recentPeriods(new Date(), 6);
  let period = periods[0];
  const body = h("div", { style: "display:flex;flex-direction:column;gap:8px" });
  const feedback = h("div", {});

  function say(text: string, kind: "ok" | "err" = "ok") {
    clear(feedback);
    feedback.append(h("div", { class: `notice ${kind}`, text }));
  }

  async function load() {
    const text = await Bridge.timeStoreLoad();
    store = parseStore(text);
    draw();
  }

  /** Re-reads the file first: the island adds events to it while this window is open. */
  async function adjust(day: string, key: string, deltaMs: number, title?: string) {
    if (!key || !deltaMs) return false;
    const text = await Bridge.timeStoreLoad();
    if (text === null) {
      say("Couldn't read the time file.", "err");
      return false;
    }
    store = addAdjustment(parseStore(text), { day, key, deltaMs, ...(title ? { title } : {}) });
    try {
      await Bridge.timeStoreSave(serializeStore(store));
    } catch (err) {
      say(String(err).replace(/^Error:\s*/, ""), "err");
      return false;
    }
    draw();
    return true;
  }

  const rows = (): DayRow[] => rowsFromStore(store, { now: Date.now() });
  const label = (r: DayRow) => r.issue?.identifier ?? r.key;

  const dayBtn = h("button", { class: "small", text: "Day", onclick: () => { mode = "day"; clear(feedback); draw(); } });
  const periodBtn = h("button", { class: "small", text: "Period", onclick: () => { mode = "period"; clear(feedback); draw(); } });
  const refreshBtn = h("button", { class: "small", text: "Refresh", onclick: () => void load() });

  function totalRow(text: string) {
    return h("div", { class: "time-row", style: "font-weight:600" },
      h("span", { class: "time-main", text: "Total" }), h("span", { class: "time-num", "data-raw": true, text }));
  }

  function drawDay() {
    const today = dayKey(Date.now());
    const list = rows().filter((r) => r.day === today);
    if (!list.length) body.append(h("div", { class: "hint", text: "No time recorded today yet." }));
    for (const r of list) {
      body.append(h("div", { class: "time-row" },
        h("div", { class: "time-main", "data-raw": true },
          h("div", { class: "time-key time-ellipsis", text: label(r) }),
          r.issue?.title ? h("div", { class: "hint time-ellipsis", text: r.issue.title }) : null),
        h("span", { class: "time-num", "data-raw": true, text: formatDuration(r.ms) }),
        h("button", { class: "small", text: "−15", title: "Remove 15 minutes",
          onclick: () => void adjust(r.day, r.key, -Math.min(15 * MINUTE_MS, r.ms), r.issue?.title) }),
        h("button", { class: "small", text: "+15", title: "Add 15 minutes",
          onclick: () => void adjust(r.day, r.key, 15 * MINUTE_MS, r.issue?.title) }),
      ));
    }
    if (list.length) {
      const ms = list.reduce((n, r) => n + r.ms, 0);
      body.append(totalRow(formatDuration(ms)));
    }

    const key = h("input", { type: "text", placeholder: "Issue or task (SHO-123)", spellcheck: "false",
      style: "flex:0 1 190px;min-width:0" }) as HTMLInputElement;
    const title = h("input", { type: "text", placeholder: "Description (optional)",
      style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
    const minutes = h("select", { "data-raw": true }) as HTMLSelectElement;
    for (let m = 15; m <= 720; m += 15) minutes.append(h("option", { value: String(m), text: formatDuration(m * MINUTE_MS) }));
    minutes.value = "30";
    const add = h("button", { text: "Add", onclick: async () => {
      let k = key.value.trim();
      if (!k) return;
      if (/^[A-Za-z][A-Za-z0-9]+-\d+$/.test(k)) k = k.toUpperCase();
      if (await adjust(today, k, Number(minutes.value) * MINUTE_MS, title.value.trim() || undefined)) {
        say("Entry added.");
      }
    } });
    body.append(
      h("div", { style: "font-weight:600;margin-top:6px", text: "Add an entry (work outside Claude Code)" }),
      h("div", { class: "row", style: "gap:8px" }, key, title),
      h("div", { class: "row", style: "gap:8px" }, minutes, add),
    );
  }

  function drawPeriod() {
    const select = h("select", { "data-raw": true }) as HTMLSelectElement;
    for (const p of periods) select.append(h("option", { value: p.from, text: `${p.from} – ${p.to}` }));
    select.value = period.from;
    select.addEventListener("change", () => {
      period = periods.find((p) => p.from === select.value) ?? periods[0];
      clear(feedback);
      draw();
    });
    body.append(h("div", { class: "row" }, h("label", { text: "Period" }), select));

    const days = groupPeriod(rows(), period.from, period.to);
    if (!days.length) body.append(h("div", { class: "hint", text: "No time recorded in this period." }));
    for (const d of days) {
      body.append(h("div", { class: "time-day", "data-raw": true },
        h("div", { class: "time-row" },
          h("span", { class: "time-key", text: d.day }),
          h("span", { class: "hint time-main time-ellipsis", style: "font-family:var(--mono)", text: d.rows.map(label).join(", ") }),
          h("span", { class: "time-num", text: `${formatHours(d.ms)} h` })),
        h("div", { class: "hint", text: d.description }),
      ));
    }
    if (days.length) body.append(totalRow(`${formatHours(days.reduce((n, d) => n + d.ms, 0))} h`));

    const copy = async (text: string, done: string) => {
      try {
        await navigator.clipboard.writeText(text);
        say(done);
      } catch (err) {
        say(String(err).replace(/^Error:\s*/, ""), "err");
      }
    };
    body.append(
      h("div", { class: "row", style: "gap:8px" },
        h("button", { text: "Copy as text", disabled: !days.length, onclick: () => void copy(toText(days), "Copied ✓") }),
        h("button", { text: "Copy CSV", disabled: !days.length,
          onclick: () => void copy(toCsv(days), "CSV copied. Paste it into your spreadsheet.") })),
      h("div", { class: "hint", text: "Exports stay on this computer: nothing is sent anywhere." }),
    );
  }

  function draw() {
    dayBtn.className = mode === "day" ? "small primary" : "small";
    periodBtn.className = mode === "period" ? "small primary" : "small";
    clear(body);
    if (mode === "day") drawDay();
    else drawPeriod();
  }

  draw();
  void load();
  // The island keeps adding time while this window is open: fresh numbers when it comes back.
  window.addEventListener("focus", () => void load());

  return h("section", {},
    h("h2", {}, statusDot(settings.timeTracking !== false), h("span", { text: "Time" })),
    h("div", { class: "hint", text: "Active time of your Claude Code sessions per Linear issue (from the session's branch), or per repo @ branch when there's no issue. Gaps over 10 minutes aren't counted. Kept only on this computer." }),
    h("div", { class: "row" }, h("label", { text: "Record time per issue" }),
      toggle(settings.timeTracking !== false, (v) => { settings.timeTracking = v; void save(); })),
    h("div", { class: "row", style: "gap:6px" }, dayBtn, periodBtn, h("span", { class: "spacer" }), refreshBtn),
    body,
    feedback,
  );
}

// ── Linear quick capture (#118) ───────────────────────────────────────────────

function captureSection(hasLinearKey: boolean): HTMLElement {
  const shortcut = h("input", {
    type: "text", value: settings.captureShortcut ?? "", placeholder: "Ctrl+Alt+L",
    spellcheck: "false", autocomplete: "off", style: "flex:0 1 160px;min-width:0",
  }) as HTMLInputElement;
  shortcut.addEventListener("change", () => {
    settings.captureShortcut = shortcut.value.trim();
    void save();
  });

  const team = h("select", { style: "flex:0 1 220px;min-width:0" }) as HTMLSelectElement;
  const feedback = h("div", { class: "hint" });
  function fillTeams(teams: TeamInfo[]) {
    clear(team);
    team.append(h("option", { value: "", text: "None (type #TEAM)" }));
    for (const t of teams) team.append(h("option", { value: t.key, text: `${t.key} · ${t.name}` }));
    // Saved before the teams loaded (or no longer visible): keep it selectable.
    const saved = settings.linearDefaultTeam ?? "";
    if (saved && !teams.some((t) => t.key === saved)) team.append(h("option", { value: saved, text: saved }));
    team.value = saved;
  }
  team.addEventListener("change", () => {
    settings.linearDefaultTeam = team.value;
    void save();
  });
  async function load() {
    feedback.textContent = "Loading your Linear teams…";
    try {
      fillTeams(parseTeams(await Bridge.linearTeams()).teams);
      feedback.textContent = "";
    } catch (err) {
      feedback.textContent = String(err).replace(/^Error:\s*/, "");
    }
  }
  fillTeams([]);
  if (hasLinearKey) void load();
  const loadBtn = h("button", { text: "Load teams", onclick: () => void load() });

  return h("section", {},
    h("h2", {}, statusDot(hasLinearKey && !!settings.captureShortcut), h("span", { text: "Quick capture (Linear)" })),
    h("div", { class: "hint", text: "Quick capture: #TEAM picks the team, p1–p4 the priority, @me assigns it to you, !today / !fri / !2026-12-01 sets a due date. Nothing is created until you press Enter on the preview. The + in the Linear card opens it too." }),
    h("div", { class: "row" }, h("label", { text: "Shortcut" }), shortcut,
      h("span", { class: "hint", text: "e.g. Ctrl+Alt+L · empty = off · only while a Linear key is saved" })),
    h("div", { class: "row" }, h("label", { text: "Default team" }), team, loadBtn),
    feedback,
  );
}

// ── Google (Gmail, Drive) ─────────────────────────────────────────────────────

function googleSection(connected: boolean, hasClient: boolean): HTMLElement {
  const status = h("div", {});
  const buttons = h("div", { class: "row" });

  function setStatus(text: string, kind: "hint" | "ok" | "err") {
    status.className = kind === "hint" ? "hint" : `notice ${kind}`;
    status.textContent = text;
  }

  function draw() {
    clear(buttons);
    if (connected) {
      setStatus(settings.googleEmail ? `Connected as ${settings.googleEmail}.` : "Connected.", "ok");
      buttons.append(h("button", { class: "danger", text: "Disconnect", onclick: async () => {
        await Bridge.googleDisconnect();
        connected = false;
        settings.googleEmail = "";
        void save();
        draw();
      } }));
    } else {
      setStatus(hasClient ? "Not connected yet." : "Add your OAuth client first (steps above).", "hint");
      const connect = h("button", { class: "primary", text: "Connect Google…" }) as HTMLButtonElement;
      connect.addEventListener("click", async () => {
        connect.disabled = true;
        setStatus("Finish signing in in your browser…", "hint");
        try {
          const email = await Bridge.googleConnect();
          connected = true;
          settings.googleEmail = email;
          void save();
        } catch (err) {
          setStatus(String(err).replace(/^Error:\s*/, ""), "err");
          connect.disabled = false;
          return;
        }
        draw();
      });
      buttons.append(connect);
    }
  }

  const clientRow = (key: string, label: string, placeholder: string, secret: boolean) => {
    const input = h("input", { type: secret ? "password" : "text", placeholder, autocomplete: "off", spellcheck: "false", style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
    const saveBtn = h("button", { text: "Save" });
    saveBtn.addEventListener("click", async () => {
      try {
        await Bridge.secretSet(key, input.value.trim());
        input.value = "";
        input.placeholder = "••••••••  (stored)";
        hasClient = true;
        draw();
      } catch (err) {
        setStatus(String(err), "err");
      }
    });
    return h("div", { class: "row" }, h("label", { text: label }), input, saveBtn);
  };

  const query = h("input", { type: "text", value: settings.gmailQuery || "is:unread in:inbox", style: "flex:1;min-width:200px" }) as HTMLInputElement;
  query.addEventListener("change", () => {
    settings.gmailQuery = query.value.trim() || "is:unread in:inbox";
    void save();
  });

  draw();
  return h("section", {},
    h("h2", {}, h("i", { class: "dot", style: "background:#EA4335" }), h("span", { text: "Google" })),
    h("div", { class: "hint", text: "Gmail in the island and your Drive files in the chat (type @ and a file name). Read-only: Coucou never sends mail or changes files." }),
    h("div", { class: "hint", text: "One-time setup, free: in console.cloud.google.com create a project, turn on the Gmail API and the Google Drive API, set up the OAuth consent screen (External, add yourself as a test user, then Publish it so the sign-in doesn't expire every 7 days), and create an OAuth client ID of type \"Desktop app\". Paste its ID and secret here." }),
    clientRow("google-client-id", "Client ID", hasClient ? "••••••••  (stored)" : "….apps.googleusercontent.com", false),
    clientRow("google-client-secret", "Client secret", hasClient ? "••••••••  (stored)" : "GOCSPX-…", true),
    h("div", { class: "row" }, buttons, status),
    h("div", { class: "row" }, h("label", { text: "Gmail shows" }), query),
    h("div", { class: "hint", text: "A Gmail search, e.g. is:unread in:inbox, or is:important is:unread. Turn on the Gmail pill under Integrations." }),
  );
}

// ── WhaTicket (browser extension) ─────────────────────────────────────────────

function whaticketSection(browser: BrowserStatus | null): HTMLElement {
  const status = h("div", { class: "hint" });
  const install = h("button", { text: "Set up browser extension" }) as HTMLButtonElement;
  const reveal = h("button", { text: "Show folder" }) as HTMLButtonElement;
  reveal.addEventListener("click", () => void Bridge.browserReveal());

  function show(b: BrowserStatus | null) {
    const ready = !!b && b.installed && b.browsers.length > 0;
    reveal.style.display = b?.installed ? "" : "none";
    install.textContent = ready ? "Set up again" : "Set up browser extension";
    status.className = ready ? "notice ok" : "hint";
    status.textContent = ready
      ? `Ready for ${b!.browsers.join(", ")}. Extension folder: ${b!.extensionDir}`
      : "Not set up yet.";
  }
  show(browser);

  install.addEventListener("click", async () => {
    install.disabled = true;
    try {
      show(await Bridge.browserInstall());
      void refreshQueues();
    } catch (err) {
      status.className = "notice err";
      status.textContent = String(err).replace(/^Error:\s*/, "");
    } finally {
      install.disabled = false;
    }
  });

  // Queues come from the extension's last check-in (your whaticket.com tab).
  const queues = h("div", { class: "row", style: "gap:8px 14px" });
  async function refreshQueues() {
    const list = (await Bridge.whaticketQueues()) ?? [];
    clear(queues);
    if (!list.length) {
      queues.append(h("span", { class: "hint", text: "Your queues show here once whaticket.com is open with the extension." }));
      return;
    }
    queues.append(h("label", { text: "Only from" }));
    for (const q of list) {
      const box = h("input", { type: "checkbox" }) as HTMLInputElement;
      box.checked = settings.whaticketQueues.includes(q.id);
      box.addEventListener("change", () => {
        settings.whaticketQueues = box.checked
          ? [...settings.whaticketQueues.filter((x) => x !== q.id), q.id]
          : settings.whaticketQueues.filter((x) => x !== q.id);
        void save();
      });
      queues.append(h("span", { style: "display:flex;align-items:center;gap:5px;font-size:12.5px" },
        box, h("i", { class: "dot", style: `background:${q.color || "#8e939c"}` }), h("span", { text: q.name })));
    }
    queues.append(h("span", { class: "hint", text: "none ticked = any of your queues" }));
  }
  void refreshQueues();

  const hours = h("input", {
    type: "text",
    placeholder: "Any time — or e.g. 09:00-18:00",
    value: settings.whaticketHours ?? "",
    style: "width:200px",
  }) as HTMLInputElement;
  hours.addEventListener("change", () => {
    settings.whaticketHours = hours.value.trim();
    void save();
  });

  return h("section", {},
    h("h2", {}, h("i", { class: "dot", style: "background:#25D366" }), h("span", { text: "WhaTicket" })),
    h("div", { class: "hint", text: "Coucou reads your whaticket.com queue through a small Chrome / Edge extension that uses the session you already have open — no token, no password, and it never signs you out." }),
    h("div", { class: "row" }, install, reveal),
    status,
    h("ol", { class: "hint", style: "margin:4px 0 0 18px;padding:0;line-height:1.6" },
      h("li", { text: "Click Set up browser extension." }),
      h("li", { text: "In Chrome open chrome://extensions (in Edge: edge://extensions) and turn on Developer mode." }),
      h("li", { text: "Click Load unpacked and pick the extension folder shown above." }),
      h("li", { text: "Keep a whaticket.com tab open, and turn on the WhaTicket pill under Integrations." }),
    ),
    h("div", { class: "row" },
      h("label", { text: "Auto-accept" }),
      toggle(settings.whaticketAutoAccept === true, (v) => { settings.whaticketAutoAccept = v; void save(); }),
      h("span", { class: "hint", text: "accept new tickets as you as soon as they arrive" }),
    ),
    queues,
    h("div", { class: "row" }, h("label", { text: "Only between" }), hours),
    h("div", { class: "hint", text: "Only while your whaticket.com tab is open. Never during Do not disturb, never group chats, never tickets an AI agent is handling. Coucou only assigns the ticket — it never writes to the customer." }),
    whaticketStatsBlock(),
  );
}

/** Settings → WhaTicket → Stats: tickets that arrived and the ones we accepted, from the
 *  local log (src-tauri/src/whaticket.rs). Bars are plain DOM — no chart library. */
function whaticketStatsBlock(): HTMLElement {
  let events: StatEvent[] = [];
  const period = h("select", {},
    h("option", { value: "today", text: "Today" }),
    h("option", { value: "week", text: "Last 7 days" }),
    h("option", { value: "month", text: "Last 30 days" }),
    h("option", { value: "custom", text: "Custom" }),
  ) as HTMLSelectElement;
  const now = new Date();
  const weekAgo = new Date(now);
  weekAgo.setDate(weekAgo.getDate() - 6);
  const from = h("input", { type: "date", value: wtDayKey(weekAgo) }) as HTMLInputElement;
  const to = h("input", { type: "date", value: wtDayKey(now) }) as HTMLInputElement;
  const custom = h("span", { style: "display:none;align-items:center;gap:8px" },
    h("span", { class: "hint", text: "From" }), from, h("span", { class: "hint", text: "To" }), to);
  const body = h("div", { class: "wt-stats" });
  const feedback = h("div", {});
  const copy = h("button", { text: "Copy CSV" }) as HTMLButtonElement;
  const reset = h("button", { class: "danger", text: "Reset stats" }) as HTMLButtonElement;
  const confirmRow = h("div", { class: "row", style: "display:none" });

  const currentRange = () => range(period.value as Period, Date.now(), from.value, to.value);

  const stat = (label: string, value: string) =>
    h("div", { class: "wt-stat" }, h("b", { text: value }), h("span", { text: label }));

  /** Two bars per slot (arrived, accepted), scaled to the busiest slot. */
  const bars = (slots: { arrived: number; accepted: number }[], labels: string[]) => {
    const top = Math.max(1, ...slots.map((s) => Math.max(s.arrived, s.accepted)));
    const chart = h("div", { class: "wt-bars" });
    const axis = h("div", { class: "wt-axis" });
    slots.forEach((s, i) => {
      const bar = (n: number, cls: string) => h("i", { class: cls, style: `height:${n > 0 ? Math.max(2, (n / top) * 100) : 0}%` });
      chart.append(h("div", { class: "wt-slot", title: `${s.arrived} arrived · ${s.accepted} accepted` },
        bar(s.arrived, "a"), bar(s.accepted, "b")));
      axis.append(h("span", { text: labels[i] ?? "" }));
    });
    return h("div", {}, chart, axis);
  };

  function draw() {
    custom.style.display = period.value === "custom" ? "inline-flex" : "none";
    const r = currentRange();
    const s = summary(events, r.from, r.to);
    clear(body);
    copy.disabled = s.arrived + s.accepted === 0;
    reset.disabled = events.length === 0;
    body.append(
      h("div", { class: "wt-numbers" },
        stat("Arrived", String(s.arrived)),
        stat("Accepted", String(s.accepted)),
        stat("Acceptance rate", s.rate == null ? "—" : `${Math.round(s.rate * 100)} %`),
        stat("Average wait", duration(s.averageWait)),
        stat("Median wait", duration(s.medianWait)),
      ),
      h("div", { class: "hint", text: `From Coucou ${s.click} · Auto-accepted ${s.auto} · Elsewhere ${s.web}` }),
    );
    if (s.backlog > 0) {
      body.append(h("div", { class: "hint", text: `${s.backlog} were already waiting when the tab opened (not in the per-hour chart or the waits).` }));
    }
    if (s.arrived + s.accepted === 0) {
      body.append(h("div", { class: "hint", text: "No tickets in this period." }));
      return;
    }
    body.append(
      h("div", { class: "hint", text: "By hour of day" }),
      bars(s.hours, s.hours.map((_, i) => (i % 6 === 0 ? `${i}h` : ""))),
    );
    if (s.days.length > 1) {
      const n = s.days.length;
      body.append(
        h("div", { class: "hint", text: "By day" }),
        bars(s.days, s.days.map((d, i) => (n <= 10 || i === 0 || i === n - 1 ? d.day.slice(5) : ""))),
      );
    }
    body.append(h("div", { class: "row", style: "gap:14px" },
      h("span", { class: "wt-key a", text: "Arrived" }), h("span", { class: "wt-key b", text: "Accepted" })));
    const table = h("table", { class: "wt-table" },
      h("tr", {}, h("th", { text: "Queue" }), h("th", { text: "Arrived" }), h("th", { text: "Accepted" }), h("th", { text: "Average wait" })));
    for (const q of s.queues) {
      table.append(h("tr", {},
        h("td", { text: q.name || "No queue", "data-raw": q.name ? true : undefined }),
        h("td", { text: String(q.arrived) }), h("td", { text: String(q.accepted) }), h("td", { text: duration(q.averageWait) })));
    }
    body.append(table);
  }

  async function load() {
    events = (await Bridge.whaticketStats()) ?? [];
    draw();
  }

  period.addEventListener("change", () => void load());
  from.addEventListener("change", draw);
  to.addEventListener("change", draw);

  // No dependency for a file dialog: the CSV goes to the clipboard, ready to paste
  // into a spreadsheet.
  copy.addEventListener("click", async () => {
    clear(feedback);
    const r = currentRange();
    const csv = wtToCsv(events, r.from, r.to);
    try {
      await navigator.clipboard.writeText(csv);
      const rows = csv.trim().split("\n").length - 1;
      feedback.append(h("div", { class: "notice ok", text: `CSV copied to the clipboard (${rows} rows).` }));
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }));
    }
  });

  reset.addEventListener("click", () => {
    clear(confirmRow);
    confirmRow.style.display = "flex";
    confirmRow.append(
      h("span", { class: "hint", text: "Delete all WhaTicket stats? This can't be undone." }),
      h("button", { class: "danger", text: "Yes, reset", onclick: async () => {
        await Bridge.whaticketStatsReset();
        confirmRow.style.display = "none";
        clear(feedback);
        await load();
      } }),
      h("button", { text: "Cancel", onclick: () => { confirmRow.style.display = "none"; } }),
    );
  });

  void load();
  return h("div", { class: "wt-stats-block" },
    h("h3", { text: "Stats" }),
    h("div", { class: "row" }, period, custom, h("span", { class: "spacer" }),
      h("button", { class: "small", text: "Refresh", onclick: () => void load() })),
    body,
    h("div", { class: "row" }, copy, reset),
    confirmRow,
    feedback,
    h("div", { class: "hint", text: "Counts only cover the time your whaticket.com tab was open with the extension. Kept on this computer for a year, never uploaded: ticket ids, queues and times only — no names, phone numbers or messages." }),
  );
}

// ── Skills ────────────────────────────────────────────────────────────────────

const SOURCE_LABEL: Record<SkillInfo["source"], string> = {
  personal: "Personal",
  project: "Project",
  plugin: "Plugin",
  codex: "Codex",
};

function skillsSection(targets: { id: string; label: string }[]): HTMLElement {
  const head = h("h2", {}, h("span", { text: "Skills" }));
  const count = h("span", { class: "hint", text: "" });
  head.append(count);
  const search = h("input", { type: "text", placeholder: "Search skills…", style: "flex:1" }) as HTMLInputElement;
  const list = h("div", { class: "skill-list" });
  let all: SkillInfo[] = [];

  function groupLabel(s: SkillInfo): string {
    if (s.source === "project" || s.source === "plugin") return `${SOURCE_LABEL[s.source]} · ${s.origin ?? ""}`;
    return SOURCE_LABEL[s.source];
  }

  function row(s: SkillInfo): HTMLElement {
    const viewer = h("div", { class: "skill-md", style: "display:none" });
    const view = h("button", { class: "small", text: "View" });
    view.addEventListener("click", async () => {
      if (viewer.style.display !== "none") {
        viewer.style.display = "none";
        return;
      }
      clear(viewer);
      try {
        const text = await Bridge.skillRead(s.path);
        viewer.append(
          h("pre", { text: text.content }),
          h("div", { class: "hint", text: `${text.files.length} files: ${text.files.slice(0, 15).join(", ")}${text.files.length > 15 ? "…" : ""}` }),
        );
      } catch (err) {
        viewer.append(h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }));
      }
      viewer.style.display = "";
    });
    const actions = h("div", { class: "skill-actions" },
      view,
      h("button", { class: "small", text: "Open", title: "Open in the editor", onclick: () => void Bridge.openInVSCode(s.path) }),
      h("button", { class: "small", text: "Folder", onclick: () => void Bridge.skillReveal(s.path) }),
    );
    if (s.editable) {
      actions.append(toggle(s.enabled, async (v) => {
        try {
          await Bridge.skillSetEnabled(s.path, v);
        } catch (err) {
          list.prepend(h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }));
        }
        await refresh();
      }));
    }
    const title = h("div", { class: "skill-title" }, h("b", { text: s.name }));
    if (s.hasScripts) title.append(h("span", { class: "tag", text: "scripts" }));
    if (!s.enabled) title.append(h("span", { class: "tag off", text: "off" }));
    return h("div", { class: s.enabled ? "skill" : "skill disabled" },
      h("div", { class: "skill-main" }, title, h("div", { class: "hint skill-desc", text: s.description || "No description." })),
      actions,
      viewer,
    );
  }

  function draw() {
    const q = search.value.trim().toLowerCase();
    const shown = all.filter((s) => !q || `${s.name} ${s.description} ${s.origin ?? ""}`.toLowerCase().includes(q));
    count.textContent = all.length ? `· ${all.length}` : "";
    clear(list);
    if (!all.length) {
      list.append(h("div", { class: "hint", text: "No skills on this computer yet. Add one below." }));
      return;
    }
    let group = "";
    for (const s of shown) {
      const g = groupLabel(s);
      if (g !== group) {
        group = g;
        list.append(h("div", { class: "skill-group", text: g }));
      }
      list.append(row(s));
    }
  }

  async function refresh() {
    all = (await Bridge.skillsList()) ?? [];
    draw();
  }
  search.addEventListener("input", draw);

  // Adding: a folder, a .zip / .skill file or a GitHub link → preview → Install.
  const target = h("select", {}) as HTMLSelectElement;
  for (const t of targets) target.append(h("option", { value: t.id, text: t.label }));
  const source = h("input", {
    type: "text",
    placeholder: "Folder, .zip / .skill file, or a GitHub link",
    style: "flex:1;min-width:220px",
  }) as HTMLInputElement;
  const previewBox = h("div", { class: "skill-preview" });
  const previewBtn = h("button", { class: "primary", text: "Preview" }) as HTMLButtonElement;

  function showPreview(p: SkillPreview) {
    clear(previewBox);
    for (const sk of p.skills) {
      const files = sk.files.slice(0, 12).join(", ") + (sk.files.length > 12 ? ` and ${sk.files.length - 12} more` : "");
      previewBox.append(h("div", { class: "skill" },
        h("div", { class: "skill-main" },
          h("div", { class: "skill-title" }, h("b", { text: sk.name })),
          h("div", { class: "hint skill-desc", text: sk.description || "No description." }),
          h("div", { class: "hint", text: `${sk.files.length} files: ${files}` }),
          h("div", { class: "hint" }, h("span", { text: "Installs to " }), h("span", { class: "path", text: sk.dest })),
          sk.hasScripts
            ? h("div", { class: "notice warn", text: "It has scripts. Coucou never runs them, but Claude may when it uses the skill — read them first." })
            : h("span", {}),
          sk.exists
            ? h("div", { class: "notice warn", text: "A skill with this name is already there; installing replaces it (the old one is kept in Coucou's trash)." })
            : h("span", {}),
        ),
      ));
    }
    const replace = p.skills.some((sk) => sk.exists);
    const install = h("button", { class: "primary", text: p.skills.length > 1 ? `Install ${p.skills.length} skills` : "Install" });
    install.addEventListener("click", async () => {
      try {
        await Bridge.skillsInstall(p.token, replace);
        clear(previewBox);
        source.value = "";
        previewBox.append(h("div", { class: "notice ok", text: "Installed. Claude Code picks it up in its next session." }));
        await refresh();
      } catch (err) {
        previewBox.append(h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }));
      }
    });
    previewBox.append(h("div", { class: "row" },
      install,
      h("button", { text: "Cancel", onclick: () => clear(previewBox) }),
    ));
  }

  async function runPreview() {
    if (!source.value.trim()) return;
    previewBtn.disabled = true;
    clear(previewBox);
    previewBox.append(h("div", { class: "hint", text: "Looking…" }));
    try {
      showPreview(await Bridge.skillsPreview(source.value.trim(), target.value));
    } catch (err) {
      clear(previewBox);
      previewBox.append(h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }));
    } finally {
      previewBtn.disabled = false;
    }
  }
  previewBtn.addEventListener("click", () => void runPreview());
  source.addEventListener("keydown", (e) => {
    if ((e as KeyboardEvent).key === "Enter") void runPreview();
  });
  // Dropping a folder or an archive on the window previews it.
  void onDragDrop((e) => {
    if (e.type === "drop" && e.paths?.length) {
      source.value = e.paths[0];
      void runPreview();
    }
  });

  const newName = h("input", { type: "text", placeholder: "New skill name", style: "flex:1;min-width:160px" }) as HTMLInputElement;
  const createBtn = h("button", { text: "Create" });
  createBtn.addEventListener("click", async () => {
    if (!newName.value.trim()) return;
    try {
      await Bridge.skillCreate(newName.value.trim(), target.value);
      newName.value = "";
      await refresh();
    } catch (err) {
      previewBox.append(h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }));
    }
  });

  void refresh();
  return h("section", {},
    head,
    h("div", { class: "hint", text: "What Claude Code and Codex can use on this computer: your own skills, each project's, and the ones that come with plugins. Turning one off moves it aside; nothing is deleted." }),
    h("div", { class: "row" }, search, h("button", { text: "Refresh", onclick: () => void refresh() })),
    list,
    h("div", { class: "skill-group", text: "Add a skill" }),
    h("div", { class: "row" }, h("label", { text: "Install to" }), target),
    h("div", { class: "row" }, source, previewBtn),
    h("div", { class: "hint", text: "Or drop a skill folder or a .zip / .skill file on this window. You see what's inside before anything is installed." }),
    previewBox,
    h("div", { class: "row" }, newName, createBtn),
  );
}

// ── Voice ─────────────────────────────────────────────────────────────────────

function voiceSection(canListen: boolean): HTMLElement {
  return h("section", {},
    h("h2", {}, h("span", { text: "Voice" })),
    h("div", { class: "row" }, h("label", { text: "Read replies aloud" }),
      toggle(settings.speakReplies, (v) => { settings.speakReplies = v; void save(); })),
    h("div", { class: "hint", text: canListen
      ? "🎙 in the chat: say your question and Mochi sends it (Windows speech recognition; dictation needs online speech recognition on in Windows Settings → Privacy & security → Speech)."
      : "Speaking your questions isn't available on Linux: it has no built-in speech recognition. Mochi can still read its replies aloud." }),
  );
}

// ── Focus timer (#119) ────────────────────────────────────────────────────────

function focusSection(): HTMLElement {
  /** A whole-minutes field; Rust stores these as integers, so never send a fraction. */
  const minutes = (key: "focusMin" | "breakMin" | "longBreakMin" | "blocksBeforeLong", min: number, max: number) => {
    const input = h("input", {
      type: "number", min: String(min), max: String(max), step: "1",
      value: String(settings[key]),
      style: "width:72px",
    }) as HTMLInputElement;
    input.addEventListener("change", () => {
      const v = Math.round(Number(input.value));
      settings[key] = Number.isFinite(v) ? Math.max(min, Math.min(max, v)) : DEFAULT_SETTINGS[key];
      input.value = String(settings[key]);
      void save();
    });
    return input;
  };
  return h("section", {},
    h("h2", {}, h("span", { text: "Focus" })),
    h("div", { class: "row" }, h("label", { text: "Focus block" }), minutes("focusMin", 5, 180), h("span", { class: "hint", text: "minutes" })),
    h("div", { class: "row" }, h("label", { text: "Break" }), minutes("breakMin", 1, 60), h("span", { class: "hint", text: "minutes" })),
    h("div", { class: "row" }, h("label", { text: "Long break" }), minutes("longBreakMin", 1, 90), h("span", { class: "hint", text: "minutes" })),
    h("div", { class: "row" }, h("label", { text: "Long break after" }), minutes("blocksBeforeLong", 1, 12), h("span", { class: "hint", text: "blocks" })),
    h("div", { class: "row" }, h("label", { text: "Ctrl+Alt+F shortcut" }),
      toggle(settings.focusShortcut !== false, (v) => { settings.focusShortcut = v; void save(); }),
      h("span", { class: "hint", text: "start, pause or resume a block from any app" })),
    h("div", { class: "hint", text: "Do not disturb is on during each block and goes back to how it was at the end; approvals still reach the island, quietly. Start a block from the ⏱ in the island, the Claude Code card, the shortcut, or the chat: “focus 50 min on SHO-475”." }),
  );
}

// ── Updates ───────────────────────────────────────────────────────────────────

function updatesSection(): HTMLElement {
  const status = h("span", { class: "hint", text: `You have ${version || "this version"}.` });
  const link = h("button", { class: "primary", text: "Download", style: "display:none" });
  let url = "";
  let canInstall = false;
  link.addEventListener("click", async () => {
    if (!canInstall) {
      if (url) void Bridge.openUrl(url);
      return;
    }
    link.textContent = "Updating…";
    (link as HTMLButtonElement).disabled = true;
    try {
      await Bridge.updateInstall();
    } catch (err) {
      status.textContent = String(err).replace(/^Error:\s*/, "");
      link.textContent = "Install and restart";
      (link as HTMLButtonElement).disabled = false;
    }
  });
  const check = h("button", { text: "Check now", onclick: async () => {
    status.textContent = "Checking…";
    try {
      const info = await Bridge.checkUpdate();
      url = info.url;
      canInstall = info.newer ? (await Bridge.updateCanInstall()) ?? false : false;
      status.textContent = info.newer ? `Coucou ${info.latest} is out (you have ${info.current}).` : `You're up to date (${info.current}).`;
      link.textContent = canInstall ? "Install and restart" : "Download";
      link.style.display = info.newer ? "" : "none";
    } catch (err) {
      status.textContent = String(err).replace(/^Error:\s*/, "");
    }
  } });
  return h("section", {},
    h("h2", {}, h("span", { text: "Updates" })),
    h("div", { class: "row" }, h("label", { text: "Check daily" }),
      toggle(settings.checkUpdates, (v) => { settings.checkUpdates = v; void save(); })),
    h("div", { class: "row" }, status, check, link),
  );
}

// ── General section ───────────────────────────────────────────────────────────

// ── Appearance (themes) ───────────────────────────────────────────────────────

const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
function paintTheme() {
  applyTheme(document.documentElement, settings.theme, darkQuery.matches);
}
darkQuery.addEventListener("change", paintTheme);

function appearanceSection(): HTMLElement {
  const grid = h("div", { class: "theme-grid" });
  const choices: [string, string, string[]][] = [
    ["system", "System", ["#141518", "#FFFFFF"]],
    ...THEMES.map((t): [string, string, string[]] => [t.id, t.id === "dark" ? "Dark" : t.id === "light" ? "Light" : t.name, [t.card, t.ink, t.accent]]),
  ];
  function draw() {
    clear(grid);
    for (const [id, name, colors] of choices) {
      const swatch = h("span", { class: "theme-swatch" });
      for (const c of colors) swatch.append(h("i", { style: `background:${c}` }));
      grid.append(h("button", {
        class: "theme-choice" + ((settings.theme ?? "dark") === id ? " on" : ""),
        onclick: () => { settings.theme = id; void save(); paintTheme(); draw(); },
      }, swatch, h("span", { text: name })));
    }
  }
  draw();
  return h("section", {},
    h("h2", {}, h("span", { text: "Appearance" })),
    grid,
    h("div", { class: "hint", text: "Colours of the island and of this window. Pills keep their own colours." }),
  );
}

function generalSection(editors: { id: string; name: string }[]): HTMLElement {
  // Where "Open terminal" / project folders open (#75).
  const editor = h("select", {}) as HTMLSelectElement;
  editor.append(h("option", { value: "", text: editors.length ? "First one installed" : "File manager (no editor found)" }));
  for (const e of editors) editor.append(h("option", { value: e.id, text: e.name }));
  editor.value = editors.some((e) => e.id === settings.editor) ? settings.editor : "";
  editor.addEventListener("change", () => {
    settings.editor = editor.value;
    void save();
  });

  const volume = h("input", {
    type: "range", min: "0", max: "0.2", step: "0.005",
    value: String(settings.soundVolume),
  }) as HTMLInputElement;
  volume.addEventListener("input", () => {
    settings.soundVolume = Number(volume.value);
    void save();
  });

  const autoClose = h("input", {
    type: "number", min: "5", max: "120", step: "1",
    value: String(Math.round(settings.autoCloseInterval)),
    style: "width:72px",
  }) as HTMLInputElement;
  autoClose.addEventListener("change", () => {
    settings.autoCloseInterval = Math.max(5, Math.min(120, Number(autoClose.value) || 15));
    autoClose.value = String(settings.autoCloseInterval);
    void save();
  });

  const language = h("select", {}) as HTMLSelectElement;
  language.append(
    h("option", { value: "system", text: "Same as the system" }),
    h("option", { value: "en", text: "English" }),
    h("option", { value: "es", text: "Español" }),
  );
  language.value = settings.language ?? "system";
  language.addEventListener("change", async () => {
    settings.language = language.value as Settings["language"];
    await save();
    window.location.reload();
  });

  const screen = h("select", {}) as HTMLSelectElement;
  screen.append(
    h("option", { value: "primary", text: "Main display" }),
    h("option", { value: "cursor", text: "Display under the cursor" }),
  );
  screen.value = settings.screen;
  screen.addEventListener("change", () => {
    settings.screen = screen.value as Settings["screen"];
    void save();
  });

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "General" })),
    h("div", { class: "row" },
      h("label", { text: "Sound" }),
      toggle(settings.soundEnabled, (v) => { settings.soundEnabled = v; void save(); }),
      volume,
    ),
    h("div", { class: "row" },
      h("label", { text: "Auto-close" }),
      autoClose,
      h("span", { class: "hint", text: "seconds after you leave the island" }),
    ),
    h("div", { class: "row" },
      h("label", { text: "Language" }),
      language,
    ),
    h("div", { class: "row" },
      h("label", { text: "Island lives on" }),
      screen,
    ),
    h("div", { class: "row" },
      h("label", { text: "Idle notch" }),
      toggle(settings.idleNotch !== false, (v) => { settings.idleNotch = v; void save(); }),
      h("span", { class: "hint", text: "a small notch stays at the top when the island hides" }),
    ),
    h("div", { class: "row" },
      h("label", { text: "Mochi moves with the music" }),
      toggle(settings.mochiDance === true, (v) => { settings.mochiDance = v; void save(); }),
      h("span", { class: "hint", text: "bobs along while music plays; off in Do not disturb and with reduced motion. Music detection isn't available on this system yet" }),
    ),
    h("div", { class: "row" },
      h("label", { text: "Open projects in" }),
      editor,
    ),
    h("div", { class: "row" },
      h("label", { text: "Launch at startup" }),
      toggle(settings.autostart, (v) => { settings.autostart = v; void save(); }),
    ),
  );
}

// ── Boot ──────────────────────────────────────────────────────────────────────

async function main() {
  const boot = await Bridge.boot();
  if (boot) {
    settings = { ...settings, ...boot.settings };
    version = boot.version;
    if (boot.platform === "linux") keychainName = "your keyring (Secret Service)";
  }
  setLanguage(settings.language);
  paintTheme();
  const status = (await Bridge.hooksStatus()) ?? {
    installed: false, settingsPath: "", hookPath: "", hookReady: false,
  };

  const hasKey = (await Bridge.secretPresent("anthropic-api-key")) ?? false;
  const claudeCode = (await Bridge.claudeCodeStatus()) ?? { installed: false, path: null };
  const editors = (await Bridge.editorsInstalled()) ?? [];
  const codex = (await Bridge.codexStatus()) ?? { found: false, installed: false, hooksPath: "" };
  const presets = (await Bridge.providerPresets()) ?? [];
  const canListen = (await Bridge.voiceAvailable()) ?? false;
  const googleConnected = (await Bridge.googleConnected()) ?? false;
  const browser = await Bridge.browserStatus();
  const googleClient = (await Bridge.secretPresent("google-client-id")) ?? false;
  const skillTargets = (await Bridge.skillsTargets()) ?? [{ id: "personal", label: "Claude Code — personal (~/.claude/skills)" }];

  const keys = [
    "stripe-api-key", "github-token", "vercel-token",
    "n8n-url", "n8n-api-key", "resend-api-key", "notion-api-key", "calcom-api-key", "linear-api-key",
  ];
  const present: Record<string, boolean> = {};
  for (const k of keys) present[k] = (await Bridge.secretPresent(k)) ?? false;
  for (const p of ["openai", "gemini", "openrouter", "ollama", "lmstudio", "custom"]) {
    present[`provider-key-${p}`] = (await Bridge.secretPresent(`provider-key-${p}`)) ?? false;
  }

  clear(root);
  // Tabs: everything used to be one long page.
  type Tab = "general" | "chat" | "claude" | "integrations" | "alerts";
  const pages: [Tab, string, HTMLElement[]][] = [
    ["general", "General", [appearanceSection(), generalSection(editors), voiceSection(canListen), updatesSection()]],
    ["chat", "Chat", [apiSection(hasKey, claudeCode, presets, present), skillsSection(skillTargets)]],
    ["claude", "Claude Code", [claudeSection(status), codexSection(codex), timeSection(), focusSection()]],
    ["integrations", "Integrations", [
      integrationsSection(present), captureSection(present["linear-api-key"] ?? false),
      whaticketSection(browser), googleSection(googleConnected, googleClient),
    ]],
    ["alerts", "Alerts", [inboxSection(), phoneSection()]],
  ];
  let current = (localStorage.getItem("settingsTab") as Tab | null) ?? "general";
  if (!pages.some(([id]) => id === current)) current = "general";
  const tabBar = h("div", { class: "settings-tabs", role: "tablist" });
  const buttons = new Map<Tab, HTMLElement>();
  function show(tab: Tab) {
    current = tab;
    try { localStorage.setItem("settingsTab", tab); } catch { /* private mode: fine */ }
    for (const [id, , sections] of pages) {
      for (const el of sections) el.style.display = id === tab ? "" : "none";
      buttons.get(id)?.classList.toggle("on", id === tab);
    }
    window.scrollTo(0, 0);
  }
  for (const [id, label] of pages) {
    const b = h("button", { class: "settings-tab", role: "tab", text: label, onclick: () => show(id) });
    buttons.set(id, b);
    tabBar.append(b);
  }
  root.append(
    h("h1", {}, h("span", { text: "Coucou" }), h("span", { class: "version", text: version })),
    tabBar,
    ...pages.flatMap(([, , sections]) => sections),
    h("div", {
      class: "hint",
      text: "No telemetry. Network requests only go to the services you configure yourself.",
    }),
  );
  show(current);

  startTranslating(document.body);

  void onEvent<Settings>("settings-changed", (s) => {
    settings = { ...settings, ...s };
  });
}

void main();
