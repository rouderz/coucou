// AliExpress: your orders grouped by the box they ship in, and one invoice per box.
// Same behaviour as NotchBuddy/Sources/App/AliExpress.swift.
//
// Coucou for AliExpress, its own browser extension (extensions/aliexpress), reads your own AliExpress
// order pages, groups the orders by tracking number and checks in here (kind "aliexpress").
// Coucou shows the packages and answers with what to do — make a package's invoice, export a
// CSV, refresh — which the extension does in the browser (files in Downloads/Coucou/AliExpress).
// Coucou makes no AliExpress requests and keeps no AliExpress credentials; the buyer details for
// the invoices are the user's own, in the credential store ("aliexpress-buyer").

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};
use tauri::{AppHandle, Manager};

use crate::integrations::{emit, IntegrationEvent, IntegrationUpdate};

pub const ID: &str = "integration_aliexpress";

#[derive(Default)]
struct State {
    queued: Vec<Value>,
    busy: HashSet<String>,
    seen_files: HashSet<String>,
    last: Option<Value>,
}

static STATE: std::sync::LazyLock<Mutex<State>> = std::sync::LazyLock::new(|| Mutex::new(State::default()));

/// Tracking numbers are letters and digits; nothing else goes back to the browser.
pub fn valid_tracking(s: &str) -> bool {
    !s.is_empty() && s.len() <= 60 && s.chars().all(|c| c.is_ascii_alphanumeric())
}

/// The packages of a check-in, keeping only well-formed ones and the fields the card shows.
pub fn packages(msg: &Value) -> Vec<Value> {
    let s = |p: &Value, k: &str, max: usize| p.get(k).and_then(Value::as_str).unwrap_or("").chars().take(max).collect::<String>();
    msg.get("packages")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter(|p| p.get("tracking").and_then(Value::as_str).map(valid_tracking).unwrap_or(false))
                .take(200)
                .map(|p| {
                    let orders: Vec<Value> = p.get("orders").and_then(Value::as_array).cloned().unwrap_or_default()
                        .into_iter()
                        .filter(|o| o.as_str().map(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit())).unwrap_or(false))
                        .take(50)
                        .collect();
                    json!({
                        "tracking": s(p, "tracking", 60), "carrier": s(p, "carrier", 60), "status": s(p, "status", 120),
                        "lastEvent": s(p, "lastEvent", 200), "lastTime": s(p, "lastTime", 40), "orders": orders,
                        "items": p.get("items").and_then(Value::as_u64).unwrap_or(0),
                        "total": p.get("total").and_then(Value::as_f64).unwrap_or(0.0),
                        "currency": { let c = s(p, "currency", 4); if c.is_empty() { "USD".to_string() } else { c } },
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn delivered(status: &str) -> bool {
    let s = status.to_lowercase();
    s.contains("deliver") || s.contains("entreg")
}

fn enabled(app: &AppHandle) -> bool {
    app.try_state::<crate::Shared>()
        .map(|shared| shared.settings.lock().unwrap().active_integrations.iter().any(|x| x == ID))
        .unwrap_or(false)
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// One check-in from the extension; the answer carries the queued commands.
pub fn handle_browser(app: &AppHandle, msg: &Value) -> Value {
    if !enabled(app) {
        return json!({ "commands": [], "interval": 600 });
    }
    let list = packages(msg);
    let mut st = STATE.lock().unwrap();
    let before: Vec<(String, String)> = st
        .last
        .as_ref()
        .and_then(|d| d.get("packages").and_then(Value::as_array).cloned())
        .unwrap_or_default()
        .iter()
        .map(|p| (p["tracking"].as_str().unwrap_or("").to_string(), p["status"].as_str().unwrap_or("").to_string()))
        .collect();
    let mut event = None;
    for p in &list {
        let tracking = p["tracking"].as_str().unwrap_or("");
        let now = p["status"].as_str().unwrap_or("");
        if let Some((_, old)) = before.iter().find(|(t, _)| t == tracking) {
            if delivered(now) && !delivered(old) {
                event = Some(IntegrationEvent {
                    success: true,
                    label: format!("Package delivered · {}", p["carrier"].as_str().unwrap_or("")),
                    detail: Some(tracking.to_string()),
                });
            }
        }
    }
    let mut last_file = st.last.as_ref().and_then(|d| d.get("lastFile").cloned()).unwrap_or(Value::Null);
    for f in msg.get("files").and_then(Value::as_array).cloned().unwrap_or_default() {
        let Some(path) = f.get("path").and_then(Value::as_str) else { continue };
        if st.seen_files.insert(path.to_string()) {
            let key = f.get("tracking").and_then(Value::as_str).map(str::to_string)
                .unwrap_or_else(|| if f.get("csv").and_then(Value::as_bool).unwrap_or(false) { "csv".into() } else { String::new() });
            st.busy.remove(&key);
            last_file = json!({ "path": path.chars().take(500).collect::<String>() });
        }
    }
    let commands: Vec<Value> = st.queued.drain(..).collect();
    let data = json!({
        "packages": list,
        "orders": msg.get("orders").and_then(Value::as_u64).unwrap_or(0),
        "syncing": msg.get("syncing").and_then(Value::as_bool).unwrap_or(false),
        "seenAt": now_ms(),
        "busy": st.busy.iter().cloned().collect::<Vec<_>>(),
        "lastFile": last_file,
    });
    st.last = Some(data.clone());
    drop(st);
    emit(app, IntegrationUpdate { id: ID, data, error: None, event });
    json!({ "commands": commands, "interval": if commands.is_empty() { 30 } else { 15 } })
}

fn republish(app: &AppHandle, st: &State) {
    if let Some(mut data) = st.last.clone() {
        data["busy"] = json!(st.busy.iter().cloned().collect::<Vec<_>>());
        emit(app, IntegrationUpdate { id: ID, data, error: None, event: None });
    }
}

/// Invoice of one box, on a click: done by the extension at its next check-in.
pub fn queue_invoice(app: &AppHandle, tracking: &str, lang: &str) -> Result<(), String> {
    if !valid_tracking(tracking) {
        return Err("Unknown package".into());
    }
    let buyer: Value = crate::secrets::get("aliexpress-buyer")
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_else(|| json!({}));
    let mut st = STATE.lock().unwrap();
    st.queued.push(json!({ "op": "invoice", "tracking": tracking, "buyer": buyer, "lang": if lang == "es" { "es" } else { "en" } }));
    st.busy.insert(tracking.to_string());
    republish(app, &st);
    Ok(())
}

pub fn queue_csv(app: &AppHandle) {
    let mut st = STATE.lock().unwrap();
    st.queued.push(json!({ "op": "csv" }));
    st.busy.insert("csv".into());
    republish(app, &st);
}

pub fn queue_sync() {
    STATE.lock().unwrap().queued.push(json!({ "op": "sync" }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packages_are_checked_and_trimmed() {
        let msg = json!({ "packages": [
            { "tracking": "GFUS01074935269124", "carrier": "GOFO INC.", "orders": ["8214937669763641", "x/y"], "items": 3, "total": 31.58 },
            { "tracking": "../etc", "carrier": "bad" },
            { "carrier": "no tracking" },
        ]});
        let list = packages(&msg);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0]["orders"], json!(["8214937669763641"]));
        assert_eq!(list[0]["currency"], "USD");
        assert_eq!(list[0]["total"], 31.58);
    }

    #[test]
    fn delivered_in_english_or_spanish() {
        assert!(delivered("Package delivered."));
        assert!(delivered("Entregado"));
        assert!(!delivered("In transit"));
        assert!(valid_tracking("LP00123456789CN"));
        assert!(!valid_tracking("a b"));
    }
}
