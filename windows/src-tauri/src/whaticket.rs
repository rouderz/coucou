// WhaTicket, the WhatsApp ticket system: show the queue and my open tickets, and —
// when the user turns it on — accept new tickets as they arrive.
//
// Two flavours:
//
// • whaticket.com (the hosted service) — an API token from Integrations → Tokens.
//   Public API at https://api.whaticket.com/api/v1 (openapi.json there):
//     GET  /me                            → the credential (name, company, permissions)
//     GET  /users, GET /queues            → who's who (a token has no user: Coucou finds
//                                           yours by your email)
//     GET  /tickets?status=pending        → needs tickets:view, tickets:viewAll, tickets:viewPending
//     GET  /tickets?status=open&userIds=… → my tickets
//     GET  /tickets/{id}                  → to check it's still pending
//     POST /tickets/{id}/transfer {userId}→ accept (needs tickets:transfer)
//   IDs are UUIDs. There's no way to put a ticket back in the queue, so no Undo.
//   (Signing in with email and password needs reCAPTCHA and an emailed code, which
//   an app can't do — that's why it's a token.)
//
// • WhaTicket Community (self-hosted, github.com/canove/whaticket-community):
//     POST /auth/login {email, password}        → {token, user: {id, name, queues}}
//     GET  /tickets?status=pending&queueIds=[…]  → {tickets}
//     PUT  /tickets/:id {status: "open", userId} → accept; {status: "pending", userId: null} → undo
//   The access token lasts 15 minutes: on a 401 we sign in again with the stored password.
//
// Polling every 20 s while the pill is on; nothing when it's off or Coucou is paused.
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
const CLOUD_API: &str = "https://api.whaticket.com";
const CLOUD_WEB: &str = "https://app.whaticket.com";

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Queue {
    pub id: String,
    pub name: String,
    pub color: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub user_id: String,
    pub name: String,
    pub queues: Vec<Queue>,
    /// whaticket.com (API token) rather than a self-hosted WhaTicket.
    pub cloud: bool,
    /// whaticket.com: every queue of the company (names and colours for the card).
    pub all_queues: Vec<Queue>,
}

struct Session {
    base: String,
    token: String,
    account: Account,
}

#[derive(Default)]
struct Memory {
    /// Pending ticket ids seen so far (None until the first poll, which is silent).
    pending: Option<HashSet<String>>,
    /// My open tickets: id → unread count, to notice new messages.
    unread: HashMap<String, i64>,
    /// Tickets Coucou accepted on its own, for Undo (self-hosted only).
    accepted: HashMap<String, Instant>,
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

/// The whaticket.com API root: the URL setting if any (with /api/v1 added), else the default.
pub fn cloud_base(url: Option<&str>) -> String {
    let base = url.and_then(normalise_base).unwrap_or_else(|| CLOUD_API.to_string());
    if base.ends_with("/api/v1") { base } else { format!("{base}/api/v1") }
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
pub fn queue_allowed(queue: Option<&str>, queues: &[String]) -> bool {
    queues.is_empty() || queue.map(|q| queues.iter().any(|x| x == q)).unwrap_or(false)
}

/// An id as text, whether the API sent a number (self-hosted) or a UUID (whaticket.com).
pub fn id_of(v: Option<&Value>) -> Option<String> {
    match v? {
        Value::String(s) if !s.is_empty() => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

/// A list under `key`, or the body itself when it's already a list.
pub fn list_of<'a>(json: &'a Value, key: &str) -> Vec<&'a Value> {
    match json {
        Value::Array(a) => a.iter().collect(),
        other => other.get(key).and_then(Value::as_array).map(|a| a.iter().collect()).unwrap_or_default(),
    }
}

pub fn parse_queue(q: &Value) -> Option<Queue> {
    Some(Queue {
        id: id_of(q.get("id"))?,
        name: q.get("name").and_then(Value::as_str).unwrap_or("").to_string(),
        color: q.get("color").and_then(Value::as_str).unwrap_or("").to_string(),
    })
}

/// The fields the island shows, from one ticket of either API.
/// `queues` names the queue when the ticket only carries its id (whaticket.com).
pub fn ticket_view(t: &Value, queues: &[Queue]) -> Option<Value> {
    let id = id_of(t.get("id"))?;
    let contact = t.get("contact");
    let name = contact
        .and_then(|c| c.get("name"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .or_else(|| contact.and_then(|c| c.get("number")).and_then(Value::as_str))
        .unwrap_or("?");
    let queue_id = id_of(t.get("queueId"));
    let embedded = t.get("queue").filter(|q| q.is_object()).and_then(parse_queue);
    let queue = embedded.or_else(|| queue_id.as_ref().and_then(|id| queues.iter().find(|q| &q.id == id).cloned()));
    Some(json!({
        "id": id,
        "name": name,
        "number": contact.and_then(|c| c.get("number")).and_then(Value::as_str).unwrap_or(""),
        "lastMessage": t.get("lastMessage").and_then(Value::as_str).unwrap_or(""),
        "unread": t.get("unreadMessages").and_then(Value::as_i64).unwrap_or(0),
        "queueId": queue_id,
        "queue": queue.as_ref().map(|q| q.name.clone()).unwrap_or_default(),
        "queueColor": queue.as_ref().map(|q| q.color.clone()).unwrap_or_default(),
        "updatedAt": t.get("updatedAt").and_then(Value::as_str).unwrap_or(""),
        "status": t.get("status").and_then(Value::as_str).unwrap_or(""),
        "userId": id_of(t.get("userId")),
        "isGroup": t.get("isGroup").and_then(Value::as_bool).unwrap_or(false),
    }))
}

/// Self-hosted login answer → (token, account).
pub fn parse_account(json: &Value) -> Option<(String, Account)> {
    let token = json.get("token")?.as_str()?.to_string();
    let user = json.get("user")?;
    let queues = list_of(user, "queues").into_iter().filter_map(parse_queue).collect();
    Some((
        token,
        Account {
            user_id: id_of(user.get("id"))?,
            name: user.get("name").and_then(Value::as_str).unwrap_or("").to_string(),
            queues,
            cloud: false,
            all_queues: Vec::new(),
        },
    ))
}

/// whaticket.com: me among the company's users, by email (case-insensitive).
pub fn find_user<'a>(users: &'a Value, email: &str) -> Option<&'a Value> {
    let email = email.trim().to_lowercase();
    list_of(users, "users").into_iter().find(|u| {
        u.get("email").and_then(Value::as_str).map(|e| e.trim().to_lowercase() == email).unwrap_or(false)
    })
}

/// whaticket.com permissions this token's profile still lacks.
pub fn missing_permissions(me: &Value) -> Vec<&'static str> {
    const NEEDED: &[&str] = &["tickets:view", "tickets:viewAll", "tickets:viewPending", "tickets:transfer", "users:view"];
    let have: Vec<String> = me
        .get("permissions")
        .and_then(Value::as_array)
        .map(|p| {
            p.iter()
                .filter_map(|x| x.as_str().map(str::to_string).or_else(|| x.get("name").and_then(Value::as_str).map(str::to_string)))
                .collect()
        })
        .unwrap_or_default();
    if have.is_empty() {
        return Vec::new(); // the answer didn't list them: let the requests speak
    }
    NEEDED.iter().copied().filter(|n| !have.iter().any(|h| h == n)).collect()
}

fn urlencode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

// ── HTTP ──────────────────────────────────────────────────────────────────────

fn client() -> reqwest::Client {
    reqwest::Client::builder().timeout(Duration::from_secs(12)).build().unwrap_or_default()
}

enum Credentials {
    /// whaticket.com: API root, token, the email that says which agent I am.
    Cloud { base: String, token: String, email: String },
    /// Self-hosted: backend URL, email, password.
    Community { base: String, email: String, password: String },
}

fn credentials() -> Option<Credentials> {
    let email = secrets::get("whaticket-email").unwrap_or_default();
    if let Some(token) = secrets::get("whaticket-token") {
        let base = cloud_base(secrets::get("whaticket-url").as_deref());
        return Some(Credentials::Cloud { base, token, email });
    }
    let base = normalise_base(&secrets::get("whaticket-url")?)?;
    Some(Credentials::Community { base, email, password: secrets::get("whaticket-password")? })
}

pub fn configured() -> bool {
    credentials().is_some()
}

async fn send(request: reqwest::RequestBuilder, base: &str) -> Result<(u16, Value), String> {
    let response = request.send().await.map_err(|e| format!("Can't reach {base} ({e})"))?;
    let code = response.status().as_u16();
    let text = response.text().await.unwrap_or_default();
    let json = serde_json::from_str(&text).unwrap_or_else(|_| json!({ "raw": text.chars().take(160).collect::<String>() }));
    Ok((code, json))
}

fn api_error(code: u16, json: &Value) -> String {
    let what = json
        .get("error")
        .or_else(|| json.get("message"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| json.get("raw").and_then(Value::as_str).map(|s| s.trim().to_string()))
        .unwrap_or_default();
    match (code, what.as_str()) {
        (401, "ERR_SHOULD_LOGIN_BY_AUTH_CODE") | (401, "ERR_SHOULD_LOGIN_BY_2FA") => {
            "This WhaTicket asks for a code to sign in: use an API token instead (whaticket.com → Integrations → Tokens).".into()
        }
        (429, _) => "WhaTicket says too many attempts — wait a minute and try again.".into(),
        (_, "") => format!("WhaTicket answered {code}"),
        (_, w) => format!("WhaTicket answered {code}: {w}"),
    }
}

/// Signs in (self-hosted) or checks the token and finds my user (whaticket.com).
pub async fn login() -> Result<Account, String> {
    match credentials().ok_or("Add your WhaTicket token (or URL, email and password) first.")? {
        Credentials::Cloud { base, token, email } => {
            let get = |path: &str| client().get(format!("{base}{path}")).bearer_auth(&token);
            let (code, me) = send(get("/me"), &base).await?;
            if code == 401 || code == 403 {
                return Err("WhaTicket refused the token — check it in whaticket.com → Integrations → Tokens.".into());
            }
            if code != 200 {
                return Err(api_error(code, &me));
            }
            let missing = missing_permissions(&me);
            if !missing.is_empty() {
                return Err(format!("The token's profile needs these permissions: {}", missing.join(", ")));
            }
            if email.trim().is_empty() {
                return Err("Add the email you sign in to WhaTicket with, so Coucou knows which agent you are.".into());
            }
            let (code, users) = send(get("/users"), &base).await?;
            if code != 200 {
                return Err(api_error(code, &users));
            }
            let user = find_user(&users, &email).ok_or("No WhaTicket user has that email — check it.")?;
            let (_, queues) = send(get("/queues"), &base).await?;
            let all_queues: Vec<Queue> = list_of(&queues, "queues").into_iter().filter_map(parse_queue).collect();
            // My queues: the user's own list, named from the company's.
            let mine: Vec<Queue> = list_of(user, "queues")
                .into_iter()
                .filter_map(|q| id_of(q.get("id")).or_else(|| id_of(Some(q))))
                .map(|id| {
                    all_queues.iter().find(|q| q.id == id).cloned().unwrap_or(Queue { id, name: String::new(), color: String::new() })
                })
                .collect();
            let account = Account {
                user_id: id_of(user.get("id")).ok_or("That user has no id")?,
                name: user.get("name").and_then(Value::as_str).unwrap_or("").to_string(),
                queues: mine,
                cloud: true,
                all_queues,
            };
            *SESSION.lock().unwrap() = Some(Session { base, token, account: account.clone() });
            Ok(account)
        }
        Credentials::Community { base, email, password } => {
            let request = client().post(format!("{base}/auth/login")).json(&json!({ "email": email, "password": password }));
            let (code, json) = send(request, &base).await?;
            if code == 401 || code == 403 {
                let why = json.get("error").and_then(Value::as_str).unwrap_or("");
                if why.starts_with("ERR_SHOULD_LOGIN_BY") {
                    return Err(api_error(code, &json));
                }
                return Err("Wrong email or password".into());
            }
            if code != 200 {
                return Err(format!("{} — is it the backend (API) URL?", api_error(code, &json)));
            }
            let (token, account) = parse_account(&json).ok_or("That URL doesn't answer like WhaTicket.")?;
            *SESSION.lock().unwrap() = Some(Session { base, token, account: account.clone() });
            Ok(account)
        }
    }
}

/// Forget the session (credentials changed, or "Sign in" again).
pub fn forget() {
    *SESSION.lock().unwrap() = None;
    *MEMORY.lock().unwrap() = Memory::default();
}

fn session() -> Option<(String, String, Account)> {
    SESSION.lock().unwrap().as_ref().map(|s| (s.base.clone(), s.token.clone(), s.account.clone()))
}

/// One authorised request; signs in (again) when needed (a self-hosted token expires).
async fn call(method: reqwest::Method, path: &str, body: Option<Value>) -> Result<Value, String> {
    for attempt in 0..2 {
        if session().is_none() || attempt == 1 {
            login().await?;
        }
        let (base, token, account) = session().ok_or("Not signed in")?;
        let mut request = client().request(method.clone(), format!("{base}{path}")).bearer_auth(&token);
        if let Some(b) = &body {
            request = request.json(b);
        }
        let (code, json) = send(request, &base).await?;
        if (code == 401 || code == 403) && attempt == 0 && !account.cloud {
            continue;
        }
        if code == 401 {
            return Err("WhaTicket refused the token — check it in whaticket.com → Integrations → Tokens.".into());
        }
        if !(200..300).contains(&code) {
            return Err(api_error(code, &json));
        }
        return Ok(json);
    }
    Err("Not signed in".into())
}

/// Pending tickets in my queues, and my open tickets.
async fn fetch(account: &Account) -> Result<(Vec<Value>, Vec<Value>), String> {
    let mine_queues: Vec<String> = account.queues.iter().map(|q| q.id.clone()).collect();
    if account.cloud {
        let pending = call(reqwest::Method::GET, "/tickets?status=pending", None).await?;
        let pending: Vec<Value> = list_of(&pending, "tickets")
            .into_iter()
            .filter(|t| {
                // A token sees the whole company: keep my queues (and tickets with none).
                let q = id_of(t.get("queueId"));
                mine_queues.is_empty() || q.as_ref().map(|q| mine_queues.contains(q)).unwrap_or(true)
            })
            .cloned()
            .collect();
        let path = format!("/tickets?status=open&userIds={}", urlencode(&account.user_id));
        let open = call(reqwest::Method::GET, &path, None).await.unwrap_or(Value::Null);
        let mine = list_of(&open, "tickets").into_iter().cloned().collect();
        return Ok((pending, mine));
    }
    let ids: Vec<Value> = mine_queues.iter().map(|q| q.parse::<i64>().map(Value::from).unwrap_or(Value::from(q.clone()))).collect();
    let ids = urlencode(&serde_json::to_string(&ids).unwrap_or_else(|_| "[]".into()));
    let path = |status: &str| format!("/tickets?status={status}&showAll=false&pageNumber=1&queueIds={ids}");
    let pending = call(reqwest::Method::GET, &path("pending"), None).await?;
    let open = call(reqwest::Method::GET, &path("open"), None).await.unwrap_or(Value::Null);
    let mine = list_of(&open, "tickets")
        .into_iter()
        .filter(|t| id_of(t.get("userId")).as_deref() == Some(account.user_id.as_str()))
        .cloned()
        .collect();
    Ok((list_of(&pending, "tickets").into_iter().cloned().collect(), mine))
}

fn valid_id(id: &str) -> Result<(), String> {
    if !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        Ok(())
    } else {
        Err("Unknown ticket".into())
    }
}

/// Accepts a ticket as me — only if it's still pending and nobody has it.
pub async fn accept(id: &str) -> Result<(), String> {
    valid_id(id)?;
    let current = call(reqwest::Method::GET, &format!("/tickets/{id}"), None).await?;
    let current = current.get("ticket").unwrap_or(&current);
    let status = current.get("status").and_then(Value::as_str).unwrap_or("");
    if status != "pending" || id_of(current.get("userId")).is_some() {
        return Err("Someone already took that ticket.".into());
    }
    let (_, _, account) = session().ok_or("Not signed in")?;
    if account.cloud {
        call(
            reqwest::Method::POST,
            &format!("/tickets/{id}/transfer"),
            Some(json!({ "userId": account.user_id })),
        )
        .await?;
    } else {
        let user: Value = account.user_id.parse::<i64>().map(Value::from).unwrap_or(Value::from(account.user_id.clone()));
        call(reqwest::Method::PUT, &format!("/tickets/{id}"), Some(json!({ "status": "open", "userId": user }))).await?;
    }
    Ok(())
}

/// Puts a ticket Coucou accepted back in the queue (self-hosted only).
pub async fn undo(id: &str) -> Result<(), String> {
    valid_id(id)?;
    if session().map(|(_, _, a)| a.cloud).unwrap_or(false) {
        return Err("whaticket.com can't put a ticket back in the queue — open it in WhaTicket.".into());
    }
    let recent = MEMORY.lock().unwrap().accepted.get(id).map(|t| t.elapsed() < UNDO_WINDOW).unwrap_or(false);
    if !recent {
        return Err("Too late to undo — reopen it in WhaTicket.".into());
    }
    call(
        reqwest::Method::PUT,
        &format!("/tickets/{id}"),
        Some(json!({ "status": "pending", "userId": Value::Null })),
    )
    .await?;
    MEMORY.lock().unwrap().accepted.remove(id);
    Ok(())
}

/// The web app's address for a ticket.
pub fn web_url(id: Option<&str>) -> Option<String> {
    let base = secrets::get("whaticket-web-url").and_then(|u| normalise_base(&u)).or_else(|| match credentials()? {
        Credentials::Cloud { .. } => Some(CLOUD_WEB.to_string()),
        Credentials::Community { base, .. } => Some(base),
    })?;
    Some(match id.filter(|i| valid_id(i).is_ok()) {
        Some(id) => format!("{base}/tickets/{id}"),
        None => format!("{base}/tickets"),
    })
}

// ── Polling ───────────────────────────────────────────────────────────────────

struct Rules {
    auto_accept: bool,
    queues: Vec<String>,
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
    let (pending, mut mine) = match fetch(&account).await {
        Ok(lists) => lists,
        Err(e) => return error(&app, e),
    };
    let names: Vec<Queue> = account.all_queues.iter().chain(account.queues.iter()).cloned().collect();

    let rules = rules(&app);
    let mut event: Option<IntegrationEvent> = None;
    let mut accepted_now = false;

    // New tickets in the queue.
    let ids: HashSet<String> = pending.iter().filter_map(|t| id_of(t.get("id"))).collect();
    let fresh: Vec<&Value> = {
        let mut memory = MEMORY.lock().unwrap();
        let fresh = match &memory.pending {
            None => Vec::new(), // first poll: fill the card silently
            Some(seen) => pending
                .iter()
                .filter(|t| id_of(t.get("id")).map(|id| !seen.contains(&id)).unwrap_or(false))
                .collect(),
        };
        memory.pending = Some(ids);
        fresh
    };
    for t in fresh {
        let Some(view) = ticket_view(t, &names) else { continue };
        let id = view["id"].as_str().unwrap_or_default().to_string();
        let can = rules.auto_accept
            && !rules.dnd
            && !view["isGroup"].as_bool().unwrap_or(false)
            && queue_allowed(view["queueId"].as_str(), &rules.queues)
            && in_hours(&rules.hours, minutes_now());
        if can {
            match accept(&id).await {
                Ok(()) => {
                    log::line(format!("whaticket: auto-accepted ticket {id}"));
                    accepted_now = true;
                    if !account.cloud {
                        MEMORY.lock().unwrap().accepted.insert(id.clone(), Instant::now());
                    }
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
    // Tickets accepted just now are mine already: list them on the card.
    if accepted_now {
        if let Ok((_, now_mine)) = fetch(&account).await {
            mine = now_mine;
        }
    }

    // New messages on my tickets.
    {
        let mut memory = MEMORY.lock().unwrap();
        let first = !memory.mine_ready;
        memory.mine_ready = true;
        let mut next = HashMap::new();
        for t in &mine {
            let Some(view) = ticket_view(t, &names) else { continue };
            let id = view["id"].as_str().unwrap_or_default().to_string();
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

    let undoable: Vec<String> = MEMORY.lock().unwrap().accepted.keys().cloned().collect();
    emit(&app, IntegrationUpdate {
        id: ID,
        data: json!({
            "user": account.name,
            "cloud": account.cloud,
            "pending": pending.iter().take(8).filter_map(|t| ticket_view(t, &names)).collect::<Vec<_>>(),
            "pendingCount": pending.len(),
            "mine": mine.iter().take(8).filter_map(|t| ticket_view(t, &names)).collect::<Vec<_>>(),
            "mineCount": mine.len(),
            "autoAccept": rules.auto_accept,
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
        assert_eq!(cloud_base(None), "https://api.whaticket.com/api/v1");
        assert_eq!(cloud_base(Some("https://api.whaticket.com/")), "https://api.whaticket.com/api/v1");
        assert_eq!(cloud_base(Some("https://api.whaticket.com/api/v1")), "https://api.whaticket.com/api/v1");
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
        let mine = vec!["a".to_string(), "b".to_string()];
        assert!(queue_allowed(Some("x"), &[]));
        assert!(queue_allowed(None, &[]));
        assert!(queue_allowed(Some("b"), &mine));
        assert!(!queue_allowed(Some("c"), &mine));
        assert!(!queue_allowed(None, &mine));
    }

    #[test]
    fn self_hosted_login_and_tickets() {
        let login = json!({ "token": "t", "user": { "id": 7, "name": "Ana", "queues": [ { "id": 1, "name": "Sales", "color": "#f00" } ] } });
        let (token, account) = parse_account(&login).unwrap();
        assert_eq!(token, "t");
        assert_eq!(account.user_id, "7");
        assert_eq!(account.queues[0].id, "1");

        let t = json!({ "id": 5, "status": "pending", "unreadMessages": 2, "lastMessage": "Hola", "queueId": 1,
            "contact": { "name": "", "number": "5491100" }, "queue": { "id": 1, "name": "Sales", "color": "#f00" }, "userId": null });
        let v = ticket_view(&t, &[]).unwrap();
        assert_eq!(v["id"], "5");
        assert_eq!(v["name"], "5491100");
        assert_eq!(v["queue"], "Sales");
        assert_eq!(v["queueId"], "1");
        assert!(v["userId"].is_null());
    }

    #[test]
    fn cloud_tickets_users_and_permissions() {
        let queues = vec![Queue { id: "q-1".into(), name: "Soporte".into(), color: "#0af".into() }];
        let t = json!({ "id": "6b1c-uuid", "status": "pending", "queueId": "q-1", "userId": null,
            "contact": { "name": "María" }, "lastMessage": "Hola" });
        let v = ticket_view(&t, &queues).unwrap();
        assert_eq!(v["id"], "6b1c-uuid");
        assert_eq!(v["queue"], "Soporte");
        assert_eq!(v["queueColor"], "#0af");

        let users = json!({ "users": [ { "id": "u-1", "email": "Ana@Empresa.com", "name": "Ana" } ] });
        assert_eq!(find_user(&users, "ana@empresa.com ").unwrap()["id"], "u-1");
        assert!(find_user(&users, "otro@x.com").is_none());

        let me = json!({ "name": "Coucou", "permissions": ["tickets:view", "tickets:viewAll"] });
        assert_eq!(missing_permissions(&me), vec!["tickets:viewPending", "tickets:transfer", "users:view"]);
        assert!(missing_permissions(&json!({ "name": "x" })).is_empty());
        assert_eq!(list_of(&json!([1, 2]), "queues").len(), 2);
    }

    #[test]
    fn errors_name_the_cause() {
        assert!(api_error(401, &json!({ "error": "ERR_SHOULD_LOGIN_BY_AUTH_CODE" })).contains("API token"));
        assert!(api_error(429, &json!({ "raw": "429 Too Many Requests" })).contains("too many"));
        assert_eq!(api_error(500, &json!({ "error": "ERR_X" })), "WhaTicket answered 500: ERR_X");
    }

    #[test]
    fn encodes() {
        assert_eq!(urlencode("[1,2]"), "%5B1%2C2%5D");
    }
}
