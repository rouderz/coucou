// Mochi's inbox (macOS Inbox.swift): GitHub notifications you're part of and
// Linear notifications — review requests, mentions, assignments, comments.
// Polled every minute; what's new is announced once.

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::island::WINDOW_LABEL;
use crate::{integrations, linear, log, settings};

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct InboxItem {
    /// "github:<thread>" / "linear:<notification>"
    pub id: String,
    pub remote_id: String,
    pub source: String,
    /// review, mention, assigned, comment, other
    pub kind: String,
    pub title: String,
    /// "rouderz/coucou #80" / "SHO-123"
    pub subtitle: String,
    pub actor: Option<String>,
    pub url: String,
    /// ms since the epoch, for sorting
    pub date: f64,
}

#[derive(Default)]
pub struct Inbox {
    items: Mutex<Vec<InboxItem>>,
    announced: Mutex<HashSet<String>>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct InboxUpdate {
    items: Vec<InboxItem>,
    /// Newly arrived since the last poll (empty on the first one).
    fresh: Vec<InboxItem>,
}

pub fn github_kind(reason: &str) -> &'static str {
    match reason {
        "review_requested" => "review",
        "mention" | "team_mention" => "mention",
        "assign" => "assigned",
        "comment" | "author" => "comment",
        _ => "other",
    }
}

pub fn linear_kind(kind: &str) -> &'static str {
    let k = kind.to_lowercase();
    if k.contains("mention") {
        "mention"
    } else if k.contains("assigned") {
        "assigned"
    } else if k.contains("comment") {
        "comment"
    } else if k.contains("review") {
        "review"
    } else {
        "other"
    }
}

/// api.github.com/repos/o/r/pulls/80 → github.com/o/r/pull/80
pub fn github_web_url(api: &str) -> Option<String> {
    let rest = api.strip_prefix("https://api.github.com/repos/")?;
    Some(format!("https://github.com/{rest}").replace("/pulls/", "/pull/").replace("/commits/", "/commit/"))
}

/// ISO 8601 → ms since the epoch, good enough for sorting ("2026-10-02T09:05:07Z").
fn date_ms(s: &str) -> f64 {
    let n = |a: usize, b: usize| s.get(a..b).and_then(|x| x.parse::<i64>().ok()).unwrap_or(0);
    let (y, mo, d, h, mi, se) = (n(0, 4), n(5, 7), n(8, 10), n(11, 13), n(14, 16), n(17, 19));
    // Days from civil (Howard Hinnant).
    let y2 = if mo <= 2 { y - 1 } else { y };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    ((days * 86400 + h * 3600 + mi * 60 + se) * 1000) as f64
}

pub fn parse_github(list: &Value) -> Vec<InboxItem> {
    list.as_array()
        .map(|items| {
            items
                .iter()
                .filter(|n| n.get("unread").and_then(Value::as_bool) != Some(false))
                .filter_map(|n| {
                    let id = n.get("id")?.as_str()?.to_string();
                    let title = n.pointer("/subject/title")?.as_str()?.to_string();
                    let repo = n.pointer("/repository/full_name").and_then(Value::as_str).unwrap_or("");
                    let url = n
                        .pointer("/subject/url")
                        .and_then(Value::as_str)
                        .and_then(github_web_url)
                        .or_else(|| n.pointer("/repository/html_url").and_then(Value::as_str).map(str::to_string))
                        .unwrap_or_else(|| "https://github.com/notifications".into());
                    let number = url
                        .rsplit('/')
                        .next()
                        .and_then(|x| x.parse::<u64>().ok())
                        .map(|x| format!(" #{x}"))
                        .unwrap_or_default();
                    Some(InboxItem {
                        id: format!("github:{id}"),
                        remote_id: id,
                        source: "github".into(),
                        kind: github_kind(n.get("reason").and_then(Value::as_str).unwrap_or("")).into(),
                        title,
                        subtitle: format!("{repo}{number}"),
                        actor: None,
                        url,
                        date: date_ms(n.get("updated_at").and_then(Value::as_str).unwrap_or("")),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn parse_linear(data: &Value) -> Vec<InboxItem> {
    data.pointer("/notifications/nodes")
        .and_then(Value::as_array)
        .map(|nodes| {
            nodes
                .iter()
                .filter(|n| n.get("readAt").map(Value::is_null).unwrap_or(true))
                .filter_map(|n| {
                    let id = n.get("id")?.as_str()?.to_string();
                    let identifier = n.pointer("/issue/identifier")?.as_str()?.to_string();
                    Some(InboxItem {
                        id: format!("linear:{id}"),
                        remote_id: id,
                        source: "linear".into(),
                        kind: linear_kind(n.get("type").and_then(Value::as_str).unwrap_or("")).into(),
                        title: n.pointer("/issue/title").and_then(Value::as_str).unwrap_or(&identifier).to_string(),
                        subtitle: identifier,
                        actor: n.pointer("/actor/name").and_then(Value::as_str).map(str::to_string),
                        url: n.pointer("/issue/url").and_then(Value::as_str).unwrap_or("https://linear.app").to_string(),
                        date: date_ms(n.get("createdAt").and_then(Value::as_str).unwrap_or("")),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

async fn fetch_github() -> Option<Vec<InboxItem>> {
    let token = integrations::github_token().await?;
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .ok()?
        .get("https://api.github.com/notifications?participating=true&per_page=30")
        .header("Authorization", format!("Bearer {token}"))
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "Coucou")
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    Some(parse_github(&response.json::<Value>().await.ok()?))
}

async fn fetch_linear() -> Option<Vec<InboxItem>> {
    if !linear::has_key() {
        return Some(vec![]);
    }
    let q = "query { notifications(first: 30) { nodes { id type readAt createdAt actor { name } \
             ... on IssueNotification { issue { identifier title url } } } } }";
    let data = linear::query(q, json!({})).await.ok()?;
    Some(parse_linear(&data))
}

fn current_settings(app: &AppHandle) -> settings::Settings {
    app.state::<crate::Shared>().settings.lock().unwrap().clone()
}

/// One poll: merge both sources (a failed one keeps its previous items), filter
/// by the kinds chosen in Settings, and tell the island what's new.
pub async fn refresh(app: AppHandle) {
    let s = current_settings(&app);
    let inbox = app.state::<Inbox>();
    if !s.inbox_enabled || integrations::PAUSED.load(std::sync::atomic::Ordering::Relaxed) {
        return;
    }
    let previous = inbox.items.lock().unwrap().clone();
    let keep = |source: &str| previous.iter().filter(|i| i.source == source).cloned().collect::<Vec<_>>();
    let github = if s.inbox_github { fetch_github().await.unwrap_or_else(|| keep("github")) } else { vec![] };
    let linear_items = if s.inbox_linear { fetch_linear().await.unwrap_or_else(|| keep("linear")) } else { vec![] };
    let mut items: Vec<InboxItem> = github
        .into_iter()
        .chain(linear_items)
        .filter(|i| s.inbox_kinds.contains(&i.kind))
        .collect();
    items.sort_by(|a, b| b.date.partial_cmp(&a.date).unwrap_or(std::cmp::Ordering::Equal));

    let fresh = {
        let mut announced = inbox.announced.lock().unwrap();
        let first_run = announced.is_empty() && previous.is_empty();
        let fresh: Vec<InboxItem> = items.iter().filter(|i| !announced.contains(&i.id)).cloned().collect();
        announced.extend(items.iter().map(|i| i.id.clone()));
        // The first poll after launch fills the inbox without announcing old news.
        if first_run { vec![] } else { fresh }
    };
    *inbox.items.lock().unwrap() = items.clone();
    if !fresh.is_empty() {
        log::line(format!("inbox: {} new", fresh.len()));
    }
    let _ = app.emit_to(WINDOW_LABEL, "inbox", InboxUpdate { items, fresh });
}

pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(12)).await;
        let mut ticker = tokio::time::interval(Duration::from_secs(60));
        loop {
            ticker.tick().await;
            refresh(app.clone()).await;
        }
    });
}

/// Marks it read where it came from and drops it from the inbox.
pub async fn dismiss(app: AppHandle, id: String) {
    let item = {
        let inbox = app.state::<Inbox>();
        let mut items = inbox.items.lock().unwrap();
        let found = items.iter().find(|i| i.id == id).cloned();
        items.retain(|i| i.id != id);
        found
    };
    let Some(item) = item else { return };
    match item.source.as_str() {
        "github" => {
            if let Some(token) = integrations::github_token().await {
                let _ = reqwest::Client::new()
                    .patch(format!("https://api.github.com/notifications/threads/{}", item.remote_id))
                    .header("Authorization", format!("Bearer {token}"))
                    .header("Accept", "application/vnd.github+json")
                    .header("User-Agent", "Coucou")
                    .send()
                    .await;
            }
        }
        "linear" => {
            let now = chrono_now_iso();
            let _ = linear::query(
                "mutation($id: String!, $at: DateTime!) { notificationUpdate(id: $id, input: { readAt: $at }) { success } }",
                json!({ "id": item.remote_id, "at": now }),
            )
            .await;
        }
        _ => {}
    }
}

/// UTC now as ISO 8601, without a date library.
fn chrono_now_iso() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    // Civil from days (Howard Hinnant).
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn github_notifications() {
        let list = json!([
            { "id": "1", "unread": true, "reason": "review_requested", "updated_at": "2026-10-02T09:00:00Z",
              "subject": { "title": "Fix cart", "url": "https://api.github.com/repos/o/r/pulls/80" },
              "repository": { "full_name": "o/r" } },
            { "id": "2", "unread": false, "reason": "mention", "subject": { "title": "old" } }
        ]);
        let items = parse_github(&list);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].kind, "review");
        assert_eq!(items[0].url, "https://github.com/o/r/pull/80");
        assert_eq!(items[0].subtitle, "o/r #80");
    }

    #[test]
    fn linear_notifications() {
        let data = json!({ "notifications": { "nodes": [
            { "id": "a", "type": "issueAssignedToYou", "readAt": null, "createdAt": "2026-10-02T09:00:00Z",
              "actor": { "name": "Ana" }, "issue": { "identifier": "SHO-1", "title": "Cart", "url": "https://linear.app/x" } },
            { "id": "b", "type": "issueComment", "readAt": "2026-10-01T00:00:00Z", "issue": { "identifier": "SHO-2" } }
        ] } });
        let items = parse_linear(&data);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].kind, "assigned");
        assert_eq!(items[0].actor.as_deref(), Some("Ana"));
    }

    #[test]
    fn dates_sort_and_print() {
        assert!(date_ms("2026-10-02T09:00:01Z") > date_ms("2026-10-02T09:00:00Z"));
        assert_eq!(date_ms("1970-01-01T00:00:00Z"), 0.0);
        assert_eq!(chrono_now_iso().len(), 20);
    }
}
