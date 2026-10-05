// CI pill (#115): the GitHub calls behind windows/src/core/ciPoller.ts. The page decides
// what to fetch and when (core/ci.ts: pill state, events, adaptive interval); Rust adds the
// GitHub token (the saved one, else the GitHub CLI's, like the GitHub poller), keeps ETags,
// and refuses any request the CI pill doesn't make. Nothing goes out while the pill is off,
// and polls stop while Coucou is paused. Logs and re-runs only follow a click in the card.

use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use serde_json::Value;
use tauri::AppHandle;

use crate::{files, integrations};

pub const ID: &str = "integration_ci";
const API: &str = "https://api.github.com/";
/// Only the end of a job log matters ("Ask Mochi why" keeps ~150 lines of it).
const LOG_TAIL_BYTES: usize = 1_000_000;
const NOT_CONNECTED: &str = "Not connected to GitHub · sign in with gh or add a token in Settings";

/// path → (ETag, body): a 304 answer doesn't count against GitHub's rate limit.
static ETAGS: LazyLock<Mutex<HashMap<String, (String, Value)>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn client(secs: u64) -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(secs))
        .build()
        .unwrap_or_default()
}

fn segment_ok(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 100
        && s != "."
        && s != ".."
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
}

/// "owner/name" made of the characters GitHub allows.
pub fn repo_ok(repo: &str) -> bool {
    match repo.split_once('/') {
        Some((owner, name)) => segment_ok(owner) && segment_ok(name),
        None => false,
    }
}

/// The GETs the CI pill makes, and nothing else: the search for your open PRs
/// (core/ci.ts MY_OPEN_PRS_PATH), one PR, and a commit's check runs.
pub fn allowed_get(path: &str) -> bool {
    if let Some(q) = path.strip_prefix("search/issues?q=") {
        return q.starts_with("is%3Apr+is%3Aopen+author%3A%40me")
            && q.chars().all(|c| c.is_ascii_graphic() && c != '#');
    }
    let Some(rest) = path.strip_prefix("repos/") else {
        return false;
    };
    let parts: Vec<&str> = rest.splitn(4, '/').collect();
    if parts.len() != 4 || !segment_ok(parts[0]) || !segment_ok(parts[1]) {
        return false;
    }
    match parts[2] {
        "pulls" => {
            !parts[3].is_empty()
                && parts[3].len() <= 10
                && parts[3].chars().all(|c| c.is_ascii_digit())
        }
        "commits" => match parts[3].split_once('/') {
            Some((sha, "check-runs?per_page=100")) => {
                (7..=40).contains(&sha.len()) && sha.chars().all(|c| c.is_ascii_hexdigit())
            }
            _ => false,
        },
        _ => false,
    }
}

fn pill_on(app: &AppHandle) -> Result<(), String> {
    if integrations::enabled(app, ID) {
        Ok(())
    } else {
        Err("The CI pill is off".into())
    }
}

async fn token() -> Result<String, String> {
    integrations::github_token()
        .await
        .ok_or_else(|| NOT_CONNECTED.to_string())
}

fn github(builder: reqwest::RequestBuilder, token: &str) -> reqwest::RequestBuilder {
    builder
        .header("Authorization", format!("Bearer {token}"))
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "Coucou")
}

/// One poll request (see `allowed_get`), with ETags.
pub async fn get(app: &AppHandle, path: &str) -> Result<Value, String> {
    if !allowed_get(path) {
        return Err("Not a CI request".into());
    }
    if integrations::PAUSED.load(Ordering::Relaxed) {
        return Err("Coucou is paused".into());
    }
    pill_on(app)?;
    let token = token().await?;
    let cached = ETAGS.lock().unwrap().get(path).cloned();
    let mut request = github(client(15).get(format!("{API}{path}")), &token);
    if let Some((etag, _)) = &cached {
        request = request.header("If-None-Match", etag.as_str());
    }
    let response = request
        .send()
        .await
        .map_err(|_| "Can't reach GitHub".to_string())?;
    let code = response.status().as_u16();
    if code == 304 {
        if let Some((_, body)) = cached {
            return Ok(body);
        }
    }
    if !response.status().is_success() {
        return Err(match code {
            401 => "Token rejected · check it in Settings".into(),
            _ => format!("GitHub error {code}"),
        });
    }
    let etag = response
        .headers()
        .get("etag")
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    let body: Value = response
        .json()
        .await
        .map_err(|_| "Unexpected response from GitHub".to_string())?;
    if let Some(etag) = etag {
        let mut map = ETAGS.lock().unwrap();
        if map.len() > 300 {
            map.clear(); // old commits' check runs: start over rather than grow forever
        }
        map.insert(path.to_string(), (etag, body.clone()));
    }
    Ok(body)
}

/// The end of a failed Actions job's log ("Ask Mochi why", on a click). GitHub answers with
/// a redirect to short-lived storage; reqwest drops the Authorization header on the way.
pub async fn job_log(app: &AppHandle, repo: &str, job_id: u64) -> Result<String, String> {
    if !repo_ok(repo) {
        return Err("Couldn't fetch the job log".into());
    }
    pill_on(app)?;
    let token = token().await?;
    let url = format!("{API}repos/{repo}/actions/jobs/{job_id}/logs");
    let response = github(client(45).get(url), &token)
        .send()
        .await
        .map_err(|_| "Couldn't fetch the job log".to_string())?;
    if !response.status().is_success() {
        return Err("Couldn't fetch the job log".into());
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|_| "Couldn't fetch the job log".to_string())?;
    let start = bytes.len().saturating_sub(LOG_TAIL_BYTES);
    Ok(String::from_utf8_lossy(&bytes[start..]).into_owned())
}

/// POST …/rerun-failed-jobs for one workflow run. On an explicit click only.
pub async fn rerun_failed(app: &AppHandle, repo: &str, run_id: u64) -> Result<(), String> {
    if !repo_ok(repo) {
        return Err("Couldn't re-run the failed jobs".into());
    }
    pill_on(app)?;
    let token = token().await?;
    let url = format!("{API}repos/{repo}/actions/runs/{run_id}/rerun-failed-jobs");
    let response = github(client(15).post(url), &token)
        .send()
        .await
        .map_err(|_| "Can't reach GitHub".to_string())?;
    match response.status().as_u16() {
        200..=299 => {
            crate::log::line(format!("ci: re-run failed jobs of {repo} run {run_id}"));
            Ok(())
        }
        403 => {
            Err("GitHub refused the re-run (403) · the token needs the Actions permission".into())
        }
        _ => Err("Couldn't re-run the failed jobs".into()),
    }
}

/// The log tail (already trimmed by the page) as a text file in the inbox, to attach to the chat.
pub fn save_log(name: &str, text: &str) -> Result<files::DroppedFile, String> {
    crate::google::save_text(name, "txt", text.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_pills_requests() {
        assert!(allowed_get(
            "search/issues?q=is%3Apr+is%3Aopen+author%3A%40me+archived%3Afalse&sort=updated&order=desc&per_page=10"
        ));
        assert!(allowed_get("repos/rouderz/coucou/pulls/115"));
        assert!(allowed_get("repos/rouderz/coucou/commits/abcdef1234567890abcdef1234567890abcdef12/check-runs?per_page=100"));
        assert!(allowed_get(
            "repos/o.k/my_repo-1/commits/abc1234/check-runs?per_page=100"
        ));

        assert!(!allowed_get("search/issues?q=is%3Aissue"));
        assert!(!allowed_get("user/repos"));
        assert!(!allowed_get("repos/rouderz/coucou/pulls/115/merge"));
        assert!(!allowed_get("repos/rouderz/coucou/pulls/"));
        assert!(!allowed_get("repos/../coucou/pulls/1"));
        assert!(!allowed_get(
            "repos/rouderz/coucou/commits/main/check-runs?per_page=100"
        ));
        assert!(!allowed_get("repos/rouderz/coucou/commits/abc1234/status"));
        assert!(!allowed_get("repos/rouderz/coucou/actions/jobs/1/logs"));
        assert!(!allowed_get("repos/rouderz/coucou/contents/x"));
    }

    #[test]
    fn repo_names() {
        assert!(repo_ok("rouderz/coucou"));
        assert!(repo_ok("a-b/c.d_e"));
        assert!(!repo_ok("rouderz"));
        assert!(!repo_ok("rouderz/coucou/x"));
        assert!(!repo_ok("../coucou"));
        assert!(!repo_ok("o/r?x=1"));
        assert!(!repo_ok("/coucou"));
    }
}
