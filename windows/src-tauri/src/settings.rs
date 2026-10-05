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
    /// Pills that never rotate out of the island (more than 4 can be active).
    #[serde(default)]
    pub pinned_pills: Vec<String>,
    /// Seconds between pill rotations when more than 4 are active; 0 = off.
    #[serde(default = "default_pill_rotation")]
    pub pill_rotation_seconds: u32,
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
    /// Codex / Gemini CLI chat engines (#108): the model to ask for ("" = the CLI's default).
    #[serde(default)]
    pub codex_model: String,
    #[serde(default)]
    pub gemini_model: String,
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
    /// Theme: "dark" (the original look), "light", "system" or a palette id (src/core/themes.ts).
    #[serde(default = "default_theme")]
    pub theme: String,

    /// Mochi reads its chat replies aloud.
    #[serde(default)]
    pub speak_replies: bool,

    /// When the island hides, a small notch stays at the top of the screen (like
    /// the Mac's), instead of nothing but an invisible strip.
    #[serde(default = "yes")]
    pub idle_notch: bool,

    /// Mochi moves with the music (#117). Off by default.
    #[serde(default)]
    pub mochi_dance: bool,

    /// WhaTicket: accept new tickets on their own (off by default), only from these
    /// queues (empty = any of mine), only during these hours ("09:00-18:00"; empty = always).
    #[serde(default)]
    pub whaticket_auto_accept: bool,
    /// Queue ids as text (whaticket.com uses UUIDs); numbers from an older build still load.
    #[serde(default, deserialize_with = "ids_as_text")]
    pub whaticket_queues: Vec<String>,
    #[serde(default)]
    pub whaticket_hours: String,

    /// Google: the connected account (shown in Settings) and the Gmail search the pill shows.
    #[serde(default)]
    pub google_email: String,
    #[serde(default = "default_gmail_query")]
    pub gmail_query: String,

    /// Time per Linear issue (#114): record session time in a local file (never uploaded).
    #[serde(default = "yes")]
    pub time_tracking: bool,
    /// Quick capture (#118): the shortcut that opens the one-line input ("" = off), and
    /// the team key used when the line has no #TEAM ("" = the only team, if there's one).
    #[serde(default = "default_capture_shortcut")]
    pub capture_shortcut: String,
    #[serde(default)]
    pub linear_default_team: String,
    /// Focus timer (#119 on macOS): block, break and long-break lengths in minutes, how many
    /// blocks before a long break, and the Ctrl+Alt+F shortcut. The timer itself runs in the page.
    #[serde(default = "default_focus_min")]
    pub focus_min: u32,
    #[serde(default = "default_break_min")]
    pub break_min: u32,
    #[serde(default = "default_long_break_min")]
    pub long_break_min: u32,
    #[serde(default = "default_blocks_before_long")]
    pub blocks_before_long: u32,
    #[serde(default = "yes")]
    pub focus_shortcut: bool,
}

fn default_focus_min() -> u32 {
    25
}

fn default_break_min() -> u32 {
    5
}

fn default_long_break_min() -> u32 {
    15
}

fn default_blocks_before_long() -> u32 {
    4
}

fn ids_as_text<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Vec<String>, D::Error> {
    let raw: Vec<serde_json::Value> = Deserialize::deserialize(d)?;
    Ok(raw
        .into_iter()
        .filter_map(|v| match v {
            serde_json::Value::String(s) => Some(s),
            serde_json::Value::Number(n) => Some(n.to_string()),
            _ => None,
        })
        .collect())
}

fn default_theme() -> String {
    "dark".into()
}

fn default_capture_shortcut() -> String {
    "Ctrl+Alt+L".into()
}

fn default_gmail_query() -> String {
    "is:unread in:inbox".into()
}

fn default_pill_rotation() -> u32 {
    30
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
            codex_model: String::new(),
            gemini_model: String::new(),
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
            pinned_pills: Vec::new(),
            pill_rotation_seconds: default_pill_rotation(),
            provider_id: default_provider(),
            provider_base_url: String::new(),
            provider_model: String::new(),
            language: default_language(),
            theme: default_theme(),
            speak_replies: false,
            idle_notch: true,
            mochi_dance: false,
            whaticket_auto_accept: false,
            whaticket_queues: Vec::new(),
            whaticket_hours: String::new(),
            google_email: String::new(),
            gmail_query: default_gmail_query(),
            time_tracking: true,
            capture_shortcut: default_capture_shortcut(),
            linear_default_team: String::new(),
            focus_min: default_focus_min(),
            break_min: default_break_min(),
            long_break_min: default_long_break_min(),
            blocks_before_long: default_blocks_before_long(),
            focus_shortcut: true,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whaticket_queues_load_from_numbers_or_text() {
        let old: Settings = serde_json::from_str(r#"{"soundEnabled":true,"soundVolume":0.1,"autoCloseInterval":15,"absenceInterval":180,"activeIntegrations":[],"screen":"primary","autostart":false,"hooksInstalled":false,"whaticketQueues":[1,"q-2"]}"#).unwrap();
        assert_eq!(old.whaticket_queues, vec!["1".to_string(), "q-2".to_string()]);
        let none: Settings = serde_json::from_str(r#"{"soundEnabled":true,"soundVolume":0.1,"autoCloseInterval":15,"absenceInterval":180,"activeIntegrations":[],"screen":"primary","autostart":false,"hooksInstalled":false}"#).unwrap();
        assert!(none.whaticket_queues.is_empty());
    }

    #[test]
    fn pill_settings_default_for_older_files_and_round_trip() {
        let old: Settings = serde_json::from_str(r#"{"soundEnabled":true,"soundVolume":0.1,"autoCloseInterval":15,"absenceInterval":180,"activeIntegrations":[],"screen":"primary","autostart":false,"hooksInstalled":false}"#).unwrap();
        assert!(old.pinned_pills.is_empty());
        assert_eq!(old.pill_rotation_seconds, 30);
        let json = serde_json::to_string(&Settings { pinned_pills: vec!["integration_github".into()], pill_rotation_seconds: 0, ..Settings::default() }).unwrap();
        let back: Settings = serde_json::from_str(&json).unwrap();
        assert_eq!(back.pinned_pills, vec!["integration_github".to_string()]);
        assert_eq!(back.pill_rotation_seconds, 0);
    }

    #[test]
    fn quick_capture_settings_default_for_older_files() {
        let old: Settings = serde_json::from_str(r#"{"soundEnabled":true,"soundVolume":0.1,"autoCloseInterval":15,"absenceInterval":180,"activeIntegrations":[],"screen":"primary","autostart":false,"hooksInstalled":false}"#).unwrap();
        assert_eq!(old.capture_shortcut, "Ctrl+Alt+L");
        assert!(old.linear_default_team.is_empty());
    }

    #[test]
    fn mochi_dance_is_off_for_older_files_and_round_trips() {
        let old: Settings = serde_json::from_str(r#"{"soundEnabled":true,"soundVolume":0.1,"autoCloseInterval":15,"absenceInterval":180,"activeIntegrations":[],"screen":"primary","autostart":false,"hooksInstalled":false}"#).unwrap();
        assert!(!old.mochi_dance);
        let json = serde_json::to_string(&Settings { mochi_dance: true, ..Settings::default() }).unwrap();
        assert!(json.contains(r#""mochiDance":true"#));
        let back: Settings = serde_json::from_str(&json).unwrap();
        assert!(back.mochi_dance);
    }
}
