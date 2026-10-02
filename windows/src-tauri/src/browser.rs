// The WhaTicket browser extension (Chrome, Edge, Brave, Chromium).
//
// whaticket.com only lets admins create API tokens, so instead of signing in
// ourselves we ride on the session the user already has open in their browser:
// a small extension reads the queue with it and talks to us through native
// messaging. This module puts the pieces in place:
//
//   * the unpacked extension, in <local>/browser-extension/, for the user to load
//     once from chrome://extensions or edge://extensions ("Load unpacked");
//   * the native-messaging host manifest, which tells the browser to start
//     coucou-hook (in its native-host mode) when the extension calls us;
//   * its registration with every Chromium browser: a file in the browser's
//     NativeMessagingHosts folder on Linux, a registry key on Windows.
//
// Only our own extension id may start the host (`allowed_origins`).

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::settings;

pub const HOST: &str = "fr.louisraille.coucou";
/// Fixed by the public `key` in the extension's manifest.json.
pub const EXTENSION_ID: &str = "jcdddeeehgafiakcgaabpiocfdijekce";

const FILES: &[(&str, &str)] = &[
    ("manifest.json", include_str!("../../../extensions/whaticket/manifest.json")),
    ("background.js", include_str!("../../../extensions/whaticket/background.js")),
    ("content.js", include_str!("../../../extensions/whaticket/content.js")),
];

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    /// Where the unpacked extension lives ("Load unpacked" points here).
    pub extension_dir: String,
    /// The extension files are written and current.
    pub installed: bool,
    /// Browsers the host is registered with ("Chrome", "Edge", …).
    pub browsers: Vec<String>,
    pub extension_id: String,
}

pub fn extension_dir() -> PathBuf {
    settings::local_dir().join("browser-extension")
}

fn host_manifest_path() -> PathBuf {
    settings::local_dir().join(format!("{HOST}.json"))
}

/// The native-messaging host manifest the browsers read.
pub fn host_manifest(exe: &Path) -> String {
    let body = serde_json::json!({
        "name": HOST,
        "description": "Coucou — WhaTicket queue in the notch",
        "path": exe.to_string_lossy(),
        "type": "stdio",
        "allowed_origins": [format!("chrome-extension://{EXTENSION_ID}/")],
    });
    serde_json::to_string_pretty(&body).unwrap_or_default()
}

fn files_current(dir: &Path) -> bool {
    FILES
        .iter()
        .all(|(name, text)| std::fs::read_to_string(dir.join(name)).map(|t| t == *text).unwrap_or(false))
}

pub fn status() -> Status {
    let dir = extension_dir();
    Status {
        extension_dir: dir.to_string_lossy().to_string(),
        installed: files_current(&dir),
        browsers: registered(),
        extension_id: EXTENSION_ID.into(),
    }
}

pub fn install() -> Result<Status, String> {
    let dir = extension_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("could not create {}: {e}", dir.display()))?;
    for (name, text) in FILES {
        std::fs::write(dir.join(name), text).map_err(|e| format!("could not write {name}: {e}"))?;
    }
    let exe = settings::hook_exe_path();
    if !exe.exists() {
        return Err(format!("{} is missing — restart Coucou and try again", exe.display()));
    }
    let manifest = host_manifest_path();
    std::fs::write(&manifest, host_manifest(&exe)).map_err(|e| format!("could not write the host manifest: {e}"))?;
    let browsers = register(&manifest)?;
    if browsers.is_empty() {
        return Err("No Chrome, Edge, Brave or Chromium found for this user".into());
    }
    crate::log::line(format!("browser extension installed for {}", browsers.join(", ")));
    Ok(status())
}

pub fn reveal() {
    let dir = extension_dir();
    if dir.exists() {
        crate::platform::open_folder(&dir.to_string_lossy());
    }
}

// ── Linux: a manifest file in each browser's NativeMessagingHosts folder ──────

#[cfg(target_os = "linux")]
fn browser_dirs() -> Vec<(&'static str, PathBuf)> {
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| crate::platform::home().join(".config"));
    [
        ("Chrome", "google-chrome"),
        ("Chrome Beta", "google-chrome-beta"),
        ("Chromium", "chromium"),
        ("Edge", "microsoft-edge"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Vivaldi", "vivaldi"),
    ]
    .into_iter()
    .map(|(name, sub)| (name, config.join(sub)))
    .collect()
}

#[cfg(target_os = "linux")]
fn register(manifest: &Path) -> Result<Vec<String>, String> {
    let text = std::fs::read_to_string(manifest).map_err(|e| e.to_string())?;
    let mut done = Vec::new();
    for (name, dir) in browser_dirs() {
        // Only browsers this user actually runs: their profile folder exists.
        if !dir.is_dir() {
            continue;
        }
        let hosts = dir.join("NativeMessagingHosts");
        if std::fs::create_dir_all(&hosts).is_ok() && std::fs::write(hosts.join(format!("{HOST}.json")), &text).is_ok() {
            done.push(name.to_string());
        }
    }
    Ok(done)
}

#[cfg(target_os = "linux")]
fn registered() -> Vec<String> {
    browser_dirs()
        .into_iter()
        .filter(|(_, dir)| dir.join("NativeMessagingHosts").join(format!("{HOST}.json")).exists())
        .map(|(name, _)| name.to_string())
        .collect()
}

// ── Windows: HKCU\Software\<browser>\NativeMessagingHosts\<host> ──────────────

#[cfg(windows)]
const REG_BROWSERS: &[(&str, &str)] = &[
    ("Chrome", r"Software\Google\Chrome"),
    ("Edge", r"Software\Microsoft\Edge"),
    ("Brave", r"Software\BraveSoftware\Brave-Browser"),
    ("Chromium", r"Software\Chromium"),
];

#[cfg(windows)]
fn reg(args: &[&str]) -> Option<String> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let out = std::process::Command::new("reg.exe")
        .args(args)
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).to_string())
}

#[cfg(windows)]
fn register(manifest: &Path) -> Result<Vec<String>, String> {
    // Registering under every browser is harmless: a browser that isn't
    // installed never reads its key. Edge and Chrome are the ones that matter.
    let path = manifest.to_string_lossy().to_string();
    let mut done = Vec::new();
    for (name, base) in REG_BROWSERS {
        let key = format!(r"HKCU\{base}\NativeMessagingHosts\{HOST}");
        if reg(&["add", &key, "/ve", "/t", "REG_SZ", "/d", &path, "/f"]).is_some() {
            done.push(name.to_string());
        }
    }
    Ok(done)
}

#[cfg(windows)]
fn registered() -> Vec<String> {
    let path = host_manifest_path().to_string_lossy().to_lowercase();
    REG_BROWSERS
        .iter()
        .filter(|(_, base)| {
            reg(&["query", &format!(r"HKCU\{base}\NativeMessagingHosts\{HOST}"), "/ve"])
                .map(|out| out.to_lowercase().contains(&path))
                .unwrap_or(false)
        })
        .map(|(name, _)| name.to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_our_extension_may_start_the_host() {
        let text = host_manifest(Path::new("/x/coucou-hook"));
        let v: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["name"], HOST);
        assert_eq!(v["type"], "stdio");
        assert_eq!(v["path"], "/x/coucou-hook");
        assert_eq!(v["allowed_origins"], serde_json::json!([format!("chrome-extension://{EXTENSION_ID}/")]));
    }

    #[test]
    fn ships_the_extension_files() {
        let manifest: serde_json::Value = serde_json::from_str(FILES[0].1).unwrap();
        assert_eq!(manifest["manifest_version"], 3);
        assert!(manifest["permissions"].as_array().unwrap().iter().any(|p| p == "nativeMessaging"));
        assert!(FILES[1].1.contains(HOST));
    }
}
