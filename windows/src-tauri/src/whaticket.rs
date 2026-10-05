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
//
// Stats (same as NotchBuddy/Sources/App/WhaTicketStats.swift): every check-in also
// feeds a local log of the tickets that arrived in the queue and the ones we accepted
// (whaticket-stats.json in the local app-data folder, a year kept, never uploaded) —
// ticket ids, queues and times only, never a customer's name, number or message.
// The numbers are worked out by windows/src/core/whaticketStats.ts.
//  - "arrived": a ticket id seen in the queue for the first time.
//  - "accepted": an arrived ticket that moved into my tickets — "click" (Coucou),
//    "auto" (auto-accept) or "web" (anywhere else); `wait` = seconds since it arrived.
//  - One arrival and one accept per ticket and day at most.
//  - The first snapshot after a gap logs the tickets already waiting with
//    `backlog: true`: they did come in, but their arrival time is unknown, so they
//    stay out of the per-hour chart and of the waits.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
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
                        "channel": t.get("channel").and_then(Value::as_str).filter(|c| !c.is_empty())
                            .map(|c| c.chars().take(40).collect::<String>()),
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

// ── Stats: the arrival / accept log (pure, tested below) ─────────────────────

/// Events older than this many days are dropped.
const KEEP_DAYS: f64 = 365.0;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatEvent {
    /// The ticket id.
    pub id: String,
    /// "arrived" or "accepted".
    pub kind: String,
    /// Milliseconds since the epoch.
    pub at: f64,
    /// The local day it was logged, "YYYY-MM-DD" (one arrival / accept per ticket and day).
    pub day: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub queue_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub queue: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channel: Option<String>,
    /// Already waiting when we started watching: arrival time unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backlog: Option<bool>,
    /// accepted: "click", "auto" or "web".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub how: Option<String>,
    /// accepted: seconds since the arrival (none for a backlog ticket).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wait: Option<i64>,
}

/// What the log keeps of a ticket in the queue.
pub struct Seen {
    pub id: String,
    pub queue_id: Option<String>,
    pub queue: String,
    pub channel: Option<String>,
}

#[derive(Default)]
pub struct Tracker {
    pub events: Vec<StatEvent>,
    /// Arrived and not accepted yet: id → its arrival.
    open: HashMap<String, StatEvent>,
    arrived_on: HashSet<String>,
    accepted_on: HashSet<String>,
}

impl Tracker {
    pub fn new(mut events: Vec<StatEvent>) -> Self {
        events.retain(|e| e.kind == "arrived" || e.kind == "accepted");
        events.sort_by(|a, b| a.at.partial_cmp(&b.at).unwrap_or(std::cmp::Ordering::Equal));
        let mut t = Tracker { events, ..Default::default() };
        t.rebuild();
        t
    }

    fn rebuild(&mut self) {
        self.open.clear();
        self.arrived_on.clear();
        self.accepted_on.clear();
        for e in &self.events {
            let key = format!("{}|{}", e.id, e.day);
            if e.kind == "arrived" {
                self.open.insert(e.id.clone(), e.clone());
                self.arrived_on.insert(key);
            } else {
                self.open.remove(&e.id);
                self.accepted_on.insert(key);
            }
        }
    }

    /// One snapshot of the queue (`pending`) and my tickets (`mine`). `backlog`: the
    /// first snapshot after a gap. Returns whether anything was logged.
    pub fn observe(&mut self, pending: &[Seen], mine: &[String], backlog: bool, now_ms: f64, day: &str) -> bool {
        let mut changed = false;
        for t in pending {
            let key = format!("{}|{day}", t.id);
            if self.open.contains_key(&t.id) || self.arrived_on.contains(&key) {
                continue;
            }
            let e = StatEvent {
                id: t.id.clone(),
                kind: "arrived".into(),
                at: now_ms,
                day: day.to_string(),
                queue_id: t.queue_id.clone(),
                queue: Some(t.queue.clone()).filter(|q| !q.is_empty()),
                channel: t.channel.clone(),
                backlog: backlog.then_some(true),
                how: None,
                wait: None,
            };
            self.open.insert(t.id.clone(), e.clone());
            self.arrived_on.insert(key);
            self.events.push(e);
            changed = true;
        }
        // Moved from the queue into my tickets, by any means: accepted elsewhere (a click
        // or auto-accept in Coucou is logged as soon as the extension confirms it).
        let waiting: HashSet<&str> = pending.iter().map(|t| t.id.as_str()).collect();
        for id in mine {
            if !waiting.contains(id.as_str()) && self.accept(id, "web", now_ms, day) {
                changed = true;
            }
        }
        changed
    }

    /// An arrived ticket became mine. Returns whether it was logged.
    pub fn accept(&mut self, id: &str, how: &str, now_ms: f64, day: &str) -> bool {
        let Some(arrival) = self.open.remove(id) else { return false };
        if !self.accepted_on.insert(format!("{id}|{day}")) {
            return false;
        }
        let wait = if arrival.backlog == Some(true) { None } else { Some(((now_ms - arrival.at) / 1000.0).max(0.0) as i64) };
        self.events.push(StatEvent {
            id: id.to_string(),
            kind: "accepted".into(),
            at: now_ms,
            day: day.to_string(),
            queue_id: arrival.queue_id,
            queue: arrival.queue,
            channel: arrival.channel,
            backlog: None,
            how: Some(how.to_string()),
            wait,
        });
        true
    }

    /// Drops what is older than a year. Returns whether anything was dropped.
    pub fn prune(&mut self, now_ms: f64) -> bool {
        let cutoff = now_ms - KEEP_DAYS * 86_400_000.0;
        let before = self.events.len();
        self.events.retain(|e| e.at >= cutoff);
        if self.events.len() == before {
            return false;
        }
        self.rebuild();
        true
    }

    pub fn reset(&mut self) {
        self.events.clear();
        self.rebuild();
    }

    /// Today's arrivals, accepts and auto-accepts, for the card (events are in time
    /// order, so only today's tail is read).
    pub fn today(&self, day: &str) -> Value {
        let (mut arrived, mut accepted, mut auto) = (0, 0, 0);
        for e in self.events.iter().rev().take_while(|e| e.day == day) {
            if e.kind == "arrived" {
                arrived += 1;
            } else {
                accepted += 1;
                if e.how.as_deref() == Some("auto") {
                    auto += 1;
                }
            }
        }
        json!({ "arrived": arrived, "accepted": accepted, "auto": auto })
    }
}

fn stats_path() -> std::path::PathBuf {
    crate::settings::local_dir().join("whaticket-stats.json")
}

/// A missing file is an empty log; an unreadable one is kept aside, never overwritten.
fn load_stats() -> Tracker {
    let path = stats_path();
    let events = match std::fs::read(&path) {
        Ok(bytes) => match serde_json::from_slice::<Value>(&bytes)
            .ok()
            .and_then(|v| v.get("events").cloned())
            .and_then(|e| serde_json::from_value::<Vec<StatEvent>>(e).ok())
        {
            Some(events) => events,
            None => {
                let _ = std::fs::rename(&path, path.with_file_name("whaticket-stats.unreadable.json"));
                Vec::new()
            }
        },
        Err(_) => Vec::new(),
    };
    let mut t = Tracker::new(events);
    t.prune(now_ms() as f64);
    t
}

static STATS: std::sync::LazyLock<Mutex<Tracker>> = std::sync::LazyLock::new(|| Mutex::new(load_stats()));
static SAVE_PENDING: AtomicBool = AtomicBool::new(false);

/// Written a few seconds after a change, once for a burst of changes — never on a
/// check-in where nothing happened.
fn schedule_save() {
    if SAVE_PENDING.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(|| {
        std::thread::sleep(Duration::from_secs(3));
        SAVE_PENDING.store(false, Ordering::SeqCst);
        save_stats();
    });
}

fn save_stats() {
    let text = {
        let mut t = STATS.lock().unwrap();
        t.prune(now_ms() as f64);
        serde_json::to_string(&json!({ "version": 1, "events": t.events }))
    };
    let Ok(text) = text else { return };
    let path = stats_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let tmp = path.with_extension("json.tmp");
    let written = std::fs::write(&tmp, text).and_then(|_| std::fs::rename(&tmp, &path));
    if let Err(e) = written {
        log::line(format!("whaticket: stats not saved: {e}"));
    }
}

fn today_key() -> String {
    let (y, m, d, _, _, _) = platform::local_time();
    format!("{y:04}-{m:02}-{d:02}")
}

/// One snapshot into the log; returns today's counts for the card.
fn stats_observe(pending: &[Value], mine: &[Value], backlog: bool) -> Value {
    let seen: Vec<Seen> = pending
        .iter()
        .map(|t| Seen {
            id: t["id"].as_str().unwrap_or_default().to_string(),
            queue_id: t["queueId"].as_str().filter(|q| !q.is_empty()).map(str::to_string),
            queue: t["queue"].as_str().unwrap_or("").to_string(),
            channel: t["channel"].as_str().map(str::to_string),
        })
        .collect();
    let mine: Vec<String> = mine.iter().filter_map(|t| t["id"].as_str().map(str::to_string)).collect();
    let day = today_key();
    let mut t = STATS.lock().unwrap();
    if t.observe(&seen, &mine, backlog, now_ms() as f64, &day) {
        schedule_save();
    }
    t.today(&day)
}

/// The extension confirmed an accept we sent ("click" or "auto"); returns today's counts.
fn stats_accepted(id: &str, how: &str) -> Value {
    let day = today_key();
    let mut t = STATS.lock().unwrap();
    if t.accept(id, how, now_ms() as f64, &day) {
        schedule_save();
    }
    t.today(&day)
}

/// Every event of the log, for Settings → WhaTicket → Stats.
pub fn stats_events() -> Value {
    serde_json::to_value(&STATS.lock().unwrap().events).unwrap_or_else(|_| json!([]))
}

/// Settings → WhaTicket → Reset stats (after the user confirmed).
pub fn stats_reset() {
    STATS.lock().unwrap().reset();
    save_stats();
    log::line("whaticket: stats reset".to_string());
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
    // Stats: arrivals and accepts (the first snapshot after a gap logs the queue as backlog).
    let today = stats_observe(&pending, &mine, b.seen.is_none());
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
        "today": today,
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
    let mut today = None;
    for r in msg.get("results").and_then(Value::as_array).cloned().unwrap_or_default() {
        let id = r.get("id").and_then(Value::as_str).unwrap_or_default().to_string();
        b.in_flight.remove(&id);
        let auto = b.auto.remove(&id);
        let name = b.names.get(&id).cloned().unwrap_or_else(|| "?".into());
        if r.get("ok").and_then(Value::as_bool).unwrap_or(false) {
            log::line(format!("whaticket: {} ticket {id}", if auto { "auto-accepted" } else { "accepted" }));
            today = Some(stats_accepted(&id, if auto { "auto" } else { "click" }));
            event = Some(IntegrationEvent { success: true, label: format!("Accepted · {name}"), detail: None });
        } else {
            let why = error_text(r.get("error").and_then(Value::as_str).unwrap_or(""));
            log::line(format!("whaticket: accepting {id} failed: {why}"));
            event = Some(IntegrationEvent { success: false, label: format!("Couldn't accept · {name}"), detail: Some(why) });
        }
    }
    // Clicks queued meanwhile wait for the next snapshot, where the extension
    // checks they are still pending before accepting them.
    if let (Some(today), Some(last)) = (today, b.last.as_mut()) {
        last["today"] = today;
    }
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

    fn seen(id: &str, queue: &str) -> Seen {
        Seen { id: id.into(), queue_id: Some(format!("q-{queue}")), queue: queue.into(), channel: None }
    }

    const H: f64 = 3_600_000.0;
    const M: f64 = 60_000.0;

    #[test]
    fn stats_log_arrivals_and_accepts() {
        let mut t = Tracker::default();
        let day = "2026-10-04";
        assert!(t.observe(&[seen("a", "Soporte"), seen("b", "Soporte")], &[], false, 9.0 * H, day));
        // The same snapshot again writes nothing.
        assert!(!t.observe(&[seen("a", "Soporte"), seen("b", "Soporte")], &[], false, 9.0 * H + M, day));
        // "a" accepted from Coucou, then it shows in mine: logged once, as a click.
        assert!(t.accept("a", "click", 9.0 * H + 5.0 * M, day));
        assert!(!t.observe(&[seen("b", "Soporte")], &["a".to_string()], false, 9.0 * H + 6.0 * M, day));
        // "b" taken in the web app.
        assert!(t.observe(&[], &["a".to_string(), "b".to_string()], false, 9.0 * H + 10.0 * M, day));
        let accepted: Vec<&StatEvent> = t.events.iter().filter(|e| e.kind == "accepted").collect();
        assert_eq!(accepted[0].how.as_deref(), Some("click"));
        assert_eq!(accepted[0].wait, Some(300));
        assert_eq!(accepted[1].how.as_deref(), Some("web"));
        assert_eq!(accepted[1].wait, Some(600));
        assert_eq!(accepted[1].queue.as_deref(), Some("Soporte"));
        // A ticket that never waited in the queue isn't an accept.
        assert!(!t.observe(&[], &["c".to_string()], false, 10.0 * H, day));
        assert_eq!(t.today(day), json!({ "arrived": 2, "accepted": 2, "auto": 0 }));
        assert_eq!(t.today("2026-10-05"), json!({ "arrived": 0, "accepted": 0, "auto": 0 }));
    }

    #[test]
    fn stats_once_per_day_and_backlog() {
        let mut t = Tracker::default();
        let day = "2026-10-04";
        t.observe(&[seen("a", "")], &[], true, 8.0 * H, day);
        assert_eq!(t.events[0].backlog, Some(true));
        assert_eq!(t.events[0].queue, None);
        assert!(t.accept("a", "auto", 8.5 * H, day));
        assert_eq!(t.events[1].wait, None);
        assert_eq!(t.today(day), json!({ "arrived": 1, "accepted": 1, "auto": 1 }));
        // Back in the queue and accepted again the same day: counted once.
        assert!(!t.observe(&[seen("a", "")], &[], false, 10.0 * H, day));
        assert!(!t.accept("a", "click", 10.1 * H, day));
        assert_eq!(t.events.len(), 2);
        assert!(t.observe(&[seen("a", "")], &[], false, 33.0 * H, "2026-10-05"));
    }

    #[test]
    fn stats_reload_prune_and_file_format() {
        let mut t = Tracker::default();
        t.observe(&[seen("a", "Soporte")], &[], false, 9.0 * H, "2026-10-04");
        let text = serde_json::to_string(&json!({ "version": 1, "events": t.events })).unwrap();
        assert!(text.contains("\"queueId\":\"q-Soporte\""));
        assert!(!text.contains("backlog") && !text.contains("\"how\""));
        let file: Value = serde_json::from_str(&text).unwrap();
        let back: Vec<StatEvent> = serde_json::from_value(file["events"].clone()).unwrap();
        let mut again = Tracker::new(back);
        assert!(again.accept("a", "web", 9.0 * H + 2.0 * M, "2026-10-04"));
        assert_eq!(again.events[1].wait, Some(120));
        assert!(!again.prune(9.0 * H + 24.0 * H));
        assert!(again.prune(9.0 * H + 366.0 * 24.0 * H));
        assert!(again.events.is_empty());
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
