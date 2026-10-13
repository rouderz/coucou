//! VPN on the main character's base (port of NotchBuddy/Sources/App/VPN.swift): the VPNs the
//! system knows about, whether one is on, and a click to turn it on or off. Only read while the
//! island is open; nothing leaves the computer.
//!
//! - Cloudflare WARP, everywhere, through its own `warp-cli`.
//! - Linux: NetworkManager VPN and WireGuard connections (`nmcli`), Proton VPN's among them.
//! - Windows: the VPN connections of Windows Settings (`Get-VpnConnection`, `rasdial`), and
//!   whether Proton VPN's adapter is up (its app starts and stops it).

use serde::Serialize;

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct VpnService {
    pub id: String,
    pub name: String,
    pub connected: bool,
    /// False when only its own app can turn it on or off (Proton VPN on Windows).
    pub can_toggle: bool,
}

async fn run(program: &str, args: &[&str]) -> Option<String> {
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(args).stdin(std::process::Stdio::null());
    crate::platform::hide_console_async(&mut cmd);
    let out = tokio::time::timeout(std::time::Duration::from_secs(6), cmd.output()).await.ok()?.ok()?;
    Some(String::from_utf8_lossy(&out.stdout).to_string())
}

fn warp_cli() -> Option<String> {
    if let Some(p) = crate::platform::find_program("warp-cli") {
        return Some(p.to_string_lossy().to_string());
    }
    #[cfg(windows)]
    {
        let p = r"C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe";
        if std::path::Path::new(p).exists() {
            return Some(p.to_string());
        }
    }
    None
}

/// `Status update: Connected` / `Disconnected`.
pub fn parse_warp(text: &str) -> Option<bool> {
    let l = text.to_lowercase();
    if l.contains("disconnected") {
        Some(false)
    } else if l.contains("connected") {
        Some(true)
    } else {
        None
    }
}

/// `nmcli -t -f NAME,UUID,TYPE,STATE connection show`: `Proton VPN NL#1:3f2…:wireguard:activated`.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn parse_nmcli(text: &str) -> Vec<VpnService> {
    text.lines()
        .filter_map(|line| {
            // NAME may contain escaped colons ("\:"); the last three fields never do.
            let parts: Vec<&str> = line.rsplitn(4, ':').collect();
            if parts.len() != 4 {
                return None;
            }
            let (state, kind, uuid, name) = (parts[0], parts[1], parts[2], parts[3]);
            if kind != "vpn" && kind != "wireguard" {
                return None;
            }
            Some(VpnService {
                id: format!("nm:{uuid}"),
                name: name.replace("\\:", ":"),
                connected: state == "activated" || state == "activating",
                can_toggle: true,
            })
        })
        .collect()
}

/// `Get-VpnConnection | Select Name,ConnectionStatus | ConvertTo-Json` (one object or a list).
#[cfg_attr(not(windows), allow(dead_code))]
pub fn parse_windows_vpn(json: &str) -> Vec<VpnService> {
    let value: serde_json::Value = match serde_json::from_str(json.trim()) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    let items = match value {
        serde_json::Value::Array(a) => a,
        v @ serde_json::Value::Object(_) => vec![v],
        _ => Vec::new(),
    };
    items
        .iter()
        .filter_map(|v| {
            let name = v.get("Name")?.as_str()?.to_string();
            let status = v.get("ConnectionStatus").and_then(|s| s.as_str()).unwrap_or("");
            Some(VpnService { id: format!("ras:{name}"), name, connected: status == "Connected", can_toggle: true })
        })
        .collect()
}

pub async fn list() -> Vec<VpnService> {
    let mut out = Vec::new();
    if let Some(cli) = warp_cli() {
        if let Some(connected) = run(&cli, &["status"]).await.as_deref().and_then(parse_warp) {
            out.push(VpnService { id: "warp".into(), name: "Cloudflare WARP".into(), connected, can_toggle: true });
        }
    }
    #[cfg(target_os = "linux")]
    {
        if let Some(text) = run("nmcli", &["-t", "-f", "NAME,UUID,TYPE,STATE", "connection", "show"]).await {
            out.extend(parse_nmcli(&text));
        }
    }
    #[cfg(windows)]
    {
        let script = "Get-VpnConnection | Select-Object Name,ConnectionStatus | ConvertTo-Json -Compress";
        if let Some(json) = run("powershell", &["-NoProfile", "-NonInteractive", "-Command", script]).await {
            out.extend(parse_windows_vpn(&json));
        }
        if proton_app().is_some() {
            let script = "(Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'ProtonVPN|Proton VPN' -or $_.Name -match 'ProtonVPN' } | Where-Object Status -eq 'Up').Count";
            let up = run("powershell", &["-NoProfile", "-NonInteractive", "-Command", script])
                .await
                .and_then(|s| s.trim().parse::<u32>().ok())
                .unwrap_or(0);
            out.push(VpnService { id: "proton".into(), name: "Proton VPN".into(), connected: up > 0, can_toggle: false });
        }
    }
    out
}

pub async fn toggle(id: &str, on: bool) -> Result<(), String> {
    if id == "warp" {
        let cli = warp_cli().ok_or("Cloudflare WARP isn't installed")?;
        run(&cli, &[if on { "connect" } else { "disconnect" }]).await;
        return Ok(());
    }
    if let Some(uuid) = id.strip_prefix("nm:") {
        run("nmcli", &["connection", if on { "up" } else { "down" }, "uuid", uuid]).await;
        return Ok(());
    }
    if let Some(name) = id.strip_prefix("ras:") {
        if on {
            run("rasdial", &[name]).await;
        } else {
            run("rasdial", &[name, "/disconnect"]).await;
        }
        return Ok(());
    }
    if id == "proton" {
        open_proton();
        return Ok(());
    }
    Err(format!("Unknown VPN {id}"))
}

#[cfg(windows)]
fn proton_app() -> Option<std::path::PathBuf> {
    [
        r"C:\Program Files\Proton\VPN\ProtonVPN.Launcher.exe",
        r"C:\Program Files (x86)\Proton\VPN\ProtonVPN.Launcher.exe",
        r"C:\Program Files\Proton Technologies\ProtonVPN\ProtonVPN.exe",
    ]
    .iter()
    .map(std::path::PathBuf::from)
    .find(|p| p.exists())
}

/// Opens Proton VPN's app if it's there, else its free plan's page.
pub fn open_proton() {
    #[cfg(windows)]
    if let Some(app) = proton_app() {
        crate::platform::spawn_quiet(&app, &[]);
        return;
    }
    #[cfg(target_os = "linux")]
    if let Some(app) = crate::platform::find_program("protonvpn-app") {
        crate::platform::spawn_quiet(&app, &[]);
        return;
    }
    crate::platform::open_url("https://protonvpn.com/free-vpn");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_nmcli() {
        let text = "Wired connection 1:aaa:802-3-ethernet:activated\n\
                    Proton VPN NL\\:1:bbb:wireguard:activated\n\
                    work:ccc:vpn:\n";
        let list = parse_nmcli(text);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].name, "Proton VPN NL:1");
        assert!(list[0].connected);
        assert_eq!(list[1].id, "nm:ccc");
        assert!(!list[1].connected);
    }

    #[test]
    fn reads_windows_vpns() {
        let one = r#"{"Name":"Office","ConnectionStatus":"Connected"}"#;
        assert_eq!(parse_windows_vpn(one)[0].id, "ras:Office");
        assert!(parse_windows_vpn(one)[0].connected);
        let many = r#"[{"Name":"A","ConnectionStatus":"Disconnected"},{"Name":"B","ConnectionStatus":"Connected"}]"#;
        assert_eq!(parse_windows_vpn(many).len(), 2);
        assert!(parse_windows_vpn("").is_empty());
    }

    #[test]
    fn reads_warp() {
        assert_eq!(parse_warp("Status update: Connected\nNetwork: healthy"), Some(true));
        assert_eq!(parse_warp("Status update: Disconnected\nReason: Manual"), Some(false));
        assert_eq!(parse_warp("Registration missing"), None);
    }
}
