// Preferences, stored as plain JSON in settings.json (see config_dir).
// No secret ever lands here — API keys live in the system keychain (secrets.rs).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub sound_enabled: bool,
    pub sound_volume: f64,
    pub auto_close_interval: f64,
    pub absence_interval: f64,
    pub active_integrations: Vec<String>,
    /// "primary" = the main display, "cursor" = whichever display the mouse is on.
    pub screen: String,
    pub autostart: bool,
    pub hooks_installed: bool,
    /// Claude model used by the chat. Changeable in the settings window.
    /// Defaulted explicitly so a settings.json written by an older build still loads.
    #[serde(default = "default_model")]
    pub model: String,
    /// "api" (Anthropic API key) or "claude-code" (the user's Claude Code subscription).
    #[serde(default = "default_engine")]
    pub chat_engine: String,
    /// Preferred editor command ("code", "cursor", "windsurf", "zed"); empty = first installed.
    #[serde(default)]
    pub editor: String,
    /// Auto-approve per project folder (normalised path → "low" | "medium").
    #[serde(default)]
    pub auto_approve: HashMap<String, String>,

    /// Do not disturb until this time (ms since the epoch); None = off (#30 on macOS).
    #[serde(default)]
    pub dnd_until: Option<f64>,

    /// Phone alerts through ntfy for approvals left waiting (#31 on macOS).
    #[serde(default)]
    pub phone_alerts: bool,
    #[serde(default)]
    pub ntfy_server: String,
    #[serde(default)]
    pub ntfy_topic: String,
    #[serde(default = "yes")]
    pub phone_only_when_away: bool,

    /// GitHub / Linear notifications in Mochi's inbox.
    #[serde(default = "yes")]
    pub inbox_enabled: bool,
    #[serde(default = "yes")]
    pub inbox_github: bool,
    #[serde(default = "yes")]
    pub inbox_linear: bool,
    #[serde(default = "all_kinds")]
    pub inbox_kinds: Vec<String>,

    /// Look for a newer release on GitHub at launch and once a day.
    #[serde(default = "yes")]
    pub check_updates: bool,

    /// "Other provider" chat engine: preset id, server (blank = the preset's) and model.
    #[serde(default = "default_provider")]
    pub provider_id: String,
    #[serde(default)]
    pub provider_base_url: String,
    #[serde(default)]
    pub provider_model: String,

    /// Interface language: "system", "en" or "es".
    #[serde(default = "default_language")]
    pub language: String,

    /// Mochi reads its chat replies aloud.
    #[serde(default)]
    pub speak_replies: bool,
}

fn default_provider() -> String {
    "openai".into()
}

fn default_language() -> String {
    "system".into()
}

fn yes() -> bool {
    true
}

pub fn all_kinds() -> Vec<String> {
    ["review", "mention", "assigned", "comment", "other"].iter().map(|s| s.to_string()).collect()
}

fn default_engine() -> String {
    "api".into()
}

fn default_model() -> String {
    crate::claude::DEFAULT_MODEL.to_string()
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            sound_enabled: true,
            sound_volume: 0.12,
            auto_close_interval: 15.0,
            absence_interval: 180.0,
            active_integrations: vec![
                "integration_resend".into(),
                "integration_n8n".into(),
                "integration_vercel".into(),
                "integration_github".into(),
            ],
            screen: "primary".into(),
            autostart: false,
            hooks_installed: false,
            model: default_model(),
            chat_engine: default_engine(),
            editor: String::new(),
            auto_approve: HashMap::new(),
            dnd_until: None,
            phone_alerts: false,
            ntfy_server: String::new(),
            ntfy_topic: String::new(),
            phone_only_when_away: true,
            inbox_enabled: true,
            inbox_github: true,
            inbox_linear: true,
            inbox_kinds: all_kinds(),
            check_updates: true,
            provider_id: default_provider(),
            provider_base_url: String::new(),
            provider_model: String::new(),
            language: default_language(),
            speak_replies: false,
        }
    }
}

/// Where settings live: %APPDATA%\Coucou or ~/.config/coucou.
pub fn config_dir() -> PathBuf {
    crate::platform::config_dir()
}

/// Where the relay, the log and dropped files live: %LOCALAPPDATA%\Coucou or
/// ~/.local/share/coucou.
pub fn local_dir() -> PathBuf {
    crate::platform::local_dir()
}

pub fn hook_exe_path() -> PathBuf {
    crate::platform::hook_exe_path()
}

fn settings_path() -> PathBuf {
    config_dir().join("settings.json")
}

pub fn load() -> Settings {
    match std::fs::read(settings_path()) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
        Err(_) => Settings::default(),
    }
}

pub fn save(settings: &Settings) -> std::io::Result<()> {
    let dir = config_dir();
    std::fs::create_dir_all(&dir)?;
    let json = serde_json::to_vec_pretty(settings)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    std::fs::write(settings_path(), json)
}
