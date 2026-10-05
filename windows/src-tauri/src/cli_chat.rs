// Chat engines that run another agent CLI the user is signed in to (#108): Codex
// (ChatGPT plan) and Gemini CLI. This only finds and runs the official binary; the
// page builds the conversation and reads the output (src/claude/chatEngines.ts).
//
// Like the Claude Code engine it never reads the CLI's credentials, runs in an empty
// folder of Coucou's own (never a project), and sets COUCOU_INTERNAL=1 so the chat's
// hooks never reach the island. Codex runs in its read-only sandbox; Gemini keeps its
// default approval mode (no edit-capable mode is asked for).
//
// The prompt always goes through stdin: on Windows the CLIs are npm `.cmd` shims, and a
// multi-line prompt can't be passed safely as a batch-file argument.
//   codex exec … -          ("-" = read the instructions from stdin)
//   gemini -p "…"           (-p is appended to what stdin carries)

use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use serde::Serialize;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::platform;

const TURN_TIMEOUT: Duration = Duration::from_secs(240);
/// The page never sends more than this (it trims old turns first).
const MAX_PROMPT: usize = 200_000;

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Engine {
    Codex,
    Gemini,
}

impl Engine {
    pub fn parse(id: &str) -> Option<Engine> {
        match id {
            "codex" => Some(Engine::Codex),
            "gemini" => Some(Engine::Gemini),
            _ => None,
        }
    }

    fn binary(self) -> &'static str {
        match self {
            Engine::Codex => "codex",
            Engine::Gemini => "gemini",
        }
    }
}

/// Arguments for one turn; the prompt itself goes on stdin.
pub fn arguments(engine: Engine, model: &str) -> Vec<String> {
    let model = model.trim();
    let mut args: Vec<String> = match engine {
        Engine::Codex => ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only"]
            .iter()
            .map(|s| s.to_string())
            .collect(),
        Engine::Gemini => vec!["--output-format".into(), "stream-json".into()],
    };
    if !model.is_empty() {
        args.push("--model".into());
        args.push(model.to_string());
    }
    match engine {
        Engine::Codex => args.push("-".into()),
        Engine::Gemini => {
            args.push("--prompt".into());
            args.push("Reply to the last user message above.".into());
        }
    }
    args
}

/// PATH first, then the folders the installers usually use.
pub fn locate(engine: Engine) -> Option<PathBuf> {
    if let Some(p) = platform::find_program(engine.binary()) {
        return Some(p);
    }
    let home = platform::home();
    let dirs: Vec<PathBuf> = if cfg!(windows) {
        ["AppData/Roaming/npm", "scoop/shims", ".bun/bin", ".volta/bin", ".local/bin"]
            .iter()
            .map(|d| home.join(d))
            .collect()
    } else {
        let mut v: Vec<PathBuf> = ["/usr/local/bin", "/usr/bin", "/home/linuxbrew/.linuxbrew/bin"]
            .iter()
            .map(PathBuf::from)
            .collect();
        v.extend([".local/bin", ".npm-global/bin", ".bun/bin", ".volta/bin"].iter().map(|d| home.join(d)));
        v
    };
    let names: Vec<String> = if cfg!(windows) {
        vec![format!("{}.cmd", engine.binary()), format!("{}.exe", engine.binary())]
    } else {
        vec![engine.binary().to_string()]
    };
    dirs.iter().flat_map(|d| names.iter().map(move |n| d.join(n))).find(|p| p.is_file())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliStatus {
    pub path: Option<String>,
    /// Codex only (`codex login status`); None when unknown.
    pub signed_in: Option<bool>,
}

pub async fn status(engine: Engine) -> CliStatus {
    let Some(path) = locate(engine) else { return CliStatus { path: None, signed_in: None } };
    let signed_in = if engine == Engine::Codex {
        let mut cmd = tokio::process::Command::new(&path);
        cmd.args(["login", "status"])
            .env("COUCOU_INTERNAL", "1")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        platform::hide_console_async(&mut cmd);
        match tokio::time::timeout(Duration::from_secs(8), cmd.output()).await {
            Ok(Ok(out)) => {
                let text = String::from_utf8_lossy(&out.stderr).to_lowercase() + &String::from_utf8_lossy(&out.stdout).to_lowercase();
                Some(out.status.success() && !text.contains("not logged in"))
            }
            _ => None,
        }
    } else {
        None
    };
    CliStatus { path: Some(path.to_string_lossy().to_string()), signed_in }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliRun {
    /// None when the binary couldn't be started (not installed).
    pub exit_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

/// An empty folder of our own for the CLI to run in.
fn folder(engine: Engine) -> Result<PathBuf, String> {
    let dir = crate::settings::local_dir().join("chats").join(format!("cli-{}", engine.binary()));
    std::fs::create_dir_all(&dir).map_err(|e| format!("Couldn't create the chat folder: {e}"))?;
    Ok(dir)
}

/// One turn: Mochi's instructions + the conversation on stdin, the CLI's output back.
pub async fn run(engine: Engine, conversation: &str, model: &str) -> Result<CliRun, String> {
    if conversation.len() > MAX_PROMPT {
        return Err("The conversation is too long for this engine. Start a new chat.".into());
    }
    let Some(program) = locate(engine) else {
        return Ok(CliRun { exit_code: None, stdout: String::new(), stderr: String::new() });
    };
    let prompt = format!("{}\n\n{}", crate::claude::SYSTEM_PROMPT, conversation);
    let mut cmd = tokio::process::Command::new(&program);
    cmd.args(arguments(engine, model))
        .current_dir(folder(engine)?)
        .env("COUCOU_INTERNAL", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    platform::hide_console_async(&mut cmd);
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(_) => return Ok(CliRun { exit_code: None, stdout: String::new(), stderr: String::new() }),
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(prompt.as_bytes()).await;
        // Dropping stdin closes it: the CLI starts once it has read everything.
    }
    let mut out = child.stdout.take();
    let mut err = child.stderr.take();
    let reading = async {
        // Both pipes at once, so a full stderr can't stall the CLI while we wait on stdout.
        let read_out = async {
            let mut s = String::new();
            if let Some(o) = out.as_mut() {
                let _ = o.read_to_string(&mut s).await;
            }
            s
        };
        let read_err = async {
            let mut s = String::new();
            if let Some(e) = err.as_mut() {
                let _ = e.read_to_string(&mut s).await;
            }
            s
        };
        let (stdout, stderr) = tokio::join!(read_out, read_err);
        let status = child.wait().await.ok();
        (stdout, stderr, status)
    };
    match tokio::time::timeout(TURN_TIMEOUT, reading).await {
        Ok((stdout, stderr, status)) => Ok(CliRun {
            exit_code: Some(status.and_then(|s| s.code()).unwrap_or(-1)),
            stdout,
            stderr: stderr.chars().rev().take(4000).collect::<Vec<_>>().into_iter().rev().collect(),
        }),
        Err(_) => Err("The answer took too long. Try again, or ask for something shorter.".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_reads_the_prompt_from_stdin_in_its_read_only_sandbox() {
        let a = arguments(Engine::Codex, "");
        assert_eq!(a, ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", "-"]);
        let a = arguments(Engine::Codex, " gpt-5-codex ");
        assert_eq!(&a[5..], ["--model", "gpt-5-codex", "-"]);
    }

    #[test]
    fn gemini_streams_json_and_never_asks_for_an_edit_mode() {
        let a = arguments(Engine::Gemini, "");
        assert_eq!(&a[..2], ["--output-format", "stream-json"]);
        assert!(a.iter().any(|x| x == "--prompt"));
        assert!(!a.iter().any(|x| x.contains("yolo") || x.contains("approval")));
    }

    #[test]
    fn only_known_engines() {
        assert_eq!(Engine::parse("codex"), Some(Engine::Codex));
        assert_eq!(Engine::parse("gemini"), Some(Engine::Gemini));
        assert_eq!(Engine::parse("rm -rf"), None);
    }
}
