// Google Workspace: Gmail in the island, Google Drive files in the chat.
//
// Sign-in is OAuth 2.0 for desktop apps with the user's own Google Cloud client
// (Gmail scopes are "restricted": a client shipped inside Coucou would need Google's
// verification). The system browser opens Google's consent page, Google redirects to
// http://127.0.0.1:<port> where Coucou listens for that one request, and the code is
// exchanged with PKCE (S256). The refresh token goes to the Credential Manager /
// Secret Service; access tokens stay in memory.
//
// Read-only scopes: gmail.readonly and drive.readonly. Coucou never sends a mail or
// changes a file. Only Google's APIs are contacted.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::{json, Value};
use tauri::AppHandle;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::integrations::{emit, IntegrationEvent, IntegrationUpdate};
use crate::{files, log, platform, secrets};

pub const ID: &str = "integration_gmail";
const AUTH_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const REVOKE_URL: &str = "https://oauth2.googleapis.com/revoke";
const SCOPES: &str = "openid email https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/drive.readonly";
const MAX_FILE: usize = 10 * 1024 * 1024;

struct Access {
    token: String,
    until: Instant,
}

static ACCESS: Mutex<Option<Access>> = Mutex::new(None);
/// Newest mail ids seen (None until the first poll, which only fills the card).
static SEEN: Mutex<Option<Vec<String>>> = Mutex::new(None);

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct DriveFile {
    pub id: String,
    pub name: String,
    pub mime_type: String,
    pub modified: String,
    pub link: String,
}

// ── Small crypto and encoding helpers (tested below) ──────────────────────────

/// SHA-256 (FIPS 180-4), for the PKCE challenge.
pub fn sha256(data: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    let mut msg = data.to_vec();
    let bits = (data.len() as u64).wrapping_mul(8);
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bits.to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([chunk[4 * i], chunk[4 * i + 1], chunk[4 * i + 2], chunk[4 * i + 3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let mut v = h;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let ch = (v[4] & v[5]) ^ (!v[4] & v[6]);
            let t1 = v[7].wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            let t2 = s0.wrapping_add(maj);
            v = [t1.wrapping_add(t2), v[0], v[1], v[2], v[3].wrapping_add(t1), v[4], v[5], v[6]];
        }
        for i in 0..8 {
            h[i] = h[i].wrapping_add(v[i]);
        }
    }
    let mut out = [0u8; 32];
    for i in 0..8 {
        out[4 * i..4 * i + 4].copy_from_slice(&h[i].to_be_bytes());
    }
    out
}

const B64URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// base64url without padding (RFC 4648 §5), as PKCE wants.
pub fn base64url(bytes: &[u8]) -> String {
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        let len = chunk.len() + 1;
        for i in 0..len {
            out.push(B64URL[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

/// Decodes base64 or base64url, with or without padding (Gmail bodies are base64url).
pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut acc = 0u32;
    let mut bits = 0;
    for c in text.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' | b'\n' | b'\r' => continue,
            _ => return None,
        };
        acc = acc << 6 | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

pub fn urlencode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// 32 unpredictable bytes. std's RandomState is keyed from the OS's random source
/// (ProcessPrng / getrandom) and SipHash is a PRF, so its outputs can't be guessed
/// from outside the process — enough for a PKCE verifier and the state value.
fn random_bytes() -> [u8; 32] {
    use std::hash::{BuildHasher, Hasher};
    let mut out = [0u8; 32];
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    for (i, part) in out.chunks_mut(8).enumerate() {
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_u128(nanos);
        h.write_usize(i);
        h.write_u32(std::process::id());
        part.copy_from_slice(&h.finish().to_le_bytes());
    }
    out
}

/// The `code` and `state` from the redirect's first line: "GET /?state=…&code=… HTTP/1.1".
pub fn parse_redirect(request: &str) -> Option<(Option<String>, Option<String>, Option<String>)> {
    let line = request.lines().next()?;
    let target = line.split_whitespace().nth(1)?;
    let query = target.split_once('?').map(|(_, q)| q).unwrap_or("");
    let (mut code, mut state, mut error) = (None, None, None);
    for pair in query.split('&') {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        let v = urldecode(v);
        match k {
            "code" => code = Some(v),
            "state" => state = Some(v),
            "error" => error = Some(v),
            _ => {}
        }
    }
    Some((code, state, error))
}

fn urldecode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok());
                match hex {
                    Some(b) => {
                        out.push(b);
                        i += 2;
                    }
                    None => out.push(b'%'),
                }
            }
            b => out.push(b),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

/// The text of a Gmail message (format=full): the first text/plain part, else text/html stripped.
pub fn message_text(payload: &Value) -> String {
    fn find(part: &Value, mime: &str) -> Option<String> {
        if part.get("mimeType").and_then(Value::as_str) == Some(mime) {
            let data = part.get("body").and_then(|b| b.get("data")).and_then(Value::as_str)?;
            return base64_decode(data).map(|b| String::from_utf8_lossy(&b).to_string());
        }
        part.get("parts")?.as_array()?.iter().find_map(|p| find(p, mime))
    }
    if let Some(text) = find(payload, "text/plain") {
        return text;
    }
    let html = find(payload, "text/html").unwrap_or_default();
    let mut out = String::new();
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                out.push(' ');
            }
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn header(message: &Value, name: &str) -> String {
    message
        .get("payload")
        .and_then(|p| p.get("headers"))
        .and_then(Value::as_array)
        .and_then(|hs| {
            hs.iter().find(|h| h.get("name").and_then(Value::as_str).map(|n| n.eq_ignore_ascii_case(name)).unwrap_or(false))
        })
        .and_then(|h| h.get("value"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

/// "Ana Pérez <ana@x.com>" → "Ana Pérez".
pub fn sender_name(from: &str) -> String {
    let name = from.split('<').next().unwrap_or(from).trim().trim_matches('"').trim();
    if name.is_empty() { from.trim_matches(|c| c == '<' || c == '>').to_string() } else { name.to_string() }
}

/// What Drive can hand us as text: Google files exported, plain files downloaded.
pub fn export_type(mime: &str) -> Option<(&'static str, &'static str)> {
    match mime {
        "application/vnd.google-apps.document" => Some(("text/plain", "txt")),
        "application/vnd.google-apps.spreadsheet" => Some(("text/csv", "csv")),
        "application/vnd.google-apps.presentation" => Some(("text/plain", "txt")),
        _ => None,
    }
}

// ── OAuth ─────────────────────────────────────────────────────────────────────

fn client() -> reqwest::Client {
    reqwest::Client::builder().timeout(Duration::from_secs(20)).build().unwrap_or_default()
}

fn client_credentials() -> Option<(String, String)> {
    Some((secrets::get("google-client-id")?, secrets::get("google-client-secret").unwrap_or_default()))
}

pub fn connected() -> bool {
    secrets::present("google-refresh-token")
}

/// Opens Google's consent page and waits (up to 5 minutes) for the redirect.
/// Returns the account's email address.
pub async fn connect() -> Result<String, String> {
    let (client_id, client_secret) =
        client_credentials().ok_or("Paste your Google OAuth client ID first (see the steps above).")?;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.map_err(|e| e.to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let redirect = format!("http://127.0.0.1:{port}");
    let verifier = base64url(&random_bytes());
    let state = base64url(&random_bytes()[..16]);
    let challenge = base64url(&sha256(verifier.as_bytes()));
    let url = format!(
        "{AUTH_URL}?client_id={}&redirect_uri={}&response_type=code&scope={}&code_challenge={challenge}&code_challenge_method=S256&state={state}&access_type=offline&prompt=consent",
        urlencode(&client_id),
        urlencode(&redirect),
        urlencode(SCOPES),
    );
    platform::open_url(&url);

    let code = tokio::time::timeout(Duration::from_secs(300), async {
        loop {
            let (mut socket, _) = listener.accept().await.map_err(|e| e.to_string())?;
            let mut buf = vec![0u8; 8192];
            // Browsers open idle "preconnect" sockets: don't let one hold up the real redirect.
            let n = match tokio::time::timeout(Duration::from_secs(5), socket.read(&mut buf)).await {
                Ok(Ok(n)) => n,
                _ => continue,
            };
            let request = String::from_utf8_lossy(&buf[..n]).to_string();
            let Some((code, got_state, error)) = parse_redirect(&request) else { continue };
            if code.is_none() && error.is_none() {
                // The browser asking for /favicon.ico or similar.
                let _ = socket.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
                continue;
            }
            let ok = error.is_none() && got_state.as_deref() == Some(state.as_str());
            let body = if ok {
                "<html><body style='font-family:system-ui;padding:40px'><h2>Coucou is connected to Google.</h2>You can close this tab.</body></html>"
            } else {
                "<html><body style='font-family:system-ui;padding:40px'><h2>Google sign-in didn't finish.</h2>Go back to Coucou and try again.</body></html>"
            };
            let reply = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = socket.write_all(reply.as_bytes()).await;
            let _ = socket.shutdown().await;
            if let Some(e) = error {
                return Err(format!("Google said: {e}"));
            }
            if !ok {
                return Err("The answer from Google didn't match this sign-in.".to_string());
            }
            return code.ok_or_else(|| "No code from Google".to_string());
        }
    })
    .await
    .map_err(|_| "Nobody finished signing in within 5 minutes.".to_string())??;

    let body = format!(
        "code={}&client_id={}&client_secret={}&redirect_uri={}&grant_type=authorization_code&code_verifier={}",
        urlencode(&code),
        urlencode(&client_id),
        urlencode(&client_secret),
        urlencode(&redirect),
        urlencode(&verifier)
    );
    let json = token_request(body).await?;
    let refresh = json.get("refresh_token").and_then(Value::as_str).ok_or("Google sent no refresh token")?;
    secrets::set("google-refresh-token", refresh)?;
    remember(&json);
    *SEEN.lock().unwrap() = None;
    let email = profile_email().await.unwrap_or_default();
    log::line(format!("google: connected {email}"));
    Ok(email)
}

async fn token_request(body: String) -> Result<Value, String> {
    let response = client()
        .post(TOKEN_URL)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(body)
        .send()
        .await
        .map_err(|_| "Can't reach Google".to_string())?;
    let code = response.status().as_u16();
    let json: Value = response.json().await.unwrap_or(json!({}));
    if code != 200 {
        let why = json.get("error_description").or_else(|| json.get("error")).and_then(Value::as_str).unwrap_or("");
        return Err(format!("Google refused the sign-in ({code}) {why}").trim().to_string());
    }
    Ok(json)
}

fn remember(json: &Value) {
    if let Some(token) = json.get("access_token").and_then(Value::as_str) {
        let secs = json.get("expires_in").and_then(Value::as_u64).unwrap_or(3600).saturating_sub(60);
        *ACCESS.lock().unwrap() = Some(Access { token: token.to_string(), until: Instant::now() + Duration::from_secs(secs) });
    }
}

async fn access_token() -> Result<String, String> {
    if let Some(a) = ACCESS.lock().unwrap().as_ref() {
        if Instant::now() < a.until {
            return Ok(a.token.clone());
        }
    }
    let refresh = secrets::get("google-refresh-token").ok_or("Not connected to Google")?;
    let (client_id, client_secret) = client_credentials().ok_or("Not connected to Google")?;
    let body = format!(
        "client_id={}&client_secret={}&refresh_token={}&grant_type=refresh_token",
        urlencode(&client_id),
        urlencode(&client_secret),
        urlencode(&refresh)
    );
    let json = token_request(body).await.map_err(|e| format!("{e} — connect Google again in Settings"))?;
    remember(&json);
    ACCESS.lock().unwrap().as_ref().map(|a| a.token.clone()).ok_or_else(|| "No access token".into())
}

/// Forgets the account here and revokes the token at Google.
pub async fn disconnect() {
    if let Some(refresh) = secrets::get("google-refresh-token") {
        let _ = client()
            .post(REVOKE_URL)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(format!("token={}", urlencode(&refresh)))
            .send()
            .await;
    }
    let _ = secrets::clear("google-refresh-token");
    *ACCESS.lock().unwrap() = None;
    *SEEN.lock().unwrap() = None;
}

async fn get(url: &str) -> Result<reqwest::Response, String> {
    let token = access_token().await?;
    let response = client().get(url).bearer_auth(token).send().await.map_err(|_| "Can't reach Google".to_string())?;
    match response.status().as_u16() {
        200 => Ok(response),
        401 => {
            *ACCESS.lock().unwrap() = None;
            Err("Google signed Coucou out — connect again in Settings".into())
        }
        403 => Err("Google refused (403): is the Gmail / Drive API turned on in your Google Cloud project?".into()),
        code => Err(format!("Google error {code}")),
    }
}

async fn get_json(url: &str) -> Result<Value, String> {
    get(url).await?.json().await.map_err(|e| e.to_string())
}

async fn profile_email() -> Result<String, String> {
    let json = get_json("https://gmail.googleapis.com/gmail/v1/users/me/profile").await?;
    Ok(json.get("emailAddress").and_then(Value::as_str).unwrap_or("").to_string())
}

// ── Gmail ─────────────────────────────────────────────────────────────────────

fn gmail_query(app: &AppHandle) -> String {
    use tauri::Manager;
    app.try_state::<crate::Shared>()
        .map(|s| s.settings.lock().unwrap().gmail_query.clone())
        .filter(|q| !q.trim().is_empty())
        .unwrap_or_else(|| "is:unread in:inbox".into())
}

pub async fn poll(app: AppHandle) {
    if !connected() || client_credentials().is_none() {
        return;
    }
    let query = gmail_query(&app);
    let list = match get_json(&format!(
        "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=10&q={}",
        urlencode(&query)
    ))
    .await
    {
        Ok(j) => j,
        Err(e) => {
            emit(&app, IntegrationUpdate { id: ID, data: json!({}), error: Some(e), event: None });
            return;
        }
    };
    let total = list.get("resultSizeEstimate").and_then(Value::as_u64).unwrap_or(0);
    let ids: Vec<String> = list
        .get("messages")
        .and_then(Value::as_array)
        .map(|m| m.iter().filter_map(|x| x.get("id").and_then(Value::as_str).map(str::to_string)).collect())
        .unwrap_or_default();

    let mut mails = Vec::new();
    for id in ids.iter().take(5) {
        let url = format!(
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/{id}?format=metadata&metadataHeaders=From&metadataHeaders=Subject"
        );
        let Ok(m) = get_json(&url).await else { continue };
        let from = header(&m, "From");
        mails.push(json!({
            "id": id,
            "threadId": m.get("threadId").and_then(Value::as_str).unwrap_or(id),
            "from": sender_name(&from),
            "subject": header(&m, "Subject"),
            "snippet": m.get("snippet").and_then(Value::as_str).unwrap_or(""),
            "date": m.get("internalDate").and_then(Value::as_str).and_then(|d| d.parse::<u64>().ok()).unwrap_or(0),
        }));
    }

    // A mail we haven't seen before (the first poll only fills the card).
    let event = {
        let mut seen = SEEN.lock().unwrap();
        let fresh = match seen.as_ref() {
            None => None,
            Some(old) => mails.iter().find(|m| !old.contains(&m["id"].as_str().unwrap_or("").to_string())).cloned(),
        };
        *seen = Some(ids.clone());
        fresh.map(|m| IntegrationEvent {
            success: true,
            label: format!("Mail · {}", m["from"].as_str().unwrap_or("")),
            detail: m["subject"].as_str().filter(|s| !s.is_empty()).map(str::to_string),
        })
    };

    emit(&app, IntegrationUpdate {
        id: ID,
        data: json!({ "mails": mails, "total": total, "query": query }),
        error: None,
        event,
    });
}

/// Saves a mail as a text file in the inbox, to attach to the chat.
pub async fn mail_to_file(id: &str) -> Result<files::DroppedFile, String> {
    if !id.chars().all(|c| c.is_ascii_alphanumeric()) {
        return Err("Unknown mail".into());
    }
    let m = get_json(&format!("https://gmail.googleapis.com/gmail/v1/users/me/messages/{id}?format=full")).await?;
    let text = format!(
        "From: {}\nTo: {}\nDate: {}\nSubject: {}\n\n{}",
        header(&m, "From"),
        header(&m, "To"),
        header(&m, "Date"),
        header(&m, "Subject"),
        m.get("payload").map(message_text).unwrap_or_default()
    );
    let subject = header(&m, "Subject");
    save_text(&format!("Mail - {}", if subject.is_empty() { "no subject" } else { &subject }), "txt", text.as_bytes())
}

// ── Drive ─────────────────────────────────────────────────────────────────────

pub async fn drive_search(text: &str) -> Result<Vec<DriveFile>, String> {
    let escaped = text.trim().replace('\\', "\\\\").replace('\'', "\\'");
    let q = if escaped.is_empty() {
        "trashed = false".to_string()
    } else {
        format!("name contains '{escaped}' and trashed = false")
    };
    let url = format!(
        "https://www.googleapis.com/drive/v3/files?pageSize=8&orderBy=modifiedTime%20desc&fields=files(id,name,mimeType,modifiedTime,webViewLink)&q={}",
        urlencode(&q)
    );
    let json = get_json(&url).await?;
    Ok(json
        .get("files")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|f| {
                    Some(DriveFile {
                        id: f.get("id")?.as_str()?.to_string(),
                        name: f.get("name").and_then(Value::as_str).unwrap_or("").to_string(),
                        mime_type: f.get("mimeType").and_then(Value::as_str).unwrap_or("").to_string(),
                        modified: f.get("modifiedTime").and_then(Value::as_str).unwrap_or("").to_string(),
                        link: f.get("webViewLink").and_then(Value::as_str).unwrap_or("").to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default())
}

/// Downloads a Drive file into the inbox (Google Docs / Sheets / Slides exported as text / CSV).
pub async fn drive_to_file(id: &str, name: &str, mime: &str) -> Result<files::DroppedFile, String> {
    if !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return Err("Unknown file".into());
    }
    let (url, ext) = match export_type(mime) {
        Some((to, ext)) => (format!("https://www.googleapis.com/drive/v3/files/{id}/export?mimeType={}", urlencode(to)), Some(ext)),
        None if mime.starts_with("application/vnd.google-apps") => {
            return Err("Coucou can read Docs, Sheets, Slides and ordinary files — not this kind.".into())
        }
        None => (format!("https://www.googleapis.com/drive/v3/files/{id}?alt=media"), None),
    };
    let response = get(&url).await?;
    let bytes = response.bytes().await.map_err(|e| e.to_string())?;
    if bytes.len() > MAX_FILE {
        return Err("That file is over 10 MB — too big for the chat.".into());
    }
    match ext {
        Some(ext) => save_text(name, ext, &bytes),
        None => {
            let (stem, ext) = name.rsplit_once('.').unwrap_or((name, "bin"));
            save_text(stem, ext, &bytes)
        }
    }
}

/// Writes into the inbox (swept after a week, like dropped files) under a safe name.
fn save_text(name: &str, ext: &str, bytes: &[u8]) -> Result<files::DroppedFile, String> {
    let safe: String = name
        .chars()
        .map(|c| if c.is_alphanumeric() || " -_().,".contains(c) { c } else { '_' })
        .collect::<String>()
        .trim()
        .chars()
        .take(80)
        .collect();
    let safe = if safe.is_empty() { "file".to_string() } else { safe };
    let ext: String = ext.chars().filter(|c| c.is_ascii_alphanumeric()).take(8).collect();
    let dir = files::inbox_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let mut path = dir.join(format!("{safe}.{ext}"));
    let mut i = 2;
    while path.exists() {
        path = dir.join(format!("{safe} ({i}).{ext}"));
        i += 1;
    }
    std::fs::write(&path, bytes).map_err(|e| e.to_string())?;
    Ok(files::DroppedFile {
        name: path.file_name().unwrap_or_default().to_string_lossy().to_string(),
        path: path.to_string_lossy().to_string(),
        size: bytes.len() as u64,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    #[test]
    fn sha256_vectors() {
        assert_eq!(hex(&sha256(b"")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        assert_eq!(hex(&sha256(b"abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        let long = vec![b'a'; 1000];
        assert_eq!(hex(&sha256(&long)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3");
    }

    #[test]
    fn pkce_rfc7636_example() {
        // RFC 7636 appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        assert_eq!(base64url(&sha256(verifier.as_bytes())), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    }

    #[test]
    fn base64_round_trip() {
        assert_eq!(base64url(b"hi?"), "aGk_");
        assert_eq!(base64_decode("aGk_").unwrap(), b"hi?");
        assert_eq!(base64_decode("SGVsbG8gd29ybGQ=").unwrap(), b"Hello world");
    }

    #[test]
    fn redirect_parsing() {
        let (code, state, error) = parse_redirect("GET /?state=abc&code=4%2F0Ab&scope=x HTTP/1.1\r\nHost: x").unwrap();
        assert_eq!(code.as_deref(), Some("4/0Ab"));
        assert_eq!(state.as_deref(), Some("abc"));
        assert!(error.is_none());
        let (_, _, error) = parse_redirect("GET /?error=access_denied&state=abc HTTP/1.1").unwrap();
        assert_eq!(error.as_deref(), Some("access_denied"));
    }

    #[test]
    fn mail_bits() {
        assert_eq!(sender_name("\"Ana Pérez\" <ana@x.com>"), "Ana Pérez");
        assert_eq!(sender_name("<ana@x.com>"), "ana@x.com");
        let payload = json!({ "mimeType": "multipart/alternative", "parts": [
            { "mimeType": "text/html", "body": { "data": base64url(b"<p>Hola</p>") } },
            { "mimeType": "text/plain", "body": { "data": base64url(b"Hola, plain") } },
        ]});
        assert_eq!(message_text(&payload), "Hola, plain");
        let html_only = json!({ "mimeType": "text/html", "body": { "data": base64url(b"<p>Hola <b>t\xc3\xba</b></p>") } });
        assert_eq!(message_text(&html_only), "Hola tú");
    }

    #[test]
    fn exports() {
        assert_eq!(export_type("application/vnd.google-apps.spreadsheet"), Some(("text/csv", "csv")));
        assert_eq!(export_type("application/pdf"), None);
        assert_eq!(urlencode("a b/c"), "a%20b%2Fc");
    }
}
