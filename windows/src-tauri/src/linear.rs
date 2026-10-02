// Linear (#26, #27 on macOS): your open issues on a card, the issue a session's
// git branch names ("wolfgang/sho-123-fix-cart" → SHO-123), and posting a
// session's timeline as a comment on it. A personal API key, in the keychain.

use std::time::Duration;

use serde::Serialize;
use serde_json::{json, Value};

use crate::{platform, secrets};

const ENDPOINT: &str = "https://api.linear.app/graphql";
const ISSUE_FIELDS: &str = "id identifier title url priority branchName updatedAt state { name type color }";

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LinearIssue {
    pub id: String,
    pub identifier: String,
    pub title: String,
    pub url: String,
    pub state_name: String,
    pub state_type: String,
    pub state_color: String,
    pub priority: i64,
}

impl LinearIssue {
    pub fn from_node(node: &Value) -> Option<Self> {
        let s = |k: &str| node.get(k).and_then(Value::as_str).map(str::to_string);
        let state = node.get("state");
        let st = |k: &str| state.and_then(|x| x.get(k)).and_then(Value::as_str).unwrap_or("").to_string();
        Some(Self {
            id: s("id")?,
            identifier: s("identifier")?,
            title: s("title")?,
            url: s("url").unwrap_or_else(|| "https://linear.app".into()),
            state_name: st("name"),
            state_type: st("type"),
            state_color: {
                let c = st("color");
                if c.is_empty() { "#8E939C".into() } else { c }
            },
            priority: node.get("priority").and_then(Value::as_i64).unwrap_or(0),
        })
    }
}

pub fn has_key() -> bool {
    secrets::get("linear-api-key").is_some()
}

pub async fn query(query: &str, variables: Value) -> Result<Value, String> {
    let key = secrets::get("linear-api-key").ok_or("Add your Linear API key in Settings")?;
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|e| e.to_string())?
        .post(ENDPOINT)
        .header("Authorization", key)
        .header("Content-Type", "application/json")
        .json(&json!({ "query": query, "variables": variables }))
        .send()
        .await
        .map_err(|_| "Can't reach Linear".to_string())?;
    let code = response.status().as_u16();
    let body: Value = response.json().await.unwrap_or(json!({}));
    if code == 400 || code == 401 {
        return Err("Invalid API key (401)".into());
    }
    if let Some(msg) = body.pointer("/errors/0/message").and_then(Value::as_str) {
        return Err(msg.to_string());
    }
    if code != 200 {
        return Err(format!("Linear error {code}"));
    }
    Ok(body.get("data").cloned().unwrap_or(json!({})))
}

/// Your open issues, most recently updated first.
pub async fn assigned_issues() -> Result<Vec<LinearIssue>, String> {
    let q = format!(
        "query {{ viewer {{ assignedIssues(first: 25, orderBy: updatedAt, \
         filter: {{ state: {{ type: {{ nin: [\"completed\", \"canceled\"] }} }} }}) {{ nodes {{ {ISSUE_FIELDS} }} }} }} }}"
    );
    let data = query(&q, json!({})).await?;
    Ok(data
        .pointer("/viewer/assignedIssues/nodes")
        .and_then(Value::as_array)
        .map(|nodes| nodes.iter().filter_map(LinearIssue::from_node).collect())
        .unwrap_or_default())
}

pub async fn issue(identifier: &str) -> Option<LinearIssue> {
    let q = format!("query($id: String!) {{ issue(id: $id) {{ {ISSUE_FIELDS} }} }}");
    let data = query(&q, json!({ "id": identifier })).await.ok()?;
    data.get("issue").and_then(LinearIssue::from_node)
}

/// "wolfgang/sho-123-fix-cart" → "SHO-123".
pub fn identifier_in(branch: &str) -> Option<String> {
    let lower = branch.to_lowercase();
    let bytes = lower.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        // Start of a word: letters, a dash, digits.
        if bytes[i].is_ascii_alphabetic() && (i == 0 || !bytes[i - 1].is_ascii_alphanumeric()) {
            let start = i;
            while i < bytes.len() && bytes[i].is_ascii_alphabetic() {
                i += 1;
            }
            let letters = i - start;
            if (2..=6).contains(&letters) && i < bytes.len() && bytes[i] == b'-' {
                let digits_start = i + 1;
                let mut j = digits_start;
                while j < bytes.len() && bytes[j].is_ascii_digit() {
                    j += 1;
                }
                let ends = j == bytes.len() || !bytes[j].is_ascii_alphanumeric();
                if j > digits_start && ends {
                    return Some(format!("{}-{}", lower[start..i].to_uppercase(), &lower[digits_start..j]));
                }
            }
        } else {
            i += 1;
        }
    }
    None
}

/// The git branch checked out in `cwd`, without a shell.
pub async fn git_branch(cwd: &str) -> Option<String> {
    let git = platform::find_program("git")?;
    let mut cmd = tokio::process::Command::new(git);
    cmd.args(["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    platform::hide_console_async(&mut cmd);
    let out = tokio::time::timeout(Duration::from_secs(3), cmd.output()).await.ok()?.ok()?;
    let branch = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !branch.is_empty() && branch != "HEAD").then_some(branch)
}

/// The issue named by the session folder's branch, if Linear knows it.
pub async fn issue_for_folder(cwd: &str) -> Option<LinearIssue> {
    if !has_key() || cwd.is_empty() {
        return None;
    }
    let id = identifier_in(&git_branch(cwd).await?)?;
    issue(&id).await
}

/// Posts Markdown as a comment on the issue (a session's timeline).
pub async fn comment(issue_id: &str, body: &str) -> Result<(), String> {
    let q = "mutation($issueId: String!, $body: String!) { commentCreate(input: { issueId: $issueId, body: $body }) { success } }";
    let data = query(q, json!({ "issueId": issue_id, "body": body })).await?;
    if data.pointer("/commentCreate/success").and_then(Value::as_bool) == Some(true) {
        Ok(())
    } else {
        Err("Linear didn't accept the comment".into())
    }
}

#[cfg(test)]
mod tests {
    use super::identifier_in;

    #[test]
    fn finds_the_issue_in_a_branch_name() {
        assert_eq!(identifier_in("wolfgang/sho-123-fix-cart").as_deref(), Some("SHO-123"));
        assert_eq!(identifier_in("ENG-42").as_deref(), Some("ENG-42"));
        assert_eq!(identifier_in("feature/eng-7").as_deref(), Some("ENG-7"));
        assert_eq!(identifier_in("main"), None);
        assert_eq!(identifier_in("release-2026"), None, "too long a prefix");
        assert_eq!(identifier_in("v2-0-1"), None);
    }
}
