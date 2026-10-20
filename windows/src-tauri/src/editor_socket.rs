// A local WebSocket for the editor plugins that can't open Lumo's pipe / socket: Godot
// (GDScript has WebSocketPeer, no named pipes or Unix sockets) and Aseprite (its Lua has a
// WebSocket client). Same as NotchBuddy/Sources/App/EditorSocketServer.swift on macOS.
//
//   * 127.0.0.1 only, port 47615 or any free one.
//   * A token made at launch, written with the port to `<local_dir>/editor-bridge.json`
//     (%LOCALAPPDATA%\Coucou on Windows, ~/.local/share/coucou on Linux, mode 0600 there):
//     only the user's own programs can read it, so a web page can't talk to Lumo.
//   * A handshake with a web Origin (a browser) is refused.
//   * Only `EditorContext` / `EditorAsk` are accepted: nothing from here approves a Claude Code
//     permission or touches a session.
//
// One JSON text message per event, the same shape as on the pipe plus "token" (and, for
// Godot / Aseprite, "details" and "image"). The answer is {"ok":true} or {"ok":false,"error":…}.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::StatusCode;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;

use crate::island::WINDOW_LABEL;
use crate::log;

pub const PREFERRED_PORT: u16 = 47615;
const MAX_CONNECTIONS: usize = 8;
const MAX_MESSAGE: usize = 1 << 20;
const MAX_SNAPSHOT: u64 = 8 << 20;
const KEPT_SNAPSHOTS: usize = 20;

pub fn info_path() -> PathBuf {
    crate::settings::local_dir().join("editor-bridge.json")
}

/// Lumo's own folder for the plugins' snapshots; the chat's Claude Code may read it (--add-dir).
pub fn snapshots_dir() -> PathBuf {
    crate::settings::local_dir().join("snapshots")
}

pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let token = make_token();
        let listener = match TcpListener::bind(("127.0.0.1", PREFERRED_PORT)).await {
            Ok(l) => l,
            // Taken (another app): any free port, the plugins read it from editor-bridge.json.
            Err(_) => match TcpListener::bind(("127.0.0.1", 0)).await {
                Ok(l) => l,
                Err(err) => {
                    log::line(format!("cannot open the editor socket: {err}"));
                    return;
                }
            },
        };
        let port = listener.local_addr().map(|a| a.port()).unwrap_or(PREFERRED_PORT);
        if let Err(err) = write_info(port, &token) {
            log::line(format!("cannot write editor-bridge.json: {err}"));
            return;
        }
        log::line(format!("editor socket on 127.0.0.1:{port}"));
        let token = Arc::new(token);
        let open = Arc::new(AtomicUsize::new(0));
        loop {
            let Ok((stream, _)) = listener.accept().await else { continue };
            if open.load(Ordering::Relaxed) >= MAX_CONNECTIONS {
                continue; // dropped
            }
            open.fetch_add(1, Ordering::Relaxed);
            let (app, token, open) = (app.clone(), token.clone(), open.clone());
            tauri::async_runtime::spawn(async move {
                serve(app, stream, &token).await;
                open.fetch_sub(1, Ordering::Relaxed);
            });
        }
    });
}

/// A browser always sends its page's Origin (http/https): no web page gets past the handshake.
/// Godot sends none; Aseprite's IXWebSocket sends `ws://127.0.0.1:<port>`.
fn check_origin(req: &Request, resp: Response) -> Result<Response, ErrorResponse> {
    let origin = req
        .headers()
        .get("origin")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();
    if origin.starts_with("http://") || origin.starts_with("https://") {
        let mut refused = ErrorResponse::new(Some("Lumo's editor socket is for local apps only".into()));
        *refused.status_mut() = StatusCode::FORBIDDEN;
        return Err(refused);
    }
    Ok(resp)
}

async fn serve(app: AppHandle, stream: tokio::net::TcpStream, token: &str) {
    let mut config = WebSocketConfig::default();
    config.max_message_size = Some(MAX_MESSAGE);
    config.max_frame_size = Some(MAX_MESSAGE);
    let Ok(mut ws) = tokio_tungstenite::accept_hdr_async_with_config(stream, check_origin, Some(config)).await
    else {
        return;
    };
    while let Some(Ok(message)) = ws.next().await {
        let text = match message {
            Message::Text(t) => t.to_string(),
            Message::Binary(b) => String::from_utf8_lossy(&b).into_owned(),
            Message::Close(_) => break,
            _ => continue, // pings are answered by tungstenite
        };
        let answer = handle(&app, &text, token);
        if ws.send(Message::text(answer.to_string())).await.is_err() {
            break;
        }
    }
}

/// One message from a plugin. Returns the answer.
pub fn handle(app: &AppHandle, text: &str, token: &str) -> Value {
    let Some(mut payload) = parse(text, token) else {
        return json!({ "ok": false, "error": "bad token: read it again from editor-bridge.json" });
    };
    let event = payload.get("hook_event_name").and_then(Value::as_str).unwrap_or_default().to_string();
    match event.as_str() {
        "Ping" => json!({ "ok": true, "app": "Lumo" }),
        "EditorContext" | "EditorAsk" => {
            // Only "Ask Lumo" brings a snapshot, copied into our own folder.
            let image = payload.get("image").and_then(Value::as_str).map(str::to_string);
            let kept = if event == "EditorAsk" { image.and_then(|p| keep_snapshot(Path::new(&p))) } else { None };
            match kept {
                Some(p) => payload["image"] = json!(p),
                None => {
                    if let Some(obj) = payload.as_object_mut() {
                        obj.remove("image");
                    }
                }
            }
            log::line(format!("editor {event}"));
            let _ = app.emit_to(WINDOW_LABEL, "hook", payload);
            json!({ "ok": true })
        }
        _ => json!({ "ok": false, "error": "unknown event" }),
    }
}

/// The message as JSON, its token checked and removed. None when either fails.
pub(crate) fn parse(text: &str, token: &str) -> Option<Value> {
    let mut payload: Value = serde_json::from_str(text).ok()?;
    let given = payload.as_object_mut()?.remove("token")?;
    let given = given.as_str()?;
    if !same(given.as_bytes(), token.as_bytes()) {
        return None;
    }
    Some(payload)
}

/// Constant-time comparison.
fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && !b.is_empty() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn make_token() -> String {
    let mut bytes = [0u8; 24];
    if getrandom::getrandom(&mut bytes).is_err() {
        // Never happens on Windows / Linux; still, never ship an empty token.
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
            ^ (std::process::id() as u128) << 64;
        for (i, b) in bytes.iter_mut().enumerate() {
            *b = (seed >> ((i % 16) * 8)) as u8 ^ (i as u8).wrapping_mul(151);
        }
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn write_info(port: u16, token: &str) -> std::io::Result<()> {
    let path = info_path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let body = serde_json::to_vec_pretty(&json!({ "port": port, "token": token, "version": 1 }))
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&path)?;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        file.write_all(&body)?;
        Ok(())
    }
    #[cfg(not(unix))]
    {
        // %LOCALAPPDATA% is the user's own.
        std::fs::write(&path, body)
    }
}

/// Copies a plugin's PNG into `snapshots_dir()` and returns the copy's path; anything but a
/// reasonable PNG is ignored. Keeps the newest few.
pub(crate) fn keep_snapshot(source: &Path) -> Option<String> {
    keep_snapshot_in(source, &snapshots_dir())
}

pub(crate) fn keep_snapshot_in(source: &Path, dir: &Path) -> Option<String> {
    if !source.is_absolute() || !source.extension().is_some_and(|e| e.eq_ignore_ascii_case("png")) {
        return None;
    }
    let meta = std::fs::metadata(source).ok()?;
    if !meta.is_file() || meta.len() == 0 || meta.len() > MAX_SNAPSHOT {
        return None;
    }
    let bytes = std::fs::read(source).ok()?;
    if !bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        return None;
    }
    std::fs::create_dir_all(dir).ok()?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let dest = dir.join(format!("{stamp}-{}.png", std::process::id()));
    std::fs::write(&dest, &bytes).ok()?;
    if let Ok(entries) = std::fs::read_dir(dir) {
        let mut pngs: Vec<PathBuf> = entries
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|e| e == "png"))
            .collect();
        pngs.sort();
        let extra = pngs.len().saturating_sub(KEPT_SNAPSHOTS);
        for old in pngs.into_iter().take(extra) {
            let _ = std::fs::remove_file(old);
        }
    }
    Some(dest.display().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_is_required_and_removed() {
        let ok = parse(r#"{"token":"abc","hook_event_name":"Ping"}"#, "abc").unwrap();
        assert!(ok.get("token").is_none());
        assert!(parse(r#"{"token":"abd","hook_event_name":"Ping"}"#, "abc").is_none());
        assert!(parse(r#"{"hook_event_name":"Ping"}"#, "abc").is_none());
        assert!(parse(r#"{"token":"","hook_event_name":"Ping"}"#, "").is_none());
        assert!(parse("not json", "abc").is_none());
    }

    #[test]
    fn tokens_are_long_and_hex() {
        let t = make_token();
        assert_eq!(t.len(), 48);
        assert!(t.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(t, make_token());
    }

    /// The real handshake: local apps get in, a page from the web (it sends an Origin) doesn't.
    #[tokio::test]
    async fn web_pages_are_refused_at_the_handshake() {
        use tokio_tungstenite::tungstenite::client::IntoClientRequest;
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            for _ in 0..3 {
                let (stream, _) = listener.accept().await.unwrap();
                tokio::spawn(async move {
                    if let Ok(mut ws) = tokio_tungstenite::accept_hdr_async(stream, check_origin).await {
                        if let Some(Ok(Message::Text(t))) = ws.next().await {
                            let _ = ws.send(Message::text(format!("echo {t}"))).await;
                        }
                    }
                });
            }
        });
        let url = format!("ws://{addr}");

        let stream = tokio::net::TcpStream::connect(addr).await.unwrap();
        let (mut ws, _) = tokio_tungstenite::client_async(url.as_str(), stream).await.expect("local app accepted");
        ws.send(Message::text("hi")).await.unwrap();
        let answer = ws.next().await.unwrap().unwrap();
        assert_eq!(answer.into_text().unwrap().as_str(), "echo hi");

        // Aseprite's WebSocket (IXWebSocket) sends `Origin: ws://<host>:<port>`: still a local app.
        let mut request = url.as_str().into_client_request().unwrap();
        request.headers_mut().insert("Origin", format!("ws://{addr}").parse().unwrap());
        let stream = tokio::net::TcpStream::connect(addr).await.unwrap();
        assert!(tokio_tungstenite::client_async(request, stream).await.is_ok(), "Aseprite accepted");

        let mut request = url.as_str().into_client_request().unwrap();
        request.headers_mut().insert("Origin", "https://example.com".parse().unwrap());
        let stream = tokio::net::TcpStream::connect(addr).await.unwrap();
        assert!(tokio_tungstenite::client_async(request, stream).await.is_err(), "web page refused");
    }

    #[test]
    fn only_real_pngs_are_kept() {
        let tmp = std::env::temp_dir().join(format!("lumo-snap-test-{}", std::process::id()));
        let dir = tmp.join("kept");
        std::fs::create_dir_all(&tmp).unwrap();
        let png = tmp.join("frame.png");
        std::fs::write(&png, [0x89, b'P', b'N', b'G', 13, 10, 26, 10, 0]).unwrap();
        let fake = tmp.join("fake.png");
        std::fs::write(&fake, b"hello").unwrap();
        let kept = keep_snapshot_in(&png, &dir).unwrap();
        assert!(Path::new(&kept).starts_with(&dir));
        assert!(keep_snapshot_in(&fake, &dir).is_none());
        assert!(keep_snapshot_in(Path::new("relative.png"), &dir).is_none());
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
