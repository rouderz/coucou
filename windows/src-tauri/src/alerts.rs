// Phone alerts (#31 on macOS) and the update check.
//
// Phone alerts go through ntfy (https://ntfy.sh): a free app, no account. Coucou
// posts to a random topic only you know — it carries the project and the command,
// so the topic acts as a password.

use std::time::Duration;

use serde::Serialize;
use serde_json::Value;

use crate::platform;

/// A new random topic, "coucou-" + 16 hex characters.
pub fn new_topic() -> String {
    let seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
        ^ (std::process::id() as u128) << 64;
    // xorshift over the clock: unguessable enough for a topic name, no extra crate.
    let mut x = (seed as u64) ^ ((seed >> 64) as u64) ^ 0x9E37_79B9_7F4A_7C15;
    let mut out = String::from("coucou-");
    for _ in 0..16 {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        out.push(char::from_digit((x % 16) as u32, 16).unwrap());
    }
    out
}

/// Away: no keyboard or mouse for two minutes (Windows). Linux can't tell
/// without a compositor-specific API, so it counts as away.
pub fn user_is_away() -> bool {
    platform::idle_seconds().map(|s| s > 120).unwrap_or(true)
}

/// ntfy wants ASCII headers: UTF-8 titles go as RFC 2047.
fn encoded_title(title: &str) -> String {
    if title.is_ascii() {
        title.to_string()
    } else {
        format!("=?UTF-8?B?{}?=", crate::claude::base64_for(title.as_bytes()))
    }
}

pub async fn send(server: &str, topic: &str, title: &str, message: &str, priority: &str, tags: &str) -> Result<(), String> {
    if topic.trim().is_empty() {
        return Err("No ntfy topic yet".into());
    }
    let base = server.trim().trim_end_matches('/');
    let base = if base.is_empty() { "https://ntfy.sh" } else { base };
    if !(base.starts_with("https://") || base.starts_with("http://")) {
        return Err("The ntfy server must start with https://".into());
    }
    let body: String = message.chars().take(400).collect();
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?
        .post(format!("{base}/{}", topic.trim()))
        .header("Title", encoded_title(title))
        .header("Priority", priority)
        .header("Tags", tags)
        .body(body)
        .send()
        .await
        .map_err(|e| format!("Can't reach ntfy: {e}"))?;
    if response.status().is_success() {
        Ok(())
    } else {
        Err(format!("ntfy answered {}", response.status()))
    }
}

// ── Updates ──────────────────────────────────────────────────────────────────

const REPO: &str = "rouderz/coucou";

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInfo {
    pub current: String,
    pub latest: String,
    pub newer: bool,
    /// The file for this system, or the release page.
    pub url: String,
}

/// "0.10.0" > "0.9.3"; missing parts count as 0.
pub fn is_newer(a: &str, b: &str) -> bool {
    let parts = |v: &str| -> Vec<u64> {
        v.trim_start_matches('v')
            .split('.')
            .map(|p| p.chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse().unwrap_or(0))
            .collect()
    };
    let (pa, pb) = (parts(a), parts(b));
    for i in 0..pa.len().max(pb.len()) {
        let (x, y) = (pa.get(i).copied().unwrap_or(0), pb.get(i).copied().unwrap_or(0));
        if x != y {
            return x > y;
        }
    }
    false
}

/// Which release file this system wants.
fn asset_suffix() -> &'static str {
    if cfg!(windows) {
        "-Windows-setup.exe"
    } else if cfg!(target_arch = "aarch64") {
        "-Linux-arm64.AppImage"
    } else {
        "-Linux-x86_64.AppImage"
    }
}

pub fn parse_release(json: &Value, current: &str) -> Option<UpdateInfo> {
    if json.get("draft").and_then(Value::as_bool) == Some(true)
        || json.get("prerelease").and_then(Value::as_bool) == Some(true)
    {
        return None;
    }
    let tag = json.get("tag_name")?.as_str()?;
    let latest = tag.trim_start_matches('v').to_string();
    let page = json.get("html_url").and_then(Value::as_str).unwrap_or("https://github.com/rouderz/coucou/releases");
    let url = json
        .get("assets")
        .and_then(Value::as_array)
        .and_then(|assets| {
            assets.iter().find(|a| {
                a.get("name").and_then(Value::as_str).map(|n| n.ends_with(asset_suffix())).unwrap_or(false)
            })
        })
        .and_then(|a| a.get("browser_download_url").and_then(Value::as_str))
        .unwrap_or(page)
        .to_string();
    Some(UpdateInfo { current: current.to_string(), newer: is_newer(&latest, current), latest, url })
}

pub async fn check() -> Result<UpdateInfo, String> {
    let current = env!("CARGO_PKG_VERSION");
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?
        .get(format!("https://api.github.com/repos/{REPO}/releases/latest"))
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "Coucou")
        .send()
        .await
        .map_err(|_| "Can't reach GitHub".to_string())?;
    if response.status().as_u16() == 404 {
        return Ok(UpdateInfo { current: current.into(), latest: current.into(), newer: false, url: String::new() });
    }
    let json: Value = response.json().await.map_err(|e| e.to_string())?;
    parse_release(&json, current).ok_or_else(|| "No release found".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_compare_by_number() {
        assert!(is_newer("0.10.0", "0.9.3"));
        assert!(is_newer("v0.2.2", "0.2.1"));
        assert!(!is_newer("0.2.1", "0.2.1"));
        assert!(is_newer("1.2.1", "1.2"));
    }

    #[test]
    fn picks_this_systems_file() {
        let json = serde_json::json!({
            "tag_name": "v9.0.0", "html_url": "https://github.com/rouderz/coucou/releases/tag/v9.0.0",
            "assets": [
                { "name": "Coucou-9.0.0-macOS.dmg", "browser_download_url": "https://x/mac" },
                { "name": format!("Coucou-9.0.0{}", asset_suffix()), "browser_download_url": "https://x/mine" }
            ]
        });
        let info = parse_release(&json, "0.2.1").unwrap();
        assert!(info.newer);
        assert_eq!(info.url, "https://x/mine");
        assert!(parse_release(&serde_json::json!({ "tag_name": "v9", "prerelease": true }), "0.1").is_none());
    }

    #[test]
    fn topics_look_random() {
        let t = new_topic();
        assert!(t.starts_with("coucou-") && t.len() == 23);
    }
}
