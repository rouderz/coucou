// WhaTicket (the WhatsApp ticket system, github.com/canove/whaticket-community):
// sign in, show the queue and my open tickets, and — when the user turns it on —
// accept new tickets as they arrive, exactly like clicking Accept in WhaTicket.
//
// API (community version; most forks keep it):
//   POST /auth/login {email, password}        → {token, user: {id, name, queues: [{id, name, color}]}}
//   GET  /tickets?status=pending&queueIds=[…]  → {tickets: [...], count, hasMore}
//   GET  /tickets/:id                          → the ticket (to check it's still pending)
//   PUT  /tickets/:id {status: "open", userId} → accept; {status: "pending", userId: null} → undo
// The access token lasts 15 minutes: on a 401 we sign in again with the stored
// password (Credential Manager / Secret Service), which works on every fork.
//
// Polling every 20 s while the pill is on; nothing at all when it's off or Coucou is paused.
// Coucou never writes to a customer: auto-accept only assigns the ticket.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Manager};

use crate::integrations::{emit, IntegrationEvent, IntegrationUpdate};
use crate::{log, platform, secrets};

pub const ID: &str = "integration_whaticket";
const UNDO_WINDOW: Duration = Duration::from_secs(120);

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Queue {
    pub id: i64,
    pub name: String,
    pub color: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub user_id: i64,
    pub name: String,
    pub queues: Vec<Queue>,
}

struct Session {
    base: String,
    token: String,
    account: Account,
}

#[derive(Default)]
struct Memory {
    /// Pending ticket ids seen so far (None until the first poll, which is silent).
    pending: Option<HashSet<i64>>,
    /// My open tickets: id → unread count, to notice new messages.
    unread: HashMap<i64, i64>,
    /// Tickets Coucou accepted on its own, for Undo.
    accepted: HashMap<i64, Instant>,
    /// My tickets have been seen once (the first poll only fills the card).
    mine_ready: bool,
}

static SESSION: Mutex<Option<Session>> = Mutex::new(None);
static MEMORY: std::sync::LazyLock<Mutex<Memory>> = std::sync::LazyLock::new(|| Mutex::new(Memory::default()));

// ── Pure helpers (tested below) ───────────────────────────────────────────────

/// "https://api.example.com/" → "https://api.example.com". Only http(s).
pub fn normalise_base(url: &str) -> Option<String> {
    let url = url.trim().trim_end_matches('/');
    (url.starts_with("https://") || url.starts_with("http://")).then(|| url.to_string())
}

/// "09:00-18:00" (or "22:00-06:00" across midnight); empty = any time.
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

/// Whether a new pending ticket in `queue` may be accepted on its own.
/// `queues` empty = any of my queues (and tickets with no queue).
pub fn queue_allowed(queue: Option<i64>, queues: &[i64]) -> bool {
    queues.is_empty() || queue.map(|q| queues.contains(&q)).unwrap_or(false)
}

/// The fields the island shows, from one ticket of the API.
pub fn ticket_view(t: &Value) -> Option<Value> {
    let id = t.get("id")?.as_i64()?;
    let contact = t.get("contact");
    let name = contact
        .and_then(|c| c.get("name"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .or_else(|| contact.and_then(|c| c.get("number")).and_then(Value::as_str))
        .unwrap_or("?");
    let queue = t.get("queue").filter(|q| q.is_object());
    Some(json!({
        "id": id,
        "name": name,
        "number": contact.and_then(|c| c.get("number")).and_then(Value::as_str).unwrap_or(""),
        "lastMessage": t.get("lastMessage").and_then(Value::as_str).unwrap_or(""),
        "unread": t.get("unreadMessages").and_then(Value::as_i64).unwrap_or(0),
        "queueId": t.get("queueId").and_then(Value::as_i64),
        "queue": queue.and_then(|q| q.get("name")).and_then(Value::as_str).unwrap_or(""),
        "queueColor": queue.and_then(|q| q.get("color")).and_then(Value::as_str).unwrap_or(""),
        "connection": t.get("whatsapp").and_then(|w| w.get("name")).and_then(Value::as_str).unwrap_or(""),
        "updatedAt": t.get("updatedAt").and_then(Value::as_str).unwrap_or(""),
        "status": t.get("status").and_then(Value::as_str).unwrap_or(""),
        "userId": t.get("userId").and_then(Value::as_i64),
        "isGroup": t.get("isGroup").and_then(Value::as_bool).unwrap_or(false),
    }))
}

pub fn parse_account(json: &Value) -> Option<(String, Account)> {
    let token = json.get("token")?.as_str()?.to_string();
    let user = json.get("user")?;
    let queues = user
        .get("queues")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|q| {
                    Some(Queue {
                        id: q.get("id")?.as_i64()?,
                        name: q.get("name").and_then(Value::as_str).unwrap_or("").to_string(),
                        color: q.get("color").and_then(Value::as_str).unwrap_or("").to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Some((
        token,
        Account {
            user_id: user.get("id")?.as_i64()?,
            name: user.get("name").and_then(Value::as_str).unwrap_or("").to_string(),
            queues,
        },
    ))
}

// ── HTTP ──────────────────────────────────────────────────────────────────────

fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(12))
        .build()
        .unwrap_or_default()
}

fn credentials() -> Option<(String, String, String)> {
    let base = normalise_base(&secrets::get("whaticket-url")?)?;
    Some((base, secrets::get("whaticket-email")?, secrets::get("whaticket-password")?))
}

/// Signs in with the stored credentials and keeps the session.
pub async fn login() -> Result<Account, String> {
    let (base, email, password) = credentials().ok_or("Add the WhaTicket URL, email and password first.")?;
    let response = client()
        .post(format!("{base}/auth/login"))
        .json(&json!({ "email": email, "password": password }))
        .send()
        .await
        .map_err(|_| format!("Can't reach {base}"))?;
    let code = response.status().as_u16();
    if code == 401 || code == 403 {
        return Err("Wrong email or password".into());
    }
    if !response.status().is_success() {
        return Err(format!("WhaTicket answered {code} — is it the backend (API) URL?"));
    }
    let json: Value = response.json().await.map_err(|_| "That URL doesn't answer like WhaTicket.".to_string())?;
    let (token, account) = parse_account(&json).ok_or("That URL doesn't answer like WhaTicket.")?;
    *SESSION.lock().unwrap() = Some(Session { base, token, account: account.clone() });
    Ok(account)
}

/// Forget the session (credentials changed, or "Sign out").
pub fn forget() {
    *SESSION.lock().unwrap() = None;
    *MEMORY.lock().unwrap() = Memory::default();
}

fn session() -> Option<(String, String, Account)> {
    SESSION.lock().unwrap().as_ref().map(|s| (s.base.clone(), s.token.clone(), s.account.clone()))
}

/// One authorised request; signs in (again) when there's no session or the token expired.
async fn call(method: reqwest::Method, path: &str, body: Option<Value>) -> Result<Value, String> {
    for attempt in 0..2 {
        if session().is_none() || attempt == 1 {
            login().await?;
        }
        let (base, token, _) = session().ok_or("Not signed in")?;
        let mut request = client().request(method.clone(), format!("{base}{path}")).bearer_auth(&token);
        if let Some(b) = &body {
            request = request.json(b);
        }
        let response = request.send().await.map_err(|_| format!("Can't reach {base}"))?;
        let code = response.status().as_u16();
        if (code == 401 || code == 403) && attempt == 0 {
            continue;
        }
        if !response.status().is_success() {
            return Err(format!("WhaTicket error {code}"));
        }
        return Ok(response.json().await.unwrap_or(Value::Null));
    }
    Err("Not signed in".into())
}

async fn tickets(status: &str, queue_ids: &[i64]) -> Result<Vec<Value>, String> {
    let ids = serde_json::to_string(queue_ids).unwrap_or_else(|_| "[]".into());
    let path = format!(
        "/tickets?status={status}&showAll=false&pageNumber=1&queueIds={}",
        urlencode(&ids)
    );
    let json = call(reqwest::Method::GET, &path, None).await?;
    Ok(json.get("tickets").and_then(Value::as_array).cloned().unwrap_or_default())
}

fn urlencode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// Accepts a ticket as me — only if it's still pending and nobody has it.
pub async fn accept(id: i64) -> Result<(), String> {
    let current = call(reqwest::Method::GET, &format!("/tickets/{id}"), None).await?;
    let status = current.get("status").and_then(Value::as_str).unwrap_or("");
    let owner = current.get("userId").and_then(Value::as_i64);
    if status != "pending" || owner.is_some() {
        return Err("Someone already took that ticket.".into());
    }
    let (_, _, account) = session().ok_or("Not signed in")?;
    call(
        reqwest::Method::PUT,
        &format!("/tickets/{id}"),
        Some(json!({ "status": "open", "userId": account.user_id })),
    )
    .await?;
    Ok(())
}

/// Puts a ticket Coucou accepted back in the queue.
pub async fn undo(id: i64) -> Result<(), String> {
    let recent = MEMORY.lock().unwrap().accepted.get(&id).map(|t| t.elapsed() < UNDO_WINDOW).unwrap_or(false);
    if !recent {
        return Err("Too late to undo — reopen it in WhaTicket.".into());
    }
    call(
        reqwest::Method::PUT,
        &format!("/tickets/{id}"),
        Some(json!({ "status": "pending", "userId": Value::Null })),
    )
    .await?;
    MEMORY.lock().unwrap().accepted.remove(&id);
    Ok(())
}

/// The web app's address for a ticket (the "web URL" setting, else the API URL).
pub fn web_url(id: Option<i64>) -> Option<String> {
    let base = secrets::get("whaticket-web-url")
        .and_then(|u| normalise_base(&u))
        .or_else(|| secrets::get("whaticket-url").and_then(|u| normalise_base(&u)))?;
    Some(match id {
        Some(id) => format!("{base}/tickets/{id}"),
        None => format!("{base}/tickets"),
    })
}

// ── Polling ───────────────────────────────────────────────────────────────────

struct Rules {
    auto_accept: bool,
    queues: Vec<i64>,
    hours: String,
    dnd: bool,
}

fn rules(app: &AppHandle) -> Rules {
    app.try_state::<crate::Shared>()
        .map(|shared| {
            let s = shared.settings.lock().unwrap();
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as f64)
                .unwrap_or(0.0);
            Rules {
                auto_accept: s.whaticket_auto_accept,
                queues: s.whaticket_queues.clone(),
                hours: s.whaticket_hours.clone(),
                dnd: s.dnd_until.map(|u| u > now).unwrap_or(false),
            }
        })
        .unwrap_or(Rules { auto_accept: false, queues: vec![], hours: String::new(), dnd: false })
}

fn minutes_now() -> u32 {
    let (_, _, _, h, mi, _) = platform::local_time();
    h as u32 * 60 + mi as u32
}

fn error(app: &AppHandle, message: String) {
    emit(app, IntegrationUpdate { id: ID, data: json!({}), error: Some(message), event: None });
}

pub async fn poll(app: AppHandle) {
    if credentials().is_none() {
        return;
    }
    if session().is_none() {
        if let Err(e) = login().await {
            return error(&app, e);
        }
    }
    let Some((_, _, account)) = session() else { return };
    let mine_queues: Vec<i64> = account.queues.iter().map(|q| q.id).collect();

    let pending = match tickets("pending", &mine_queues).await {
        Ok(t) => t,
        Err(e) => return error(&app, e),
    };
    let open = tickets("open", &mine_queues).await.unwrap_or_default();
    let mine: Vec<&Value> = open
        .iter()
        .filter(|t| t.get("userId").and_then(Value::as_i64) == Some(account.user_id))
        .collect();

    let rules = rules(&app);
    let mut event: Option<IntegrationEvent> = None;
    let mut auto_accepted: Vec<Value> = Vec::new();

    // New tickets in the queue.
    let ids: HashSet<i64> = pending.iter().filter_map(|t| t.get("id").and_then(Value::as_i64)).collect();
    let fresh: Vec<&Value> = {
        let mut memory = MEMORY.lock().unwrap();
        let fresh = match &memory.pending {
            None => Vec::new(), // first poll: fill the card silently
            Some(seen) => pending
                .iter()
                .filter(|t| t.get("id").and_then(Value::as_i64).map(|id| !seen.contains(&id)).unwrap_or(false))
                .collect(),
        };
        memory.pending = Some(ids);
        fresh
    };
    for t in fresh {
        let Some(view) = ticket_view(t) else { continue };
        let id = view["id"].as_i64().unwrap_or_default();
        let queue = view["queueId"].as_i64();
        let can = rules.auto_accept
            && !rules.dnd
            && !view["isGroup"].as_bool().unwrap_or(false)
            && queue_allowed(queue, &rules.queues)
            && in_hours(&rules.hours, minutes_now());
        if can {
            match accept(id).await {
                Ok(()) => {
                    log::line(format!("whaticket: auto-accepted ticket {id}"));
                    MEMORY.lock().unwrap().accepted.insert(id, Instant::now());
                    auto_accepted.push(json!({ "id": id, "name": view["name"], "queue": view["queue"] }));
                    let detail = [view["queue"].as_str().unwrap_or(""), view["lastMessage"].as_str().unwrap_or("")]
                        .iter()
                        .filter(|s| !s.is_empty())
                        .cloned()
                        .collect::<Vec<_>>()
                        .join(" · ");
                    event = Some(IntegrationEvent {
                        success: true,
                        label: format!("Accepted · {}", view["name"].as_str().unwrap_or("?")),
                        detail: (!detail.is_empty()).then_some(detail),
                    });
                    continue;
                }
                Err(e) => log::line(format!("whaticket: auto-accept {id} failed: {e}")),
            }
        }
        event = Some(IntegrationEvent {
            success: true,
            label: format!("New ticket · {}", view["name"].as_str().unwrap_or("?")),
            detail: view["lastMessage"].as_str().filter(|s| !s.is_empty()).map(str::to_string),
        });
    }

    // New messages on my tickets.
    {
        let mut memory = MEMORY.lock().unwrap();
        let first = !memory.mine_ready;
        memory.mine_ready = true;
        let mut next = HashMap::new();
        for t in &mine {
            let Some(view) = ticket_view(t) else { continue };
            let id = view["id"].as_i64().unwrap_or_default();
            let unread = view["unread"].as_i64().unwrap_or(0);
            let before = memory.unread.get(&id).copied();
            // A ticket that just became mine (accepted here or in WhaTicket) isn't news.
            if event.is_none() && !first && before.map(|b| unread > b).unwrap_or(false) {
                event = Some(IntegrationEvent {
                    success: true,
                    label: format!("Message · {}", view["name"].as_str().unwrap_or("?")),
                    detail: view["lastMessage"].as_str().filter(|s| !s.is_empty()).map(str::to_string),
                });
            }
            next.insert(id, unread);
        }
        memory.unread = next;
        memory.accepted.retain(|_, at| at.elapsed() < UNDO_WINDOW);
    }

    let undoable: Vec<i64> = MEMORY.lock().unwrap().accepted.keys().copied().collect();
    emit(&app, IntegrationUpdate {
        id: ID,
        data: json!({
            "user": account.name,
            "pending": pending.iter().take(8).filter_map(ticket_view).collect::<Vec<_>>(),
            "pendingCount": pending.len(),
            "mine": mine.iter().take(8).filter_map(|t| ticket_view(t)).collect::<Vec<_>>(),
            "mineCount": mine.len(),
            "autoAccept": rules.auto_accept,
            "autoAccepted": auto_accepted,
            "undoable": undoable,
        }),
        error: None,
        event,
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base_urls() {
        assert_eq!(normalise_base(" https://api.x.com/ ").as_deref(), Some("https://api.x.com"));
        assert_eq!(normalise_base("ftp://x"), None);
    }

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
    fn queues() {
        assert!(queue_allowed(Some(2), &[]));
        assert!(queue_allowed(None, &[]));
        assert!(queue_allowed(Some(2), &[1, 2]));
        assert!(!queue_allowed(Some(3), &[1, 2]));
        assert!(!queue_allowed(None, &[1]));
    }

    #[test]
    fn login_and_tickets() {
        let login = json!({ "token": "t", "user": { "id": 7, "name": "Ana", "queues": [ { "id": 1, "name": "Sales", "color": "#f00" } ] } });
        let (token, account) = parse_account(&login).unwrap();
        assert_eq!(token, "t");
        assert_eq!(account.user_id, 7);
        assert_eq!(account.queues[0].name, "Sales");

        let t = json!({ "id": 5, "status": "pending", "unreadMessages": 2, "lastMessage": "Hola", "queueId": 1,
            "contact": { "name": "", "number": "5491100" }, "queue": { "name": "Sales", "color": "#f00" }, "userId": null });
        let v = ticket_view(&t).unwrap();
        assert_eq!(v["name"], "5491100");
        assert_eq!(v["queue"], "Sales");
        assert_eq!(v["unread"], 2);
        assert!(v["userId"].is_null());
    }

    #[test]
    fn encodes_queue_ids() {
        assert_eq!(urlencode("[1,2]"), "%5B1%2C2%5D");
    }
}
