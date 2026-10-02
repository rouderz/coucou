// Codex CLI (#44 on macOS): Codex runs Claude Code–style hooks (same events, same
// JSON on stdin, same decisions on stdout), so the same relay serves both. It is
// installed in ~/.codex/hooks.json with `--agent codex`, which tags Codex's
// events so the island can tell the two apart. Codex asks the user to trust new
// hooks once, with /hooks.

use std::path::PathBuf;

use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::{platform, settings};

/// Codex events Coucou listens to, with their timeouts (seconds).
const EVENTS: &[(&str, u64)] = &[
    ("SessionStart", 10),
    ("SessionEnd", 10),
    ("UserPromptSubmit", 10),
    ("PreToolUse", 10),
    ("PostToolUse", 10),
    ("PermissionRequest", 120),
    ("Stop", 10),
    ("SubagentStart", 10),
    ("SubagentStop", 10),
];

const MARKER: &str = "coucou-hook";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexStatus {
    /// ~/.codex exists: Codex has been run on this machine.
    pub found: bool,
    pub installed: bool,
    pub hooks_path: String,
}

fn codex_dir() -> PathBuf {
    platform::home().join(".codex")
}

fn hooks_path() -> PathBuf {
    codex_dir().join("hooks.json")
}

fn command() -> String {
    let exe = settings::hook_exe_path().to_string_lossy().replace('\\', "/");
    format!("\"{exe}\" --agent codex")
}

fn is_ours(group: &Value) -> bool {
    group
        .get("hooks")
        .and_then(Value::as_array)
        .map(|hooks| {
            hooks.iter().any(|h| {
                h.get("command").and_then(Value::as_str).map(|c| c.contains(MARKER)).unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

/// hooks.json with Coucou's hooks added; the user's own hooks are kept.
pub fn installed(root: &Value, command: &str) -> Value {
    let mut root = root.as_object().cloned().unwrap_or_default();
    let mut hooks = root.get("hooks").and_then(Value::as_object).cloned().unwrap_or_else(Map::new);
    for (event, timeout) in EVENTS {
        let mut groups: Vec<Value> = hooks
            .get(*event)
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|g| !is_ours(g))
            .collect();
        groups.push(json!({
            "hooks": [{ "type": "command", "command": command, "timeout": timeout, "statusMessage": "Coucou" }]
        }));
        hooks.insert((*event).to_string(), Value::Array(groups));
    }
    root.insert("hooks".into(), Value::Object(hooks));
    Value::Object(root)
}

/// hooks.json without Coucou's hooks.
pub fn uninstalled(root: &Value) -> Value {
    let mut root = root.as_object().cloned().unwrap_or_default();
    let Some(hooks) = root.get("hooks").and_then(Value::as_object).cloned() else {
        return Value::Object(root);
    };
    let mut out = Map::new();
    for (event, value) in hooks {
        match value.as_array() {
            Some(list) => {
                let kept: Vec<Value> = list.iter().filter(|g| !is_ours(g)).cloned().collect();
                if !kept.is_empty() {
                    out.insert(event, Value::Array(kept));
                }
            }
            None => {
                out.insert(event, value);
            }
        }
    }
    if out.is_empty() {
        root.remove("hooks");
    } else {
        root.insert("hooks".into(), Value::Object(out));
    }
    Value::Object(root)
}

fn read() -> Result<Value, String> {
    match std::fs::read(hooks_path()) {
        Ok(bytes) => {
            let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(&bytes);
            serde_json::from_slice(bytes).map_err(|e| {
                format!("{} isn't valid JSON ({e}) — Coucou won't overwrite it.", hooks_path().display())
            })
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(json!({})),
        Err(e) => Err(e.to_string()),
    }
}

fn write(value: &Value, backup: bool) -> Result<(), String> {
    let dir = codex_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path = hooks_path();
    if backup && path.exists() {
        let bak = dir.join(format!("hooks.json.bak-{}", platform::compact_timestamp()));
        std::fs::copy(&path, bak).map_err(|e| format!("backup failed: {e}"))?;
    }
    let text = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
    std::fs::write(&path, text + "\n").map_err(|e| e.to_string())
}

pub fn status() -> CodexStatus {
    let installed = read()
        .ok()
        .and_then(|v| v.get("hooks").and_then(Value::as_object).cloned())
        .map(|hooks| hooks.values().filter_map(Value::as_array).flatten().any(is_ours))
        .unwrap_or(false);
    CodexStatus {
        found: codex_dir().is_dir(),
        installed,
        hooks_path: hooks_path().to_string_lossy().to_string(),
    }
}

/// Only ever called from an explicit click in Settings.
pub fn install() -> Result<(), String> {
    let current = read()?;
    write(&installed(&current, &command()), true)
}

pub fn uninstall() -> Result<(), String> {
    let current = read()?;
    write(&uninstalled(&current), true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_keeps_the_users_hooks_and_does_not_duplicate() {
        let mine = json!({ "hooks": { "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "my-policy" }] }] } });
        let cmd = "\"/x/coucou-hook\" --agent codex";
        let once = installed(&mine, cmd);
        let twice = installed(&once, cmd);
        assert_eq!(twice["hooks"]["PreToolUse"].as_array().unwrap().len(), 2);
        assert_eq!(twice["hooks"]["PermissionRequest"][0]["hooks"][0]["timeout"], 120);
        let removed = uninstalled(&twice);
        let hooks = removed["hooks"].as_object().unwrap();
        assert_eq!(hooks.keys().collect::<Vec<_>>(), vec!["PreToolUse"]);
        assert_eq!(hooks["PreToolUse"].as_array().unwrap().len(), 1);
    }
}
