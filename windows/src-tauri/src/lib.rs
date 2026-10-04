// Coucou for Windows — app wiring and the commands the island calls.

mod claude;
mod alerts;
mod claude_code;
mod codex;
mod editors;
mod files;
mod google;
mod hooks;
mod inbox;
mod integrations;
mod island;
mod linear;
mod log;
mod pipe;
mod provider;
mod platform;
mod secrets;
mod settings;
mod skills;
mod tray;
mod voice;
mod whaticket;
mod browser;

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_autostart::{ManagerExt, MacosLauncher};

use claude::{Chat, ChatContext, ChatReply};
use claude_code::{ClaudeCodeChat, ClaudeCodeStatus};
use editors::EditorInfo;
use files::DroppedFile;
use hooks::{HookPreview, HookStatus};
use island::{PollGate, ScreenInfo};
use pipe::Pending;
use settings::Settings;

pub struct Shared {
    pub settings: Mutex<Settings>,
    pub gate: Arc<PollGate>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BootInfo {
    settings: Settings,
    screen: ScreenInfo,
    version: String,
    hook_path: String,
    /// "windows" or "linux".
    platform: String,
    /// "poll": Rust sends `cursor` events. "dom": the page tracks the pointer itself (Wayland).
    pointer: String,
}

#[tauri::command]
fn boot(app: AppHandle, shared: State<Shared>) -> BootInfo {
    let mut settings = shared.settings.lock().unwrap().clone();
    // The real state of ~/.claude/settings.json wins over whatever we stored.
    settings.hooks_installed = hooks::status().installed;
    let screen = island::screen_info(&app, &settings.screen);
    BootInfo {
        settings,
        screen,
        version: env!("CARGO_PKG_VERSION").to_string(),
        hook_path: settings::hook_exe_path().to_string_lossy().to_string(),
        platform: platform::PLATFORM.to_string(),
        pointer: platform::pointer_mode().to_string(),
    }
}

#[tauri::command]
fn save_settings(app: AppHandle, shared: State<Shared>, settings: Settings) {
    let (screen_changed, autostart_changed) = {
        let mut current = shared.settings.lock().unwrap();
        // The idle notch changes the hidden window's size too.
        let screen_changed = current.screen != settings.screen || current.idle_notch != settings.idle_notch;
        shared.gate.idle_notch.store(settings.idle_notch, Ordering::Relaxed);
        let autostart_changed = current.autostart != settings.autostart;
        *current = settings.clone();
        (screen_changed, autostart_changed)
    };
    if let Err(err) = settings::save(&settings) {
        eprintln!("[coucou] could not save settings: {err}");
    }
    if autostart_changed {
        let manager = app.autolaunch();
        let result = if settings.autostart { manager.enable() } else { manager.disable() };
        if let Err(err) = result {
            eprintln!("[coucou] autostart: {err}");
        }
    }
    if screen_changed {
        let collapsed = shared.gate.collapsed.load(Ordering::Relaxed);
        island::apply_geometry(&app, &settings.screen, collapsed);
    }
    // Keep the other window in step (island ⇄ settings window).
    let _ = app.emit("settings-changed", settings);
}

/// Hidden island → shrink the window to the invisible wake strip and park the
/// cursor poll; anything else → full panel and 60 Hz polling.
#[tauri::command]
fn set_collapsed(app: AppHandle, shared: State<Shared>, collapsed: bool) {
    let (pref, idle_notch) = {
        let s = shared.settings.lock().unwrap();
        (s.screen.clone(), s.idle_notch)
    };
    shared.gate.idle_notch.store(idle_notch, Ordering::Relaxed);
    shared.gate.collapsed.store(collapsed, Ordering::Relaxed);
    island::apply_geometry(&app, &pref, collapsed);
    // The wake strip must always take the mouse, and a resize invalidates the flag.
    island::set_ignore_cursor(&app, false);
    shared.gate.forget_ignore_state();
    shared.gate.set_active(!collapsed);
    island::apply_input_region(&app, &shared.gate);
}

/// The front end pushes the island shape; Rust decides click-through from it.
#[tauri::command]
fn set_island_rect(app: AppHandle, shared: State<Shared>, x: f64, y: f64, width: f64, height: f64) {
    shared.gate.set_rect(island::IslandRect { x, y, w: width, h: height });
    island::apply_input_region(&app, &shared.gate);
}

#[tauri::command]
fn focus_window(app: AppHandle, focused: bool) {
    let Some(win) = island::window(&app) else { return };
    island::set_activating(&win, focused);
    if focused {
        let _ = win.set_focus();
    }
}

#[tauri::command]
fn reposition(app: AppHandle, shared: State<Shared>) {
    let pref = shared.settings.lock().unwrap().screen.clone();
    let collapsed = shared.gate.collapsed.load(Ordering::Relaxed);
    island::apply_geometry(&app, &pref, collapsed);
}

#[tauri::command]
fn open_url(url: String) {
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return;
    }
    platform::open_url(&url);
}

/// "Open terminal" opens the working folder in the editor picked in Settings
/// (or the first one installed), and in the file manager otherwise.
#[tauri::command]
fn open_in_vscode(shared: State<Shared>, path: Option<String>) -> bool {
    let preferred = shared.settings.lock().unwrap().editor.clone();
    editors::open(path.as_deref().filter(|p| !p.is_empty()), &preferred)
}

/// The editors Settings can offer.
#[tauri::command]
fn editors_installed() -> Vec<EditorInfo> {
    editors::installed()
}

#[tauri::command]
fn quit_app(app: AppHandle) {
    app.exit(0);
}

/// Tray → Pause. Paused means paused: the pollers stop talking to the network,
/// not just the island stopping showing things.
#[tauri::command]
fn set_paused(paused: bool) {
    integrations::set_paused(paused);
}

// ── Claude Code hooks ─────────────────────────────────────────────────────────

#[tauri::command]
fn hooks_status() -> HookStatus {
    hooks::status()
}

/// Returns the diff the user has to look at before anything is written.
#[tauri::command]
fn hooks_preview(install: bool) -> Result<HookPreview, String> {
    hooks::preview(install)
}

/// Only ever called from an explicit click in the settings window.
#[tauri::command]
fn hooks_apply(
    app: AppHandle,
    shared: State<Shared>,
    install: bool,
    fingerprint: String,
) -> Result<String, String> {
    // The fingerprint comes from the preview the user actually looked at, so a
    // settings.json that changed in between is refused rather than overwritten.
    let backup = hooks::write(install, &fingerprint)?;
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.hooks_installed = install;
        let _ = settings::save(&current);
        current.clone()
    };
    let _ = app.emit("settings-changed", updated);
    Ok(backup)
}

#[tauri::command]
fn approval_decision(app: AppHandle, request_id: String, decision: String) {
    pipe::answer(&app, &request_id, &decision);
}

/// The island has the card on screen, so the long wait for a human may begin.
/// Until this arrives the relay only waits a few hundred milliseconds, which is
/// what stops a paused or unresponsive island from freezing Claude Code.
#[tauri::command]
fn approval_ack(app: AppHandle, request_id: String) {
    pipe::acknowledge(&app, &request_id);
}

/// Nobody can act on this request — the island is paused, or another card is
/// already up. Claude Code falls back to asking in the terminal immediately.
#[tauri::command]
fn approval_decline(app: AppHandle, request_id: String) {
    pipe::decline(&app, &request_id);
}

// ── Chat, files and secrets ───────────────────────────────────────────────────

/// One chat turn, through the engine picked in Settings. The API key and any
/// file bytes stay on the Rust side.
#[tauri::command]
async fn chat_send(
    shared: State<'_, Shared>,
    chat: State<'_, Chat>,
    code_chat: State<'_, ClaudeCodeChat>,
    provider_chat: State<'_, provider::ProviderChat>,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let s = shared.settings.lock().unwrap().clone();
    match s.chat_engine.as_str() {
        "claude-code" => claude_code::send(&code_chat, &s.model, query, context).await,
        "provider" => {
            let cfg = provider::config(&s.provider_id, &s.provider_base_url, &s.provider_model);
            provider::send(&provider_chat, cfg, query, context).await
        }
        _ => claude::send(&chat, &s.model, query, context).await,
    }
}

#[tauri::command]
fn chat_reset(chat: State<Chat>, code_chat: State<ClaudeCodeChat>, provider_chat: State<provider::ProviderChat>) {
    chat.reset();
    code_chat.reset();
    provider_chat.reset();
}

#[derive(serde::Deserialize)]
struct SavedTurn {
    user: bool,
    text: String,
}

/// Picks a saved chat back up in every engine (text for the API and providers,
/// the session for Claude Code).
#[tauri::command]
fn chat_restore(
    chat: State<Chat>,
    code_chat: State<ClaudeCodeChat>,
    provider_chat: State<provider::ProviderChat>,
    messages: Vec<SavedTurn>,
    session_id: Option<String>,
    work_dir: Option<String>,
) {
    let turns: Vec<(bool, String)> = messages.into_iter().map(|m| (m.user, m.text)).collect();
    chat.restore(&turns);
    provider_chat.restore(&turns);
    code_chat.restore(session_id, work_dir);
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ChatSessionInfo {
    session_id: Option<String>,
    work_dir: Option<String>,
}

/// What to save with a chat so Claude Code can resume it.
#[tauri::command]
fn chat_session_info(code_chat: State<ClaudeCodeChat>) -> ChatSessionInfo {
    let (session_id, work_dir) = code_chat.snapshot();
    ChatSessionInfo { session_id, work_dir }
}

fn chats_path() -> std::path::PathBuf {
    settings::local_dir().join("chats.json")
}

/// Saved chats (the newest 50), kept on this computer only.
#[tauri::command]
fn chats_load() -> serde_json::Value {
    std::fs::read(chats_path())
        .ok()
        .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
        .filter(|v| v.is_array())
        .unwrap_or_else(|| serde_json::json!([]))
}

#[tauri::command]
fn chats_save(chats: serde_json::Value) -> Result<(), String> {
    let list = chats.as_array().ok_or("not a list")?;
    let kept: Vec<serde_json::Value> = list.iter().take(50).cloned().collect();
    let dir = settings::local_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let text = serde_json::to_vec(&kept).map_err(|e| e.to_string())?;
    let temp = chats_path().with_extension("json.tmp");
    std::fs::write(&temp, text).map_err(|e| e.to_string())?;
    std::fs::rename(&temp, chats_path()).map_err(|e| e.to_string())
}

/// A deleted chat takes its Claude Code folder with it — only ever one of ours.
#[tauri::command]
fn chat_delete_dir(dir: String) {
    let root = settings::local_dir().join("chats");
    let path = std::path::PathBuf::from(&dir);
    if let (Ok(root), Ok(path)) = (root.canonicalize(), path.canonicalize()) {
        if path.starts_with(&root) && path != root {
            let _ = std::fs::remove_dir_all(path);
        }
    }
}

/// Push-to-talk: one spoken question, as text (Windows' own speech recognition).
#[tauri::command]
async fn voice_listen() -> Result<String, String> {
    voice::listen().await
}

#[tauri::command]
fn voice_available() -> bool {
    voice::can_listen()
}

#[tauri::command]
fn provider_presets() -> Vec<provider::Preset> {
    provider::PRESETS.to_vec()
}

#[tauri::command]
async fn provider_models(shared: State<'_, Shared>) -> Result<Vec<String>, String> {
    let s = shared.settings.lock().unwrap().clone();
    provider::list_models(provider::config(&s.provider_id, &s.provider_base_url, &s.provider_model)).await
}

// ── Linear, inbox, phone alerts, updates, shortcuts (phase 2 of parity) ──────

// ── WhaTicket ─────────────────────────────────────────────────────────────────

/// Accept from the island card — only ever on a click. The browser extension runs
/// it on its next check-in (a few seconds), with the user's own whaticket.com session.
#[tauri::command]
fn whaticket_accept(app: AppHandle, id: String) -> Result<(), String> {
    whaticket::queue_accept(&app, &id)?;
    log::line(format!("whaticket: accept queued for ticket {id}"));
    Ok(())
}

#[tauri::command]
fn whaticket_open(id: Option<String>) {
    open_url(whaticket::web_url(id.as_deref()));
}

#[tauri::command]
fn whaticket_queues() -> serde_json::Value {
    whaticket::queues()
}

/// The local arrival / accept log, for Settings → WhaTicket → Stats.
#[tauri::command]
fn whaticket_stats() -> serde_json::Value {
    whaticket::stats_events()
}

/// Settings → WhaTicket → Reset stats, after the user confirmed.
#[tauri::command]
fn whaticket_stats_reset() {
    whaticket::stats_reset();
}

/// Writes the browser extension and its native-messaging host, and registers the host
/// with every Chromium browser found. Returns where the unpacked extension lives.
#[tauri::command]
fn browser_install() -> Result<browser::Status, String> {
    browser::install()
}

#[tauri::command]
fn browser_status() -> browser::Status {
    browser::status()
}

#[tauri::command]
fn browser_reveal() {
    browser::reveal();
}

// ── Google (Gmail, Drive) ─────────────────────────────────────────────────────

/// Opens Google's consent page and waits for the answer; returns the account's email.
#[tauri::command]
async fn google_connect(app: AppHandle) -> Result<String, String> {
    let email = google::connect().await?;
    google::poll(app).await;
    Ok(email)
}

#[tauri::command]
async fn google_disconnect() {
    google::disconnect().await;
    log::line("google: disconnected");
}

#[tauri::command]
fn google_connected() -> bool {
    google::connected()
}

/// A mail as a text file, attached to the chat on a click.
#[tauri::command]
async fn gmail_attach(id: String) -> Result<files::DroppedFile, String> {
    google::mail_to_file(&id).await
}

#[tauri::command]
async fn drive_search(text: String) -> Result<Vec<google::DriveFile>, String> {
    google::drive_search(&text).await
}

/// A Drive file (Docs / Sheets / Slides exported as text / CSV) attached to the chat.
#[tauri::command]
async fn drive_attach(id: String, name: String, mime: String) -> Result<files::DroppedFile, String> {
    google::drive_to_file(&id, &name, &mime).await
}

// ── Skills ────────────────────────────────────────────────────────────────────

#[tauri::command]
fn skills_list() -> Vec<skills::Skill> {
    skills::list()
}

#[tauri::command]
fn skills_targets() -> Vec<skills::Target> {
    skills::targets()
}

#[tauri::command]
fn skill_read(path: String) -> Result<skills::SkillText, String> {
    skills::read(&path)
}

#[tauri::command]
fn skill_set_enabled(path: String, enabled: bool) -> Result<(), String> {
    skills::set_enabled(&path, enabled)
}

/// Stages a folder, .zip / .skill file or GitHub link and shows what it holds.
#[tauri::command]
async fn skills_preview(source: String, target: String) -> Result<skills::Preview, String> {
    skills::preview(&source, &target).await
}

/// Installs what the preview showed — only ever after the user clicked Install.
#[tauri::command]
fn skills_install(token: String, replace: bool) -> Result<Vec<String>, String> {
    let installed = skills::install(&token, replace)?;
    log::line(format!("skills installed: {}", installed.join(", ")));
    Ok(installed)
}

#[tauri::command]
fn skill_create(shared: State<Shared>, name: String, target: String) -> Result<String, String> {
    let dir = skills::create(&name, &target)?;
    let preferred = shared.settings.lock().unwrap().editor.clone();
    editors::open(Some(&dir), &preferred);
    Ok(dir)
}

/// Shows a skill's folder in Explorer / the file manager.
#[tauri::command]
fn skill_reveal(path: String) {
    if std::path::Path::new(&path).is_dir() {
        platform::open_folder(&path);
    }
}

/// The Linear issue a session's git branch names, if any.
#[tauri::command]
async fn linear_issue_for_folder(cwd: String) -> Option<linear::LinearIssue> {
    linear::issue_for_folder(&cwd).await
}

/// Posts a session's timeline on its Linear issue — only from an explicit click.
#[tauri::command]
async fn linear_comment(issue_id: String, body: String) -> Result<(), String> {
    linear::comment(&issue_id, &body).await
}

#[tauri::command]
async fn inbox_refresh(app: AppHandle) {
    inbox::refresh(app).await;
}

/// Opened or dismissed: marked read on GitHub / Linear.
#[tauri::command]
async fn inbox_dismiss(app: AppHandle, id: String) {
    inbox::dismiss(app, id).await;
}

/// An approval still waiting: tell the phone (if set up, and if away when asked to).
#[tauri::command]
async fn phone_alert(
    shared: State<'_, Shared>,
    title: String,
    message: String,
    urgent: bool,
) -> Result<bool, String> {
    let s = shared.settings.lock().unwrap().clone();
    if !s.phone_alerts || s.ntfy_topic.is_empty() {
        return Ok(false);
    }
    if s.phone_only_when_away && !alerts::user_is_away() {
        return Ok(false);
    }
    let (priority, tags) = if urgent { ("urgent", "warning") } else { ("high", "robot") };
    alerts::send(&s.ntfy_server, &s.ntfy_topic, &title, &message, priority, tags).await?;
    Ok(true)
}

#[tauri::command]
async fn phone_test(server: String, topic: String) -> Result<(), String> {
    alerts::send(&server, &topic, "Coucou is connected",
        "You'll get approvals here when you're away from the computer.", "default", "white_check_mark").await
}

#[tauri::command]
fn new_ntfy_topic() -> String {
    alerts::new_topic()
}

#[tauri::command]
async fn check_update() -> Result<alerts::UpdateInfo, String> {
    alerts::check().await
}

/// The key release builds are signed with (tauri.conf.json → plugins.updater.pubkey);
/// empty until scripts/updater-keys.sh has been run.
fn updater_pubkey(app: &AppHandle) -> String {
    app.config()
        .plugins
        .0
        .get("updater")
        .and_then(|u| u.get("pubkey"))
        .and_then(|k| k.as_str())
        .unwrap_or("")
        .to_string()
}

/// Can this copy update itself? Signed releases, and an installer that can be
/// replaced: Windows, or Linux running as an AppImage (.deb / .rpm go through the
/// system's package manager instead).
#[tauri::command]
fn update_can_install(app: AppHandle) -> bool {
    !updater_pubkey(&app).is_empty() && (cfg!(windows) || std::env::var_os("APPIMAGE").is_some())
}

/// Downloads the new version, checks its signature, installs it and restarts.
#[tauri::command]
async fn update_install(app: AppHandle) -> Result<(), String> {
    use tauri_plugin_updater::UpdaterExt;
    let update = app
        .updater()
        .map_err(|e| e.to_string())?
        .check()
        .await
        .map_err(|e| e.to_string())?
        .ok_or("You're already up to date.")?;
    log::line(format!("updating to {}", update.version));
    update
        .download_and_install(|_, _| {}, || {})
        .await
        .map_err(|e| format!("The update couldn't be installed: {e}"))?;
    app.restart()
}

/// ⌥⏎ / ⌥⌫ answer the approval on screen from any app (Alt+Enter / Alt+Backspace
/// here). Registered only while a card is up, so they never steal those keys otherwise.
#[tauri::command]
fn approval_shortcuts(app: AppHandle, armed: bool) {
    use tauri_plugin_global_shortcut::GlobalShortcutExt;
    let shortcuts = approval_keys();
    let gs = app.global_shortcut();
    for s in shortcuts {
        let result = if armed { gs.register(s.clone()) } else { gs.unregister(s.clone()) };
        if let Err(err) = result {
            if armed {
                log::line(format!("shortcut {s:?}: {err}"));
            }
        }
    }
}

fn approval_keys() -> [tauri_plugin_global_shortcut::Shortcut; 2] {
    use tauri_plugin_global_shortcut::{Code, Modifiers, Shortcut};
    [
        Shortcut::new(Some(Modifiers::ALT), Code::Enter),
        Shortcut::new(Some(Modifiers::ALT), Code::Backspace),
    ]
}

/// Codex CLI hooks in ~/.codex/hooks.json (#44 on macOS).
#[tauri::command]
fn codex_status() -> codex::CodexStatus {
    codex::status()
}

/// Only ever called from an explicit click in Settings.
#[tauri::command]
fn codex_install(install: bool) -> Result<(), String> {
    if install { codex::install() } else { codex::uninstall() }
}

/// Whether the subscription chat can work: is `claude` installed?
#[tauri::command]
fn claude_code_status() -> ClaudeCodeStatus {
    claude_code::status()
}

/// Copies a dropped file into the inbox and reports its name back.
#[tauri::command]
fn ingest_file(path: String) -> Result<DroppedFile, String> {
    files::ingest(&path)
}

/// The island may only ask whether a key exists — never read it.
#[tauri::command]
fn secret_present(key: String) -> bool {
    secrets::present(&key)
}

#[tauri::command]
fn secret_set(key: String, value: String) -> Result<(), String> {
    secrets::set(&key, &value)
}

#[tauri::command]
fn secret_clear(key: String) -> Result<(), String> {
    secrets::clear(&key)
}

/// Opens the configured n8n instance — the URL lives in the Credential Manager.
#[tauri::command]
fn open_n8n() {
    if let Some(url) = secrets::get("n8n-url") {
        open_url(url);
    }
}

/// GitHub through the GitHub CLI when no token is saved (#75, macOS #53).
#[tauri::command]
async fn github_cli_status() -> integrations::GhStatus {
    integrations::gh_status().await
}

/// Refresh buttons in the integration cards.
#[tauri::command]
async fn refresh_integration(app: AppHandle, id: String) {
    integrations::poll_once(app, &id).await;
}

/// Lets the island write to the same log as the Rust side.
#[tauri::command]
fn log_line(message: String) {
    log::line(format!("ui  {message}"));
}

// ── Settings window ───────────────────────────────────────────────────────────

/// WebView2 allows exactly one browser environment per app, and its options are
/// fixed by whichever webview is created first. Every window must therefore ask
/// for the *same* arguments as the island (see `additionalBrowserArgs` in
/// tauri.conf.json) — a mismatch makes the second window come up blank, with no
/// error anywhere.
const BROWSER_ARGS: &str = "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection --autoplay-policy=no-user-gesture-required";

/// In a dev build the pages are served by Vite, so the second window needs the
/// absolute dev URL; a bundled build resolves it inside the app bundle.
fn settings_page_url(app: &AppHandle) -> WebviewUrl {
    #[cfg(dev)]
    if let Some(mut base) = app.config().build.dev_url.clone() {
        base.set_path("/settings.html");
        return WebviewUrl::External(base);
    }
    let _ = app;
    WebviewUrl::App("settings.html".into())
}

/// The settings window is created hidden at launch and only ever shown and
/// hidden afterwards. A WebView2 window created later — on the main thread or
/// not — silently comes up blank in this app, so the window that works is the
/// one that exists before the island's webview does.
fn create_settings_window(app: &AppHandle) {
    let url = settings_page_url(app);
    match WebviewWindowBuilder::new(app, "settings", url)
        .additional_browser_args(BROWSER_ARGS)
        .title("Settings — Coucou")
        .inner_size(560.0, 680.0)
        .min_inner_size(460.0, 480.0)
        .resizable(true)
        .visible(false)
        .center()
        .build()
    {
        Ok(win) => {
            // Closing it must only hide it, or it could never be reopened.
            let hidden = win.clone();
            win.on_window_event(move |event| {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = hidden.hide();
                }
            });
        }
        Err(err) => log::line(format!("settings window failed: {err}")),
    }
}

pub fn show_settings_window(app: &AppHandle) {
    let Some(win) = app.get_webview_window("settings") else {
        log::line("settings window missing");
        return;
    };
    let _ = win.unminimize();
    let _ = win.show();
    let _ = win.set_focus();
}

#[tauri::command]
fn open_settings_window(app: AppHandle) {
    show_settings_window(&app);
}

pub fn run() {
    #[cfg(target_os = "linux")]
    platform::choose_backend();
    let loaded = settings::load();
    let gate = Arc::new(PollGate::new());

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            let _ = app.emit_to(island::WINDOW_LABEL, "tray", "open".to_string());
        }))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .manage(Shared {
            settings: Mutex::new(loaded.clone()),
            gate: gate.clone(),
        })
        .manage(Pending::default())
        .manage(Chat::default())
        .manage(ClaudeCodeChat::default())
        .manage(provider::ProviderChat::default())
        .manage(inbox::Inbox::default())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, shortcut, event| {
                    use tauri_plugin_global_shortcut::ShortcutState;
                    if event.state() != ShortcutState::Pressed {
                        return;
                    }
                    let [allow, _deny] = approval_keys();
                    let word = if *shortcut == allow { "allow" } else { "deny" };
                    let _ = app.emit_to(island::WINDOW_LABEL, "approval-shortcut", word.to_string());
                })
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            boot,
            save_settings,
            set_collapsed,
            set_island_rect,
            focus_window,
            reposition,
            open_url,
            open_in_vscode,
            quit_app,
            hooks_status,
            hooks_preview,
            hooks_apply,
            approval_decision,
            approval_ack,
            approval_decline,
            log_line,
            chat_send,
            chat_reset,
            ingest_file,
            secret_present,
            secret_set,
            secret_clear,
            refresh_integration,
            open_n8n,
            open_settings_window,
            set_paused,
            editors_installed,
            claude_code_status,
            github_cli_status,
            codex_status,
            codex_install,
            linear_issue_for_folder,
            linear_comment,
            inbox_refresh,
            inbox_dismiss,
            phone_alert,
            phone_test,
            new_ntfy_topic,
            check_update,
            update_can_install,
            update_install,
            approval_shortcuts,
            chat_restore,
            chat_session_info,
            chats_load,
            chats_save,
            chat_delete_dir,
            provider_presets,
            provider_models,
            voice_listen,
            voice_available,
            skills_list,
            skills_targets,
            skill_read,
            skill_set_enabled,
            skills_preview,
            skills_install,
            skill_create,
            skill_reveal,
            whaticket_accept,
            whaticket_open,
            whaticket_queues,
            whaticket_stats,
            whaticket_stats_reset,
            browser_install,
            browser_status,
            browser_reveal,
            google_connect,
            google_disconnect,
            google_connected,
            gmail_attach,
            drive_search,
            drive_attach,
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            tray::build(&handle)?;
            // Before the island: see create_settings_window.
            create_settings_window(&handle);

            if let Some(win) = island::window(&handle) {
                platform::prepare_island(&win);
                island::make_non_activating(&win);
                island::apply_geometry(&handle, &loaded.screen, false);
                let _ = win.show();
            }
            gate.collapsed.store(false, Ordering::Relaxed);
            gate.set_active(true);
            // Wayland has no global cursor: the page reports the pointer instead.
            if platform::pointer_mode() == "poll" {
                island::spawn_cursor_poll(handle.clone(), gate.clone());
            }
            gate.idle_notch.store(loaded.idle_notch, Ordering::Relaxed);
            island::spawn_topmost_keeper(handle.clone());

            log::line(format!("--- Coucou {} started ---", env!("CARGO_PKG_VERSION")));
            hooks::ensure_hook_exe(&handle);
            secrets::forget_retired();
            pipe::start(handle.clone());
            integrations::start(handle.clone());
            inbox::start(handle.clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Coucou");
}
