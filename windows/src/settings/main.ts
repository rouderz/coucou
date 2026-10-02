// Settings window — the place where anything that writes to disk is confirmed.
// Stage 2 covers the Claude Code hooks and the general preferences; API keys and
// integrations land here too in a later stage.

import "./settings.css";
import { setLanguage, startTranslating } from "../core/i18n.ts";
import { Bridge, onEvent, type HookStatus } from "../core/bridge";
import { DEFAULT_SETTINGS, type Settings } from "../core/state";
import { h, clear } from "../views/dom";

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
  );
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
    keyRow.style.display = code || other ? "none" : "";
    state.style.display = code || other ? "none" : "";
    codeNote.style.display = code ? "" : "none";
    providerBox.style.display = other ? "" : "none";
    modelRow.style.display = other ? "none" : "";
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
];

const MAX_ACTIVE = 4;

function integrationsSection(present: Record<string, boolean>): HTMLElement {
  const note = h("div", { class: "hint" });
  const list = h("div", { style: "display:flex;flex-direction:column;gap:14px" });

  function updateNote() {
    const used = settings.activeIntegrations.length;
    note.textContent = `Pick up to ${MAX_ACTIVE} pills to show next to Mochi — ${used}/${MAX_ACTIVE} in use. Keys are stored in ${keychainName}, never on disk.`;
  }

  for (const def of INTEGRATIONS) {
    const active = settings.activeIntegrations.includes(def.id);
    const sw = h("button", { class: active ? "switch on" : "switch" });
    sw.addEventListener("click", () => {
      const on = settings.activeIntegrations.includes(def.id);
      if (on) {
        settings.activeIntegrations = settings.activeIntegrations.filter((x) => x !== def.id);
      } else {
        if (settings.activeIntegrations.length >= MAX_ACTIVE) return;
        settings.activeIntegrations = [...settings.activeIntegrations, def.id];
      }
      sw.classList.toggle("on", !on);
      updateNote();
      void save();
    });

    const rows = h("div", { style: "display:flex;flex-direction:column;gap:6px;flex:1 1 auto;min-width:0" });
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

  updateNote();
  return h("section", {}, h("h2", {}, h("span", { text: "Integrations" })), note, list);
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

// ── Updates ───────────────────────────────────────────────────────────────────

function updatesSection(): HTMLElement {
  const status = h("span", { class: "hint", text: `You have ${version || "this version"}.` });
  const link = h("button", { class: "primary", text: "Download", style: "display:none" });
  let url = "";
  link.addEventListener("click", () => { if (url) void Bridge.openUrl(url); });
  const check = h("button", { text: "Check now", onclick: async () => {
    status.textContent = "Checking…";
    try {
      const info = await Bridge.checkUpdate();
      url = info.url;
      status.textContent = info.newer ? `Coucou ${info.latest} is out (you have ${info.current}).` : `You're up to date (${info.current}).`;
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
  const status = (await Bridge.hooksStatus()) ?? {
    installed: false, settingsPath: "", hookPath: "", hookReady: false,
  };

  const hasKey = (await Bridge.secretPresent("anthropic-api-key")) ?? false;
  const claudeCode = (await Bridge.claudeCodeStatus()) ?? { installed: false, path: null };
  const editors = (await Bridge.editorsInstalled()) ?? [];
  const codex = (await Bridge.codexStatus()) ?? { found: false, installed: false, hooksPath: "" };
  const presets = (await Bridge.providerPresets()) ?? [];
  const canListen = (await Bridge.voiceAvailable()) ?? false;

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
  root.append(
    h("h1", {}, h("span", { text: "Coucou" }), h("span", { class: "version", text: version })),
    claudeSection(status),
    codexSection(codex),
    apiSection(hasKey, claudeCode, presets, present),
    integrationsSection(present),
    phoneSection(),
    inboxSection(),
    voiceSection(canListen),
    updatesSection(),
    generalSection(editors),
    h("div", {
      class: "hint",
      text: "No telemetry. Network requests only go to the services you configure yourself.",
    }),
  );

  startTranslating(document.body);

  void onEvent<Settings>("settings-changed", (s) => {
    settings = { ...settings, ...s };
  });
}

void main();
