// WhaTicket (whaticket.com) through the browser: the "Coucou for WhaTicket" extension
// (extensions/whaticket) reads your queue in your whaticket.com tab, with your own
// session and permissions, and sends a summary here every ~15 s through native
// messaging (coucou-hook → the pipe / socket → `handle_browser`). Our answer carries
// the tickets to accept: one you clicked Accept on, or one auto-accept picked. The
// extension then sends the same POST /tickets/{id}/assign the web app's Accept
// button does, and tells us how it went.
//
// Coucou holds no WhaTicket credentials and makes no WhaTicket requests of its own.
// With the tab closed, the card says so and nothing happens.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};
use tauri::{AppHandle, Manager};

use crate::integrations::{emit, IntegrationEvent, IntegrationUpdate};
use crate::{log, platform};

pub const ID: &str = "integration_whaticket";
pub const WEB: &str = "https://app.whaticket.com";
/// How often the extension checks in.
const INTERVAL: u64 = 15;
/// A click waits at most this long for the extension to pick it up.
const QUEUED_FOR: Duration = Duration::from_secs(90);
/// No check-in for this long: the tab was closed or asleep. What arrives meanwhile
/// is backlog, not news — the next snapshot starts over, silently.
const STALE_AFTER: Duration = Duration::from_secs(60);

#[derive(Default)]
struct Bridge {
    /// Pending ticket ids seen so far (None until the first snapshot, which is silent).
    seen: Option<HashSet<String>>,
    /// My open tickets: id → unread count, to notice new messages.
    unread: HashMap<String, i64>,
    mine_ready: bool,
    /// Tickets to accept, waiting for the extension's next check-in.
    queued: Vec<(String, Instant)>,
    /// Sent to the extension, waiting for its result.
    in_flight: HashMap<String, Instant>,
    /// Names of the tickets we know, for "Accepted · María".
    names: HashMap<String, String>,
    /// Picked by auto-accept rather than clicked.
    auto: HashSet<String>,
    last: Option<Value>,
    /// When the extension last sent a snapshot.
    checked_in: Option<Instant>,
}

impl Bridge {
    /// Forget what we've seen, so the next snapshot only fills the card: no alerts
    /// and no auto-accept for a backlog that piled up while we weren't watching.
    fn start_over(&mut self) {
        self.seen = None;
        self.unread.clear();
        self.mine_ready = false;
    }
}

static BRIDGE: std::sync::LazyLock<Mutex<Bridge>> = std::sync::LazyLock::new(|| Mutex::new(Bridge::default()));

// ── Pure helpers (tested below) ───────────────────────────────────────────────

/// "09:00-18:00" (or "22:00-06:00" across midnight); empty or unreadable = any time.
pub fn in_hours(spec: &str, minutes_now: u32) -> bool {
    let spec = spec.trim();
    if spec.is_empty() {
        return true;
    }
    let parse = |s: &str| -> Option<u32> {
        let (h, m) = s.trim().split_once(':')?;
        let (h, m): (u32, u32) = (h.parse().ok()?, m.parse().ok()?);
        (h <= 24 && m < 60).then_some(h * 60 + m)
    };
    let Some((a, b)) = spec.split_once('-') else { return true };
    let (Some(from), Some(to)) = (parse(a), parse(b)) else { return true };
    if from <= to {
        minutes_now >= from && minutes_now < to
    } else {
        minutes_now >= from || minutes_now < to
    }
}

/// `queues` empty = any of my queues (and tickets with no queue).
pub fn queue_allowed(queue: Option<&str>, queues: &[String]) -> bool {
    queues.is_empty() || queue.map(|q| queues.iter().any(|x| x == q)).unwrap_or(false)
}

/// Ticket ids are UUIDs (or numbers); nothing else goes back to the browser.
pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// The tickets of a snapshot, keeping only well-formed ones and the fields the card uses.
pub fn tickets(msg: &Value, key: &str) -> Vec<Value> {
    msg.get(key)
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter(|t| t.get("id").and_then(Value::as_str).map(valid_id).unwrap_or(false))
                .take(200)
                .map(|t| {
                    let s = |k: &str| t.get(k).and_then(Value::as_str).unwrap_or("").chars().take(300).collect::<String>();
                    json!({
                        "id": s("id"),
                        "name": s("name"),
                        "lastMessage": s("lastMessage"),
                        "unread": t.get("unread").and_then(Value::as_i64).unwrap_or(0),
                        "queueId": t.get("queueId").and_then(Value::as_str),
                        "queue": s("queue"),
                        "queueColor": s("queueColor"),
                        "updatedAt": s("updatedAt"),
                        "isGroup": t.get("isGroup").and_then(Value::as_bool).unwrap_or(false),
                        "aiHandling": t.get("aiHandling").and_then(Value::as_bool).unwrap_or(false),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The snapshot's queues, keeping only `{id, name, color}` strings.
pub fn queue_list(msg: &Value) -> Value {
    let s = |q: &Value, k: &str| q.get(k).and_then(Value::as_str).unwrap_or("").chars().take(80).collect::<String>();
    let list: Vec<Value> = msg
        .get("queues")
        .and_then(Value::as_array)
        .map(|l| {
            l.iter()
                .filter(|q| q.get("id").and_then(Value::as_str).map(valid_id).unwrap_or(false))
                .take(100)
                .map(|q| json!({ "id": s(q, "id"), "name": s(q, "name"), "color": s(q, "color") }))
                .collect()
        })
        .unwrap_or_default();
    Value::Array(list)
}

/// What the card says when the extension reports a problem.
pub fn error_text(code: &str) -> String {
    match code {
        "signed_out" => "Sign in to whaticket.com in Chrome or Edge.".into(),
        "session" => "whaticket.com's session expired: use the tab once (or sign in again).".into(),
        other => other.chars().take(200).collect(),
    }
}

// ── The extension's messages ──────────────────────────────────────────────────

struct Rules {
    enabled: bool,
    auto_accept: bool,
    queues: Vec<String>,
    hours: String,
    dnd: bool,
}

fn rules(app: &AppHandle) -> Rules {
    app.try_state::<crate::Shared>()
        .map(|shared| {
            let s = shared.settings.lock().unwrap();
            let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as f64).unwrap_or(0.0);
            Rules {
                enabled: s.active_integrations.iter().any(|x| x == ID),
                auto_accept: s.whaticket_auto_accept,
                queues: s.whaticket_queues.clone(),
                hours: s.whaticket_hours.clone(),
                dnd: s.dnd_until.map(|u| u > now).unwrap_or(false),
            }
        })
        .unwrap_or(Rules { enabled: false, auto_accept: false, queues: vec![], hours: String::new(), dnd: false })
}

fn minutes_now() -> u32 {
    let (_, _, _, h, mi, _) = platform::local_time();
    h as u32 * 60 + mi as u32
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// One message from the extension (via coucou-hook); returns the reply line's JSON.
pub fn handle_browser(app: &AppHandle, msg: &Value) -> Value {
    let rules = rules(app);
    if !rules.enabled || crate::integrations::PAUSED.load(std::sync::atomic::Ordering::Relaxed) {
        // Pill off or Coucou paused: not watching WhaTicket. Check in rarely.
        BRIDGE.lock().unwrap().start_over();
        return json!({ "commands": [], "interval": 60 });
    }
    match msg.get("kind").and_then(Value::as_str).unwrap_or("") {
        "snapshot" => snapshot(app, msg, &rules),
        "results" => results(app, msg),
        _ => json!({ "commands": [], "interval": INTERVAL }),
    }
}

fn snapshot(app: &AppHandle, msg: &Value, rules: &Rules) -> Value {
    if let Some(code) = msg.get("error").and_then(Value::as_str) {
        emit(app, IntegrationUpdate { id: ID, data: json!({}), error: Some(error_text(code)), event: None });
        return json!({ "commands": [], "interval": INTERVAL });
    }
    let pending = tickets(msg, "pending");
    let mine = tickets(msg, "mine");
    let mut event: Option<IntegrationEvent> = None;

    let mut b = BRIDGE.lock().unwrap();
    if b.checked_in.map(|at| at.elapsed() > STALE_AFTER).unwrap_or(true) {
        b.start_over();
    }
    b.checked_in = Some(Instant::now());
    for t in pending.iter().chain(mine.iter()) {
        b.names.insert(t["id"].as_str().unwrap_or_default().to_string(), t["name"].as_str().unwrap_or("").to_string());
    }

    // New tickets in the queue (the first snapshot only fills the card).
    let ids: HashSet<String> = pending.iter().filter_map(|t| t["id"].as_str().map(str::to_string)).collect();
    let fresh: Vec<&Value> = match &b.seen {
        None => Vec::new(),
        Some(seen) => pending.iter().filter(|t| !seen.contains(t["id"].as_str().unwrap_or_default())).collect(),
    };
    b.seen = Some(ids);
    for t in fresh {
        let id = t["id"].as_str().unwrap_or_default().to_string();
        let can = rules.auto_accept
            && !rules.dnd
            && !t["isGroup"].as_bool().unwrap_or(false)
            && !t["aiHandling"].as_bool().unwrap_or(false)
            && queue_allowed(t["queueId"].as_str(), &rules.queues)
            && in_hours(&rules.hours, minutes_now());
        if can && !b.in_flight.contains_key(&id) && !b.queued.iter().any(|(q, _)| *q == id) {
            b.queued.push((id.clone(), Instant::now()));
            b.auto.insert(id);
            continue; // announced once the extension confirms it
        }
        event = Some(IntegrationEvent {
            success: true,
            label: format!("New ticket · {}", t["name"].as_str().unwrap_or("?")),
            detail: t["lastMessage"].as_str().filter(|s| !s.is_empty()).map(str::to_string),
        });
    }

    // New messages on my tickets (a ticket that just became mine isn't news).
    let first = !b.mine_ready;
    b.mine_ready = true;
    let mut next = HashMap::new();
    for t in &mine {
        let id = t["id"].as_str().unwrap_or_default().to_string();
        let unread = t["unread"].as_i64().unwrap_or(0);
        if event.is_none() && !first && b.unread.get(&id).map(|before| unread > *before).unwrap_or(false) {
            event = Some(IntegrationEvent {
                success: true,
                label: format!("Message · {}", t["name"].as_str().unwrap_or("?")),
                detail: t["lastMessage"].as_str().filter(|s| !s.is_empty()).map(str::to_string),
            });
        }
        next.insert(id, unread);
    }
    b.unread = next;

    let data = json!({
        "user": msg.pointer("/user/name").and_then(Value::as_str).unwrap_or(""),
        "queues": queue_list(msg),
        "pending": pending.iter().take(8).cloned().collect::<Vec<_>>(),
        "pendingCount": pending.len(),
        "mine": mine.iter().take(8).cloned().collect::<Vec<_>>(),
        "mineCount": mine.len(),
        "autoAccept": rules.auto_accept,
        "seenAt": now_ms(),
    });
    b.last = Some(data.clone());
    let reply = take_commands(&mut b);
    let accepting = accepting(&b);
    drop(b);
    let mut data = data;
    data["accepting"] = accepting;
    emit(app, IntegrationUpdate { id: ID, data, error: None, event });
    reply
}

fn results(app: &AppHandle, msg: &Value) -> Value {
    let mut b = BRIDGE.lock().unwrap();
    let mut event = None;
    for r in msg.get("results").and_then(Value::as_array).cloned().unwrap_or_default() {
        let id = r.get("id").and_then(Value::as_str).unwrap_or_default().to_string();
        b.in_flight.remove(&id);
        let auto = b.auto.remove(&id);
        let name = b.names.get(&id).cloned().unwrap_or_else(|| "?".into());
        if r.get("ok").and_then(Value::as_bool).unwrap_or(false) {
            log::line(format!("whaticket: {} ticket {id}", if auto { "auto-accepted" } else { "accepted" }));
            event = Some(IntegrationEvent { success: true, label: format!("Accepted · {name}"), detail: None });
        } else {
            let why = error_text(r.get("error").and_then(Value::as_str).unwrap_or(""));
            log::line(format!("whaticket: accepting {id} failed: {why}"));
            event = Some(IntegrationEvent { success: false, label: format!("Couldn't accept · {name}"), detail: Some(why) });
        }
    }
    // Clicks queued meanwhile wait for the next snapshot, where the extension
    // checks they are still pending before accepting them.
    let data = b.last.clone().map(|mut d| {
        d["accepting"] = accepting(&b);
        d
    });
    drop(b);
    if let Some(data) = data {
        emit(app, IntegrationUpdate { id: ID, data, error: None, event });
    }
    json!({ "commands": [], "interval": INTERVAL })
}

/// The queued accepts go to the extension now; stale clicks are dropped.
fn take_commands(b: &mut Bridge) -> Value {
    b.queued.retain(|(_, at)| at.elapsed() < QUEUED_FOR);
    b.in_flight.retain(|_, at| at.elapsed() < QUEUED_FOR);
    let commands: Vec<Value> = b
        .queued
        .drain(..)
        .map(|(id, _)| json!({ "op": "accept", "id": id }))
        .collect();
    for c in &commands {
        b.in_flight.insert(c["id"].as_str().unwrap_or_default().to_string(), Instant::now());
    }
    json!({ "commands": commands, "interval": INTERVAL })
}

fn accepting(b: &Bridge) -> Value {
    json!(b.queued.iter().map(|(id, _)| id.clone()).chain(b.in_flight.keys().cloned()).collect::<Vec<_>>())
}

/// Accept from the island card: picked up at the extension's next check-in.
pub fn queue_accept(app: &AppHandle, id: &str) -> Result<(), String> {
    if !valid_id(id) {
        return Err("Unknown ticket".into());
    }
    let mut b = BRIDGE.lock().unwrap();
    let seen_at = b.last.as_ref().and_then(|d| d["seenAt"].as_u64()).unwrap_or(0);
    if now_ms().saturating_sub(seen_at) > 60_000 {
        return Err("Open whaticket.com in Chrome or Edge (with the Coucou extension) to accept from here.".into());
    }
    if !b.queued.iter().any(|(q, _)| q == id) && !b.in_flight.contains_key(id) {
        b.queued.push((id.to_string(), Instant::now()));
    }
    let data = b.last.clone().map(|mut d| {
        d["accepting"] = accepting(&b);
        d
    });
    drop(b);
    if let Some(data) = data {
        emit(app, IntegrationUpdate { id: ID, data, error: None, event: None });
    }
    Ok(())
}

/// The queues of the last check-in, for Settings → WhaTicket → "Only from".
pub fn queues() -> Value {
    let b = BRIDGE.lock().unwrap();
    b.last.as_ref().and_then(|d| d.get("queues").cloned()).unwrap_or_else(|| json!([]))
}

pub fn web_url(id: Option<&str>) -> String {
    match id.filter(|i| valid_id(i)) {
        Some(id) => format!("{WEB}/tickets/{id}"),
        None => format!("{WEB}/tickets"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hours() {
        assert!(in_hours("", 3 * 60));
        assert!(in_hours("09:00-18:00", 9 * 60));
        assert!(!in_hours("09:00-18:00", 18 * 60));
        assert!(in_hours("22:00-06:00", 23 * 60));
        assert!(in_hours("22:00-06:00", 5 * 60));
        assert!(!in_hours("22:00-06:00", 12 * 60));
        assert!(in_hours("nonsense", 12 * 60));
    }

    #[test]
    fn queue_rules() {
        let mine = vec!["a".to_string(), "b".to_string()];
        assert!(queue_allowed(Some("x"), &[]));
        assert!(queue_allowed(None, &[]));
        assert!(queue_allowed(Some("b"), &mine));
        assert!(!queue_allowed(Some("c"), &mine));
        assert!(!queue_allowed(None, &mine));
    }

    #[test]
    fn snapshot_tickets_are_checked_and_trimmed() {
        let msg = json!({ "pending": [
            { "id": "6b1c-uuid", "name": "María", "unread": 2, "queueId": "q-1", "queue": "Soporte", "aiHandling": true, "extra": "x" },
            { "id": "../users", "name": "bad" },
            { "name": "no id" },
        ]});
        let list = tickets(&msg, "pending");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0]["id"], "6b1c-uuid");
        assert_eq!(list[0]["queue"], "Soporte");
        assert_eq!(list[0]["aiHandling"], true);
        assert!(list[0].get("extra").is_none());
        assert!(tickets(&json!({}), "mine").is_empty());
    }

    #[test]
    fn snapshot_queues_are_checked() {
        let msg = json!({ "queues": [{ "id": "q-1", "name": "Soporte", "color": "#0af", "x": 1 }, { "id": "a/b" }, 3] });
        assert_eq!(queue_list(&msg), json!([{ "id": "q-1", "name": "Soporte", "color": "#0af" }]));
        assert_eq!(queue_list(&json!({})), json!([]));
    }

    #[test]
    fn ids_and_urls() {
        assert!(valid_id("6b1c0e2a-1d2f-4c1b-9a77-0f3c2b1a9e10"));
        assert!(!valid_id("a/b"));
        assert_eq!(web_url(Some("t-1")), "https://app.whaticket.com/tickets/t-1");
        assert_eq!(web_url(Some("../x")), "https://app.whaticket.com/tickets");
        assert!(error_text("session").contains("expired"));
    }

    #[test]
    fn a_long_gap_starts_over_silently() {
        let mut b = Bridge::default();
        b.seen = Some(HashSet::from(["t-1".to_string()]));
        b.mine_ready = true;
        b.start_over();
        assert!(b.seen.is_none());
        assert!(!b.mine_ready);
    }

    #[test]
    fn queued_clicks_become_commands_once() {
        let mut b = Bridge::default();
        b.queued.push(("t-1".into(), Instant::now()));
        let reply = take_commands(&mut b);
        assert_eq!(reply["commands"][0]["id"], "t-1");
        assert!(b.in_flight.contains_key("t-1"));
        assert_eq!(take_commands(&mut b)["commands"].as_array().unwrap().len(), 0);
        assert_eq!(accepting(&b), json!(["t-1"]));
    }
}
