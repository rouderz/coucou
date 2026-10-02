// Other chat providers (#42, #43 on macOS): any OpenAI-compatible endpoint —
// OpenAI, Google Gemini, OpenRouter, Ollama or LM Studio on this computer, or a
// custom server. The key (when one is needed) lives in the keychain.

use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use serde_json::{json, Value};

use crate::claude::{ChatContext, ChatReply, SYSTEM_PROMPT};
use crate::secrets;

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Preset {
    pub id: &'static str,
    pub name: &'static str,
    pub base_url: &'static str,
    pub needs_key: bool,
    pub default_model: &'static str,
    pub key_hint: &'static str,
}

pub const PRESETS: &[Preset] = &[
    Preset { id: "openai", name: "OpenAI", base_url: "https://api.openai.com/v1", needs_key: true, default_model: "gpt-5", key_hint: "sk-…" },
    Preset { id: "gemini", name: "Google Gemini", base_url: "https://generativelanguage.googleapis.com/v1beta/openai", needs_key: true, default_model: "gemini-2.5-flash", key_hint: "AIza…" },
    Preset { id: "openrouter", name: "OpenRouter", base_url: "https://openrouter.ai/api/v1", needs_key: true, default_model: "openrouter/auto", key_hint: "sk-or-…" },
    Preset { id: "ollama", name: "Ollama (on this computer)", base_url: "http://localhost:11434/v1", needs_key: false, default_model: "llama3.2", key_hint: "" },
    Preset { id: "lmstudio", name: "LM Studio (on this computer)", base_url: "http://localhost:1234/v1", needs_key: false, default_model: "", key_hint: "" },
    Preset { id: "custom", name: "Custom (OpenAI-compatible)", base_url: "", needs_key: false, default_model: "", key_hint: "optional" },
];

pub fn preset(id: &str) -> &'static Preset {
    PRESETS.iter().find(|p| p.id == id).unwrap_or(&PRESETS[0])
}

/// The provider settings in effect: the preset, overridden by what the user typed.
pub struct Config {
    pub preset: &'static Preset,
    pub base_url: String,
    pub model: String,
    pub key: Option<String>,
}

pub fn config(id: &str, base_url: &str, model: &str) -> Config {
    let p = preset(id);
    let base = if base_url.trim().is_empty() { p.base_url } else { base_url.trim() };
    let model = if model.trim().is_empty() { p.default_model } else { model.trim() };
    Config {
        preset: p,
        base_url: base.trim_end_matches('/').to_string(),
        model: model.to_string(),
        key: secrets::get(&format!("provider-key-{}", p.id)),
    }
}

#[derive(Default)]
pub struct ProviderChat {
    messages: Mutex<Vec<Value>>,
}

const MAX_HISTORY: usize = 30;

impl ProviderChat {
    pub fn reset(&self) {
        self.messages.lock().unwrap().clear();
    }

    /// A saved conversation, from its text.
    pub fn restore(&self, turns: &[(bool, String)]) {
        let mut m: Vec<Value> = turns
            .iter()
            .map(|(user, text)| json!({ "role": if *user { "user" } else { "assistant" }, "content": text }))
            .collect();
        while m.last().and_then(|v| v.get("role")).and_then(Value::as_str) == Some("user") {
            m.pop();
        }
        *self.messages.lock().unwrap() = m;
    }
}

/// The window or file (or code) the question is about, as text: these servers
/// take text only.
fn context_text(context: &ChatContext) -> String {
    match context {
        ChatContext::Window { app_name, title, url } => {
            let mut t = format!("Context — App: {app_name}, Window: {title}");
            if let Some(u) = url {
                t.push_str(&format!(", URL: {u}"));
            }
            t + "\n\n"
        }
        ChatContext::File { name, path } => match std::fs::read_to_string(path) {
            Ok(text) if text.len() <= 200_000 => format!("File {name}:\n{text}\n\n"),
            _ => format!("File: {name} (not text, or too large to include)\n\n"),
        },
        ChatContext::Code { .. } => crate::claude::code_preamble(context, true),
    }
}

fn error_for(code: u16, body: &str, model: &str, name: &str) -> String {
    let detail = serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| {
            v.pointer("/error/message")
                .or_else(|| v.get("message"))
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .unwrap_or_default();
    match code {
        401 | 403 => format!("{name} rejected the API key. Check it in Settings → Chat."),
        404 => format!("{name} doesn't know the model “{model}”. Pick another one in Settings → Chat."),
        429 => format!("{name} is rate limiting this key. Wait a moment and try again."),
        _ if !detail.is_empty() => detail,
        _ => format!("{name} answered with an error ({code})."),
    }
}

pub async fn send(
    chat: &ProviderChat,
    cfg: Config,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    if cfg.preset.needs_key && cfg.key.is_none() {
        return Err(format!("Add your {} API key in Settings → Chat.", cfg.preset.name));
    }
    if cfg.base_url.is_empty() {
        return Err("Set the server address in Settings → Chat.".into());
    }
    if cfg.model.is_empty() {
        return Err("Pick a model in Settings → Chat.".into());
    }
    let history = chat.messages.lock().unwrap().clone();
    let mut content = String::new();
    if history.is_empty() {
        if let Some(ctx) = &context {
            content.push_str(&context_text(ctx));
        }
    }
    content.push_str(&query);

    let mut messages = vec![json!({ "role": "system", "content": SYSTEM_PROMPT })];
    let start = history.len().saturating_sub(MAX_HISTORY);
    messages.extend(history[start..].iter().cloned());
    messages.push(json!({ "role": "user", "content": content.clone() }));

    let mut req = reqwest::Client::builder()
        .timeout(Duration::from_secs(180))
        .build()
        .map_err(|e| e.to_string())?
        .post(format!("{}/chat/completions", cfg.base_url))
        .json(&json!({ "model": cfg.model, "messages": messages }));
    if let Some(key) = &cfg.key {
        req = req.header("Authorization", format!("Bearer {key}"));
    }
    let response = req.send().await.map_err(|_| format!("Can't reach {}. Is it running?", cfg.preset.name))?;
    let code = response.status().as_u16();
    let body = response.text().await.unwrap_or_default();
    if code != 200 {
        return Err(error_for(code, &body, &cfg.model, cfg.preset.name));
    }
    let text = serde_json::from_str::<Value>(&body)
        .ok()
        .and_then(|v| v.pointer("/choices/0/message/content").and_then(Value::as_str).map(str::to_string))
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
        .ok_or("The model didn't write an answer. Try asking again.")?;
    let mut m = chat.messages.lock().unwrap();
    m.push(json!({ "role": "user", "content": content }));
    m.push(json!({ "role": "assistant", "content": text }));
    Ok(ChatReply { text })
}

/// Models the server offers (GET /models), for the picker.
pub async fn list_models(cfg: Config) -> Result<Vec<String>, String> {
    let mut req = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?
        .get(format!("{}/models", cfg.base_url));
    if let Some(key) = &cfg.key {
        req = req.header("Authorization", format!("Bearer {key}"));
    }
    let response = req.send().await.map_err(|_| format!("Can't reach {}", cfg.preset.name))?;
    let code = response.status().as_u16();
    let body = response.text().await.unwrap_or_default();
    if code != 200 {
        return Err(error_for(code, &body, &cfg.model, cfg.preset.name));
    }
    let mut ids: Vec<String> = serde_json::from_str::<Value>(&body)
        .ok()
        .and_then(|v| v.get("data").and_then(Value::as_array).cloned())
        .unwrap_or_default()
        .iter()
        .filter_map(|m| m.get("id").and_then(Value::as_str))
        .map(|id| id.strip_prefix("models/").unwrap_or(id).to_string())
        .collect();
    ids.sort();
    Ok(ids)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errors_read_like_the_mac() {
        assert!(error_for(401, "", "m", "OpenAI").contains("API key"));
        assert!(error_for(404, "", "gpt-x", "OpenAI").contains("gpt-x"));
        assert_eq!(error_for(400, r#"{"error":{"message":"context too long"}}"#, "m", "X"), "context too long");
    }

    #[test]
    fn unknown_presets_fall_back_to_openai() {
        assert_eq!(preset("nope").id, "openai");
        assert_eq!(preset("ollama").needs_key, false);
    }
}
