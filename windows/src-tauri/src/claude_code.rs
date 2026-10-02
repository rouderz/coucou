// Chat through the user's own Claude Code CLI, signed in with their Claude
// subscription, instead of the API with a key (#75, the macOS chat from #46).
//
// It only launches the official, unmodified `claude` binary in print mode and
// never reads, stores or forwards Claude credentials. Each conversation runs in
// its own folder with a tight tool set — web search, web fetch, and reading the
// files in that folder — so the chat never touches the user's own files beyond
// what they drop on the island.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

use crate::claude::{ChatContext, ChatReply, SYSTEM_PROMPT};
use crate::{log, platform, settings};

/// A whole answer, web searches included, never takes longer than this.
const TURN_TIMEOUT: Duration = Duration::from_secs(600);

const NOT_INSTALLED: &str =
    "Claude Code isn't installed. Install it, or switch the chat to an API key in Settings.";
const NOT_SIGNED_IN: &str = "Claude Code isn't signed in. Run `claude` in a terminal and sign in with /login.";
const OUTDATED: &str =
    "Your Claude Code is too old for this model. Run `claude update` (or pick another model in Settings), then ask again.";

#[derive(Default)]
pub struct ClaudeCodeChat {
    /// Claude Code's session, resumed on the next turn.
    session: Mutex<Option<String>>,
    /// The conversation's own folder (dropped files are copied into it).
    dir: Mutex<Option<PathBuf>>,
}

impl ClaudeCodeChat {
    pub fn reset(&self) {
        *self.session.lock().unwrap() = None;
        if let Some(dir) = self.dir.lock().unwrap().take() {
            let _ = std::fs::remove_dir_all(dir);
        }
    }

    fn folder(&self) -> Result<PathBuf, String> {
        let mut guard = self.dir.lock().unwrap();
        if let Some(dir) = guard.as_ref() {
            return Ok(dir.clone());
        }
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let dir = settings::local_dir().join("chats").join(format!("{stamp}"));
        std::fs::create_dir_all(&dir).map_err(|e| format!("Couldn't create the chat folder: {e}"))?;
        *guard = Some(dir.clone());
        Ok(dir)
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeCodeStatus {
    pub installed: bool,
    pub path: Option<String>,
}

/// `claude` on PATH, or where its installers put it (an app started from the
/// desktop doesn't always get the shell's PATH).
pub fn locate() -> Option<PathBuf> {
    platform::find_program("claude")
        .or_else(|| platform::claude_fallbacks().into_iter().find(|p| p.is_file()))
}

pub fn status() -> ClaudeCodeStatus {
    let path = locate();
    ClaudeCodeStatus { installed: path.is_some(), path: path.map(|p| p.display().to_string()) }
}

/// The arguments for one turn: print mode, streamed JSON, the chat's tools only.
pub fn arguments(model: &str, session: Option<&str>) -> Vec<String> {
    let mut args: Vec<String> = [
        "-p",
        "--output-format", "stream-json", "--verbose",
        "--model", model,
        "--tools", "WebSearch,WebFetch,Read",
        "--allowedTools", "WebSearch,WebFetch",
        "--disallowedTools", "Edit,MultiEdit,Write,NotebookEdit,Bash",
        "--permission-mode", "dontAsk",
        "--strict-mcp-config",
        "--append-system-prompt", SYSTEM_PROMPT,
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    if let Some(id) = session {
        args.push("--resume".into());
        args.push(id.into());
    }
    args
}

/// What the stream told us.
#[derive(Default, Debug)]
pub struct Outcome {
    pub session: Option<String>,
    pub result: Option<String>,
    pub is_error: bool,
    pub auth_problem: bool,
}

impl Outcome {
    /// Reads one line of `--output-format stream-json`.
    pub fn read(&mut self, line: &str) {
        let Ok(obj) = serde_json::from_str::<Value>(line) else { return };
        let kind = obj.get("type").and_then(Value::as_str).unwrap_or_default();
        if let Some(id) = obj.get("session_id").and_then(Value::as_str) {
            self.session = Some(id.to_string());
        }
        match kind {
            "system" => {
                let retry = obj.get("subtype").and_then(Value::as_str) == Some("api_retry");
                let err = obj.get("error").and_then(Value::as_str).unwrap_or_default();
                if retry && matches!(err, "authentication_failed" | "oauth_org_not_allowed") {
                    self.auth_problem = true;
                }
            }
            "result" => {
                self.result = obj.get("result").and_then(Value::as_str).map(str::to_string);
                self.is_error = obj.get("is_error").and_then(Value::as_bool).unwrap_or(false);
            }
            _ => {}
        }
    }
}

/// A failed run in words the user can act on.
pub fn describe_failure(message: &str) -> String {
    let lower = message.to_lowercase();
    if lower.contains("claude update") || lower.contains("or newer is required") {
        return OUTDATED.into();
    }
    if lower.contains("not logged in") || lower.contains("/login") || lower.contains("please log in") {
        return NOT_SIGNED_IN.into();
    }
    let tail: String = message.chars().rev().take(400).collect::<Vec<_>>().into_iter().rev().collect();
    tail
}

/// The window or file the question is about. Files are copied into the
/// conversation folder so the Read tool can open them.
fn preamble(context: &ChatContext, dir: &Path) -> String {
    match context {
        ChatContext::Window { app_name, title, url } => {
            let mut text = format!("Context — App: {app_name}, Window: {title}");
            if let Some(url) = url {
                text.push_str(&format!(", URL: {url}"));
            }
            text + "\n\n"
        }
        ChatContext::File { name, path } => {
            let source = Path::new(path);
            let Some(file_name) = source.file_name() else { return format!("File: {name}\n\n") };
            let dest = dir.join(file_name);
            match std::fs::copy(source, &dest) {
                Ok(_) => format!(
                    "The user attached the file ./{}. Read it with the Read tool before answering.\n\n",
                    file_name.to_string_lossy()
                ),
                Err(_) => format!("File: {name} (it could not be copied, so it can't be read)\n\n"),
            }
        }
    }
}

/// One chat turn through Claude Code.
pub async fn send(
    chat: &ClaudeCodeChat,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let program = locate().ok_or_else(|| NOT_INSTALLED.to_string())?;
    let session = chat.session.lock().unwrap().clone();
    let dir = chat.folder()?;

    let mut prompt = String::new();
    if session.is_none() {
        if let Some(ctx) = &context {
            prompt.push_str(&preamble(ctx, &dir));
        }
    }
    prompt.push_str(&query);

    let mut cmd = tokio::process::Command::new(&program);
    cmd.args(arguments(model, session.as_deref()))
        .current_dir(&dir)
        // Coucou's own relay ignores this session: it is the chat, not your work.
        .env("COUCOU_INTERNAL", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    platform::hide_console_async(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| format!("Couldn't start Claude Code: {e}"))?;

    // The question goes through stdin so one starting with "-" is never read as a flag.
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(prompt.as_bytes()).await;
    }
    let mut stderr = child.stderr.take();
    let errors = tauri::async_runtime::spawn(async move {
        let mut text = String::new();
        if let Some(err) = stderr.as_mut() {
            let _ = err.read_to_string(&mut text).await;
        }
        text
    });

    let mut outcome = Outcome::default();
    let stdout = child.stdout.take().ok_or("Claude Code has no output")?;
    let mut lines = BufReader::new(stdout).lines();
    let reading = async {
        while let Ok(Some(line)) = lines.next_line().await {
            outcome.read(&line);
            if outcome.auth_problem {
                break;
            }
        }
    };
    if tokio::time::timeout(TURN_TIMEOUT, reading).await.is_err() {
        let _ = child.start_kill();
        return Err("Claude Code took too long to answer. Try again, or ask for something shorter.".into());
    }
    if outcome.auth_problem {
        let _ = child.start_kill();
    }
    let status = child.wait().await.ok();
    let stderr_text = errors.await.unwrap_or_default();

    if let Some(id) = outcome.session.clone() {
        *chat.session.lock().unwrap() = Some(id);
    }
    if outcome.auth_problem {
        return Err(NOT_SIGNED_IN.into());
    }
    match outcome.result {
        Some(text) if !outcome.is_error && !text.trim().is_empty() => {
            Ok(ChatReply { text: text.trim().to_string() })
        }
        other => {
            let message = [other.unwrap_or_default(), stderr_text.trim().to_string()]
                .into_iter()
                .find(|m| !m.is_empty())
                .unwrap_or_else(|| {
                    format!("Claude Code exited with code {}.", status.and_then(|s| s.code()).unwrap_or(-1))
                });
            log::line(format!("claude code failed: {}", message.chars().take(200).collect::<String>()));
            Err(describe_failure(&message))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_session_and_the_answer() {
        let mut o = Outcome::default();
        o.read(r#"{"type":"system","subtype":"init","session_id":"abc"}"#);
        o.read(r#"{"type":"assistant","message":{}}"#);
        o.read(r#"{"type":"result","subtype":"success","is_error":false,"result":"Hi!","session_id":"abc"}"#);
        assert_eq!(o.session.as_deref(), Some("abc"));
        assert_eq!(o.result.as_deref(), Some("Hi!"));
        assert!(!o.is_error);
    }

    #[test]
    fn spots_a_sign_in_problem() {
        let mut o = Outcome::default();
        o.read(r#"{"type":"system","subtype":"api_retry","error":"authentication_failed"}"#);
        assert!(o.auth_problem);
        o.read("not json at all");
    }

    #[test]
    fn failures_in_plain_words() {
        assert_eq!(describe_failure("Invalid API key · Please run /login"), NOT_SIGNED_IN);
        assert_eq!(describe_failure("Claude Code 2.1 or newer is required"), OUTDATED);
        assert_eq!(describe_failure("boom"), "boom");
    }

    #[test]
    fn the_chat_cannot_touch_files_or_run_commands() {
        let args = arguments("claude-opus-5-5", Some("s1"));
        let tools = args.iter().position(|a| a == "--tools").map(|i| &args[i + 1]).unwrap();
        assert_eq!(tools, "WebSearch,WebFetch,Read");
        assert!(args.iter().any(|a| a.contains("Bash")), "Bash is explicitly disallowed");
        assert_eq!(args[args.len() - 2..], ["--resume".to_string(), "s1".to_string()]);
    }
}
