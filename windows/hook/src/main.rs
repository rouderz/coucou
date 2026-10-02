//! coucou-hook — the relay Claude Code runs on every hook event.
//!
//! Reads the hook JSON on stdin, adds a little terminal context, and hands it to
//! Coucou: over the named pipe `\\.\pipe\coucou-<sid>` on Windows, over the
//! Unix socket `$XDG_RUNTIME_DIR/coucou.sock` on Linux (#33).
//!
//! Hard rule (docs/CLAUDE.md): **never block Claude Code.**
//! * If the pipe does not exist — Coucou is closed — we exit 0 immediately with
//!   nothing on stdout, and the session carries on untouched.
//! * Every step runs under a deadline enforced by the main thread, so a pipe that
//!   accepts the connection and then stops reading cannot wedge the session
//!   either: we abandon the worker and exit.
//! * Only `PermissionRequest` waits for an answer, because approving from the
//!   island is the whole point. No answer means empty stdout, and Claude Code
//!   asks in the terminal exactly as if Coucou were not installed.
//!
//! Usage: `coucou-hook <EventName>` (the name is also read from the JSON).
//!
//! It is also the native-messaging host of the WhaTicket browser extension: the
//! browser starts it with the extension's origin (`chrome-extension://…/`) as the
//! first argument, hands it one length-prefixed JSON message on stdin, and reads
//! one length-prefixed answer from stdout. See `native_host()`.

use std::io::{Read, Write};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Budget for getting a pipe connection. Beyond this Claude Code wins, always.
const CONNECT_TIMEOUT: Duration = Duration::from_millis(300);
/// Whole-run budget for an event nobody waits on: connect and write, no more.
const FIRE_AND_FORGET_BUDGET: Duration = Duration::from_secs(2);
/// How long a permission prompt may stay on screen before the terminal takes over.
const DECISION_BUDGET: Duration = Duration::from_secs(110);
/// How long the browser extension waits for Coucou's answer to a check-in.
const BROWSER_BUDGET: Duration = Duration::from_secs(10);
/// The browser never sends us more than this in one message for our purposes
/// (a queue snapshot); anything larger is not ours.
const MAX_BROWSER_MESSAGE: usize = 1 << 20;

/// `ERROR_PIPE_BUSY` — every instance is serving someone else right now. This is
/// the one error worth retrying: the server exists and a slot will free up.
#[cfg(windows)]
const ERROR_PIPE_BUSY: i32 = 231;

/// Fields that are pointless to forward and can be enormous (a whole file read,
/// a full command output). The island never shows them.
const DROPPED_FIELDS: &[&str] = &["tool_response", "transcript_path"];
/// Longest string forwarded for any single field; the island truncates to far
/// less than this anyway.
const MAX_FIELD_LEN: usize = 2_000;

#[cfg(windows)]
mod win;

/// `\\.\pipe\coucou-<sid>`. The SID keeps two accounts on the same machine from
/// ever meeting on the same pipe; the name falls back to the user name only if
/// the SID cannot be read at all, which should not happen.
#[cfg(windows)]
fn pipe_path() -> String {
    let key = win::current_user_sid()
        .unwrap_or_else(|| std::env::var("USERNAME").unwrap_or_else(|_| "user".into()));
    format!(r"\\.\pipe\coucou-{key}")
}

/// `$XDG_RUNTIME_DIR/coucou.sock`, or `/tmp/coucou-<uid>/coucou.sock` without a
/// runtime dir. Must match the app's `pipe::socket_path()` exactly.
#[cfg(unix)]
fn socket_path() -> std::path::PathBuf {
    match std::env::var_os("XDG_RUNTIME_DIR").map(std::path::PathBuf::from) {
        Some(dir) if dir.is_absolute() && dir.is_dir() => dir.join("coucou.sock"),
        _ => std::path::PathBuf::from(format!("/tmp/coucou-{}", unix_uid())).join("coucou.sock"),
    }
}

#[cfg(unix)]
fn unix_uid() -> u32 {
    unsafe { libc::getuid() }
}

/// Opens the socket. Only one that belongs to us: a socket file somebody else
/// owns gets nothing, as with the pipe owner check on Windows. A missing socket
/// (Coucou closed) fails at once.
#[cfg(unix)]
fn connect() -> Option<std::os::unix::net::UnixStream> {
    use std::os::unix::fs::MetadataExt;
    let path = socket_path();
    let owner = std::fs::metadata(&path).ok()?.uid();
    if owner != unix_uid() {
        return None;
    }
    let stream = std::os::unix::net::UnixStream::connect(&path).ok()?;
    let _ = stream.set_write_timeout(Some(CONNECT_TIMEOUT));
    Some(stream)
}

/// Opens the pipe. Retries only while the server is busy: any other error means
/// there is nothing to talk to, and waiting would only delay Claude Code.
#[cfg(windows)]
fn connect() -> Option<std::fs::File> {
    use std::os::windows::io::AsRawHandle;
    let path = pipe_path();
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    loop {
        match std::fs::OpenOptions::new().read(true).write(true).open(&path) {
            Ok(file) => {
                let handle = windows::Win32::Foundation::HANDLE(file.as_raw_handle());
                // Somebody else's server on our pipe name gets nothing from us.
                return win::pipe_server_is_same_user(handle).then_some(file);
            }
            Err(err) => {
                if err.raw_os_error() != Some(ERROR_PIPE_BUSY) || Instant::now() >= deadline {
                    return None;
                }
                std::thread::sleep(Duration::from_millis(15));
            }
        }
    }
}

fn main() {
    // Coucou's own chat runs through Claude Code too (the subscription engine):
    // its activity is not the user's work and never reaches the island.
    if std::env::var("COUCOU_INTERNAL").as_deref() == Ok("1") {
        std::process::exit(0);
    }
    // Claude Code's status line (`coucou-hook --statusline`): forward the plan
    // usage to the island, print a short line for the terminal.
    if std::env::args().any(|a| a == "--statusline") {
        status_line();
        std::process::exit(0);
    }
    // Started by Chrome/Edge for the WhaTicket extension.
    if let Some(origin) = std::env::args().nth(1).filter(|a| a.starts_with("chrome-extension://")) {
        native_host(&origin);
        std::process::exit(0);
    }
    let Some((payload, event)) = read_event() else { std::process::exit(0) };

    let waits_for_answer = event == "PermissionRequest";
    let budget = if waits_for_answer { DECISION_BUDGET } else { FIRE_AND_FORGET_BUDGET };

    // The worker owns every blocking call. If it overruns the budget we simply
    // stop listening and exit: the process dying takes the pipe handle with it.
    // (No catch_unwind here — the release profile is panic = "abort", so it would
    // be dead code. `talk` is written to have nothing to panic on instead.)
    let (tx, rx) = mpsc::channel::<Option<String>>();
    std::thread::spawn(move || {
        let _ = tx.send(talk(&payload, waits_for_answer));
    });

    if let Ok(Some(decision)) = rx.recv_timeout(budget) {
        if let Some(json) = decision_json(&decision) {
            let mut out = std::io::stdout();
            let _ = writeln!(out, "{json}");
            let _ = out.flush();
        }
    }
    // Nothing printed: Claude Code asks in the terminal, as if we were not here.
    std::process::exit(0);
}

/// Native-messaging mode: one message in, one answer out, each a 4-byte
/// native-endian length followed by UTF-8 JSON. The browser already checked the
/// origin against `allowed_origins` in our host manifest.
fn native_host(origin: &str) {
    let mut stdin = std::io::stdin();
    let answer = match read_message(&mut stdin) {
        Some(mut message) if message.is_object() => {
            message["hook_event_name"] = "WhaTicketBrowser".into();
            message["origin"] = origin.into();
            let line = message.to_string() + "\n";
            let (tx, rx) = mpsc::channel::<Option<String>>();
            std::thread::spawn(move || {
                let _ = tx.send(talk(&line, true));
            });
            rx.recv_timeout(BROWSER_BUDGET)
                .ok()
                .flatten()
                .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
                .filter(|v| v.is_object())
                .unwrap_or_else(|| serde_json::json!({ "unreachable": "Coucou isn't running" }))
        }
        _ => serde_json::json!({ "error": "bad message" }),
    };
    let mut out = std::io::stdout();
    let _ = out.write_all(&frame(&answer));
    let _ = out.flush();
}

fn read_message(input: &mut impl Read) -> Option<serde_json::Value> {
    let mut len = [0u8; 4];
    input.read_exact(&mut len).ok()?;
    let len = u32::from_ne_bytes(len) as usize;
    if len == 0 || len > MAX_BROWSER_MESSAGE {
        return None;
    }
    let mut body = vec![0u8; len];
    input.read_exact(&mut body).ok()?;
    serde_json::from_slice(&body).ok()
}

fn frame(value: &serde_json::Value) -> Vec<u8> {
    let body = value.to_string().into_bytes();
    let mut out = (body.len() as u32).to_ne_bytes().to_vec();
    out.extend_from_slice(&body);
    out
}

/// The documented PermissionRequest output. Anything we do not recognise prints
/// nothing at all rather than guessing — silence is the safe answer.
/// See https://code.claude.com/docs/en/hooks
fn decision_json(decision: &str) -> Option<String> {
    let behavior = match decision.trim() {
        // "always" still answers a plain allow; remembering it is the island's
        // business, not Claude Code's.
        "allow" | "always" => r#"{"behavior":"allow"}"#.to_string(),
        "deny" => r#"{"behavior":"deny","message":"Denied from Coucou"}"#.to_string(),
        _ => return None,
    };
    Some(format!(
        r#"{{"hookSpecificOutput":{{"hookEventName":"PermissionRequest","decision":{behavior}}}}}"#
    ))
}

/// Reads stdin and returns the payload to forward plus the event name.
fn read_event() -> Option<(String, String)> {
    let mut raw = Vec::new();
    if std::io::stdin().read_to_end(&mut raw).is_err() || raw.is_empty() {
        return None;
    }
    // Some shells hand us a UTF-8 BOM; serde_json would choke on it.
    if raw.starts_with(&[0xEF, 0xBB, 0xBF]) {
        raw.drain(..3);
    }

    let mut payload = serde_json::from_slice::<serde_json::Value>(&raw).ok()?;
    let map = payload.as_object_mut()?;

    // The event name is passed as an argument by the Claude Code hook command; the
    // JSON usually carries it too. Trust the argument when the JSON is missing it.
    // `--agent codex` marks the relay installed for Codex CLI.
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (arg_event, agent) = parse_args(&args);
    if let Some(agent) = agent {
        map.insert("agent".into(), serde_json::Value::String(agent));
    }
    let event = map
        .get("hook_event_name")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .filter(|s| !s.is_empty())
        .unwrap_or(arg_event);
    map.insert("hook_event_name".into(), serde_json::Value::String(event.clone()));

    for field in DROPPED_FIELDS {
        map.remove(*field);
    }

    let cwd_missing = map
        .get("cwd")
        .and_then(|v| v.as_str())
        .map(str::is_empty)
        .unwrap_or(true);
    if cwd_missing {
        if let Ok(cwd) = std::env::current_dir() {
            map.insert(
                "cwd".into(),
                serde_json::Value::String(cwd.to_string_lossy().to_string()),
            );
        }
    }

    // Which terminal the session runs in. Unlike macOS, Coucou on Windows accepts
    // events from every terminal, so this is context only — never a filter.
    for (key, var) in [
        ("term_program", "TERM_PROGRAM"),
        ("wt_session", "WT_SESSION"),
        ("term_session_id", "TERM_SESSION_ID"),
        ("vscode_pid", "VSCODE_PID"),
        ("session_pid", "CLAUDE_CODE_SSE_PORT"),
    ] {
        if !map.contains_key(key) {
            let value = std::env::var(var).unwrap_or_default();
            map.insert(key.into(), serde_json::Value::String(value));
        }
    }

    truncate_strings(&mut payload);

    let mut line = payload.to_string();
    line.push('\n');
    Some((line, event))
}

/// Status line mode. Claude Code only hands rate limits to its status line, so
/// this is how the island gets the plan usage bars. Never waits more than the
/// connect budget, and always prints something for the terminal.
fn status_line() {
    let mut raw = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut raw);
    if raw.starts_with(&[0xEF, 0xBB, 0xBF]) {
        raw.drain(..3);
    }
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&raw) else { return };
    let mut out = std::io::stdout();
    let _ = writeln!(out, "{}", status_text(&v));
    let _ = out.flush();

    let mut forward = serde_json::Map::new();
    forward.insert("hook_event_name".into(), "StatusLine".into());
    for key in ["session_id", "cwd", "model", "rate_limits", "context_window"] {
        if let Some(value) = v.get(key) {
            forward.insert(key.into(), value.clone());
        }
    }
    let line = serde_json::Value::Object(forward).to_string() + "\n";
    let (tx, rx) = mpsc::channel::<()>();
    std::thread::spawn(move || {
        let _ = talk(&line, false);
        let _ = tx.send(());
    });
    let _ = rx.recv_timeout(CONNECT_TIMEOUT * 2);
}

/// "Opus 5.5 · ctx 34% · 5h 42%" — what the terminal shows.
fn status_text(v: &serde_json::Value) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some(name) = v.pointer("/model/display_name").and_then(|x| x.as_str()) {
        parts.push(name.to_string());
    }
    if let Some(p) = v.pointer("/context_window/used_percentage").and_then(|x| x.as_f64()) {
        parts.push(format!("ctx {}%", p.round()));
    }
    if let Some(p) = v.pointer("/rate_limits/five_hour/used_percentage").and_then(|x| x.as_f64()) {
        parts.push(format!("5h {}%", p.round()));
    }
    if let Some(p) = v.pointer("/rate_limits/seven_day/used_percentage").and_then(|x| x.as_f64()) {
        parts.push(format!("7d {}%", p.round()));
    }
    if parts.is_empty() {
        "Coucou".into()
    } else {
        parts.join(" · ")
    }
}

/// `[Event] [--agent NAME]`, in any order.
fn parse_args(args: &[String]) -> (String, Option<String>) {
    let mut event = String::new();
    let mut agent = None;
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--agent" {
            agent = args.get(i + 1).filter(|a| !a.is_empty()).cloned();
            i += 2;
            continue;
        }
        if event.is_empty() && !args[i].starts_with("--") {
            event = args[i].clone();
        }
        i += 1;
    }
    (event, agent)
}

/// Caps every string in the payload. A single Write can carry a whole file.
fn truncate_strings(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::String(s) => {
            if s.len() > MAX_FIELD_LEN {
                // Cut on a char boundary; a lone byte index can split UTF-8.
                let mut end = MAX_FIELD_LEN;
                while end > 0 && !s.is_char_boundary(end) {
                    end -= 1;
                }
                s.truncate(end);
                s.push('…');
            }
        }
        serde_json::Value::Array(items) => items.iter_mut().for_each(truncate_strings),
        serde_json::Value::Object(map) => map.values_mut().for_each(truncate_strings),
        _ => {}
    }
}

/// Connect, send, and — for a permission request — wait for the island's word.
fn talk(payload: &str, waits_for_answer: bool) -> Option<String> {
    let mut pipe = connect()?;

    if pipe.write_all(payload.as_bytes()).is_err() {
        return None;
    }
    let _ = pipe.flush();

    if !waits_for_answer {
        return None;
    }

    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        match pipe.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.contains(&b'\n') {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    let answer = String::from_utf8_lossy(&buf).trim().to_string();
    (!answer.is_empty()).then_some(answer)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decision_json_matches_the_documented_shape() {
        assert_eq!(
            decision_json("allow").unwrap(),
            r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        );
        assert_eq!(
            decision_json("deny").unwrap(),
            r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Coucou"}}}"#
        );
        // "always" is an island concept; Claude Code just gets an allow.
        assert!(decision_json("always").unwrap().contains(r#""behavior":"allow""#));
    }

    #[test]
    fn the_status_line_reads_like_the_island() {
        let v = serde_json::json!({
            "model": { "display_name": "Opus 5.5" },
            "context_window": { "used_percentage": 33.6 },
            "rate_limits": { "five_hour": { "used_percentage": 42.0 }, "seven_day": { "used_percentage": 18.2 } }
        });
        assert_eq!(status_text(&v), "Opus 5.5 · ctx 34% · 5h 42% · 7d 18%");
        assert_eq!(status_text(&serde_json::json!({})), "Coucou");
    }

    #[test]
    fn arguments_give_the_event_and_the_agent() {
        let a = |v: &[&str]| parse_args(&v.iter().map(|s| s.to_string()).collect::<Vec<_>>());
        assert_eq!(a(&["Stop"]), ("Stop".to_string(), None));
        assert_eq!(a(&["--agent", "codex"]), (String::new(), Some("codex".to_string())));
        assert_eq!(a(&["PreToolUse", "--agent", "codex"]), ("PreToolUse".to_string(), Some("codex".to_string())));
    }

    #[test]
    fn anything_unrecognised_prints_nothing() {
        assert!(decision_json("").is_none());
        assert!(decision_json("maybe").is_none());
        // The shape the app used to send must not be mistaken for a decision.
        assert!(decision_json(r#"{"permissionDecision":"allow"}"#).is_none());
    }

    #[test]
    fn browser_messages_are_length_prefixed() {
        let v = serde_json::json!({ "kind": "snapshot", "pending": [] });
        let bytes = frame(&v);
        assert_eq!(u32::from_ne_bytes(bytes[..4].try_into().unwrap()) as usize, bytes.len() - 4);
        assert_eq!(read_message(&mut &bytes[..]).unwrap(), v);
        // Truncated or oversized input is refused, not waited on.
        assert!(read_message(&mut &bytes[..6]).is_none());
        let huge = ((MAX_BROWSER_MESSAGE + 1) as u32).to_ne_bytes();
        assert!(read_message(&mut &huge[..]).is_none());
    }

    #[test]
    fn long_strings_are_cut_on_a_char_boundary() {
        let mut v = serde_json::json!({ "tool_input": { "content": "é".repeat(4000) } });
        truncate_strings(&mut v);
        let s = v["tool_input"]["content"].as_str().unwrap();
        assert!(s.len() <= MAX_FIELD_LEN + 4);
        assert!(s.ends_with('…'));
    }
}
