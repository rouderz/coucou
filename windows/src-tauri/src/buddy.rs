// Free placement (Settings → General → Where it lives → Free): the characters float in small
// windows of their own that you drag anywhere. Port of NotchBuddy/Sources/App/FreeBuddy.swift.
//
// There is the main character (Claude Code) and one per integration that has its own (#151,
// Settings → Character → "Who handles what"). A click opens the island on that character's
// task, sitting on it; a second click folds it; right-click offers to go back to the top of
// the screen. Every character's spot is remembered.
//
// A WebView2 window created after the island's comes up blank in this app, so on Windows the
// windows are created hidden at launch, before the island's webview, and only shown and hidden
// afterwards: the main one always, the extra ones when free placement is on at launch (switch
// it on later and the extra characters appear after a restart). Linux creates them on demand.
//
// Wayland: the compositor places windows, so the characters go where it puts them (you can
// still drag them) and the island keeps opening at the top of the screen.

use std::collections::HashMap;
use std::sync::Mutex;

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use crate::island::WINDOW_LABEL;
use crate::{log, platform};

/// The main character's window.
pub const LABEL: &str = "buddy";
/// Key of the main character (the others use their integration id).
pub const MAIN: &str = "main";
/// Integrations that can float on their own at the same time.
const MAX_EXTRAS: usize = 4;
/// Logical size of a character's window.
pub const W: f64 = 104.0;
pub const H: f64 = 112.0;

/// How far above the window's bottom edge the character's feet are (logical px): the
/// island's top edge goes there, so the character looks like it sits on it.
pub const SEAT: f64 = 30.0;
/// Room kept for the open island when the character sits low on the screen (logical px).
const ISLAND_ROOM: f64 = 250.0;

struct Buddies {
    /// Window label → the key it shows ("main" or an integration id).
    keys: HashMap<String, String>,
    /// The window the open island belongs to (the last one clicked; alerts use the main one).
    active: String,
    /// The active window's spot before it hopped onto the open island (physical px).
    perched_from: Option<(String, i32, i32)>,
}

static BUDDIES: Mutex<Option<Buddies>> = Mutex::new(None);

fn with<T>(f: impl FnOnce(&mut Buddies) -> T) -> T {
    let mut guard = BUDDIES.lock().unwrap();
    let b = guard.get_or_insert_with(|| Buddies {
        keys: HashMap::new(),
        active: LABEL.to_string(),
        perched_from: None,
    });
    f(b)
}

fn extra_label(i: usize) -> String {
    format!("{LABEL}-{}", i + 1)
}

/// The main character's window.
pub fn window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window(LABEL)
}

fn page_url(app: &AppHandle) -> WebviewUrl {
    #[cfg(dev)]
    if let Some(mut base) = app.config().build.dev_url.clone() {
        base.set_path("/buddy.html");
        return WebviewUrl::External(base);
    }
    let _ = app;
    WebviewUrl::App("buddy.html".into())
}

fn create_one(app: &AppHandle, label: &str, browser_args: &str) {
    match WebviewWindowBuilder::new(app, label, page_url(app))
        .additional_browser_args(browser_args)
        .title("Lumo")
        .inner_size(W, H)
        .resizable(false)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .maximizable(false)
        .minimizable(false)
        .visible(false)
        .build()
    {
        Ok(win) => {
            crate::island::make_non_activating(&win);
            let hidden = win.clone();
            win.on_window_event(move |event| {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = hidden.hide();
                }
            });
        }
        Err(err) => log::line(format!("buddy window {label} failed: {err}")),
    }
}

/// At launch, before the island's webview: the main character's window, and the extra ones
/// on Windows when free placement is on.
pub fn create(app: &AppHandle, browser_args: &str, free: bool) {
    create_one(app, LABEL, browser_args);
    if cfg!(windows) && free {
        for i in 0..MAX_EXTRAS {
            create_one(app, &extra_label(i), browser_args);
        }
    }
    BROWSER_ARGS.lock().unwrap().replace(browser_args.to_string());
}

static BROWSER_ARGS: Mutex<Option<String>> = Mutex::new(None);

/// An extra character's window: the one made at launch, or (Linux) a new one.
fn extra_window(app: &AppHandle, i: usize) -> Option<WebviewWindow> {
    let label = extra_label(i);
    if let Some(w) = app.get_webview_window(&label) {
        return Some(w);
    }
    if cfg!(windows) {
        return None;
    }
    let args = BROWSER_ARGS.lock().unwrap().clone().unwrap_or_default();
    create_one(app, &label, &args);
    app.get_webview_window(&label)
}

/// True when the user picked the free placement.
pub fn is_free(app: &AppHandle) -> bool {
    app.try_state::<crate::Shared>()
        .map(|s| s.settings.lock().unwrap().placement == "free")
        .unwrap_or(false)
}

/// Shows the characters that should be on screen, each at its saved spot, and hides the rest:
/// the main one, and one per active integration with its own character.
pub fn sync(app: &AppHandle) {
    let Some(settings) = app.try_state::<crate::Shared>().map(|s| s.settings.lock().unwrap().clone()) else { return };
    let free = settings.placement == "free";
    let extras: Vec<String> = settings
        .active_integrations
        .iter()
        .filter(|id| {
            settings.float_all
                && !settings.grounded_characters.contains(id)
                && id.as_str() != "integration_claude"
                && settings.critter_assignments.contains_key(id.as_str())
        })
        .take(MAX_EXTRAS)
        .cloned()
        .collect();

    let mut keys = HashMap::new();
    if let Some(win) = window(app) {
        if free {
            keys.insert(LABEL.to_string(), MAIN.to_string());
            place(&win, saved_or_default(app, &settings, MAIN, 0));
        } else {
            let _ = win.hide();
        }
    }
    for i in 0..MAX_EXTRAS {
        let key = if free { extras.get(i) } else { None };
        match key {
            Some(key) => {
                let Some(win) = extra_window(app, i) else { continue };
                keys.insert(extra_label(i), key.clone());
                place(&win, saved_or_default(app, &settings, key, i + 1));
            }
            None => {
                if let Some(win) = app.get_webview_window(&extra_label(i)) {
                    let _ = win.hide();
                }
            }
        }
    }
    with(|b| {
        b.keys = keys;
        if !b.keys.contains_key(&b.active) {
            b.active = LABEL.to_string();
        }
    });
    // Every character page asks again which task it is in charge of (buddy_key).
    let _ = app.emit("buddy-keys", ());
}

fn place(win: &WebviewWindow, spot: (f64, f64)) {
    if platform::positions_itself() {
        let _ = win.set_position(tauri::LogicalPosition::new(spot.0, spot.1));
    }
    let _ = win.set_size(tauri::LogicalSize::new(W, H));
    let _ = win.show();
    let _ = win.set_always_on_top(true);
}

/// The saved top-left corner of a character, if it still lands on a monitor; else a row
/// along the bottom-right of the primary monitor.
fn saved_or_default(app: &AppHandle, s: &crate::settings::Settings, key: &str, index: usize) -> (f64, f64) {
    let saved = if key == MAIN {
        s.buddy_x.zip(s.buddy_y)
    } else {
        s.buddy_spots.get(key).map(|p| (p[0], p[1]))
    };
    let monitors = app.available_monitors().unwrap_or_default();
    if let Some((x, y)) = saved {
        let (cx, cy) = (x + W / 2.0, y + H / 2.0);
        let on_screen = monitors.iter().any(|m| {
            let sc = m.scale_factor();
            let (mx, my) = (m.position().x as f64 / sc, m.position().y as f64 / sc);
            let (mw, mh) = (m.size().width as f64 / sc, m.size().height as f64 / sc);
            cx >= mx && cx < mx + mw && cy >= my && cy < my + mh
        });
        if on_screen {
            return (x, y);
        }
    }
    match app.primary_monitor().ok().flatten().or_else(|| monitors.into_iter().next()) {
        Some(m) => {
            let sc = m.scale_factor();
            let (mx, my) = (m.position().x as f64 / sc, m.position().y as f64 / sc);
            let (mw, mh) = (m.size().width as f64 / sc, m.size().height as f64 / sc);
            (mx + mw - W - 40.0 - index as f64 * (W + 8.0), my + mh - H - 80.0)
        }
        None => (100.0 + index as f64 * (W + 8.0), 100.0),
    }
}

fn active_window(app: &AppHandle) -> Option<WebviewWindow> {
    let label = with(|b| b.active.clone());
    app.get_webview_window(&label).or_else(|| window(app))
}

/// The active character's rectangle in physical pixels: (x, y, w, h) — where the user left
/// it, even while it sits on the open island.
pub fn frame(app: &AppHandle) -> Option<(i32, i32, u32, u32)> {
    let win = active_window(app)?;
    if !win.is_visible().unwrap_or(false) {
        return None;
    }
    let p = win.outer_position().ok()?;
    let s = win.outer_size().ok()?;
    let label = win.label().to_string();
    let (x, y) = with(|b| match &b.perched_from {
        Some((l, x, y)) if *l == label => (*x, *y),
        _ => (p.x, p.y),
    });
    Some((x, y, s.width, s.height))
}

/// Where the island's window goes in free placement: centred on the active character, its top
/// edge where the character's feet are. Low on the screen, the island goes as low as it fits
/// and the character hops onto it (see perch). Physical pixels.
pub fn island_position(app: &AppHandle, panel_w: u32, _panel_h: u32) -> Option<PhysicalPosition<i32>> {
    let (bx, by, bw, bh) = frame(app)?;
    let (cx, cy) = (bx + bw as i32 / 2, by + bh as i32 / 2);
    let monitors = app.available_monitors().ok()?;
    let m = monitors.iter().find(|m| {
        let p = m.position();
        let s = m.size();
        cx >= p.x && cx < p.x + s.width as i32 && cy >= p.y && cy < p.y + s.height as i32
    })?;
    let (mx, my) = (m.position().x, m.position().y);
    let (mw, mh) = (m.size().width as i32, m.size().height as i32);
    let scale = m.scale_factor();
    let seat = (SEAT * scale) as i32;
    let room = (ISLAND_ROOM * scale) as i32;

    let x = (cx - panel_w as i32 / 2).clamp(mx, (mx + mw - panel_w as i32).max(mx));
    let mut top = by + bh as i32 - seat;
    if top + room > my + mh {
        top = (my + mh - room).max(my + bh as i32);
    }
    Some(PhysicalPosition::new(x, top))
}

/// The island opened with its top edge at `island_top`: the active character sits on it, in front.
pub fn perch(app: &AppHandle, island_top: i32) {
    let Some(win) = active_window(app) else { return };
    let (Ok(p), Ok(s), Ok(scale)) = (win.outer_position(), win.outer_size(), win.scale_factor()) else { return };
    let label = win.label().to_string();
    let y = island_top + (SEAT * scale) as i32 - s.height as i32;
    let other = with(|b| {
        let other = match &b.perched_from {
            Some((l, x, y)) if *l != label => Some((l.clone(), *x, *y)),
            _ => None,
        };
        if b.perched_from.as_ref().map(|(l, _, _)| l != &label).unwrap_or(true) {
            b.perched_from = Some((label.clone(), p.x, p.y));
        }
        other
    });
    // Another character was sitting on the island: back home first.
    if let Some((l, x, y)) = other {
        if let Some(w) = app.get_webview_window(&l) {
            let _ = w.set_position(PhysicalPosition::new(x, y));
        }
    }
    if p.y != y {
        let _ = win.set_position(PhysicalPosition::new(p.x, y));
    }
    // Last in the always-on-top band, so it stays in front of the island.
    let _ = win.set_always_on_top(true);
    platform::keep_on_top(&win);
}

/// The island folded: the character goes back to where the user left it, and the next alert
/// opens on the main one.
pub fn unperch(app: &AppHandle) {
    let from = with(|b| {
        b.active = LABEL.to_string();
        b.perched_from.take()
    });
    if let Some((label, x, y)) = from {
        if let Some(win) = app.get_webview_window(&label) {
            let _ = win.set_position(PhysicalPosition::new(x, y));
        }
    }
    // Back on the Settings window if it's still open (#154).
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || sit_on_settings(&handle));
}

/// The Settings window is open (#154): the main character sits on its top edge, near the right
/// end, and moves with it — unless it is busy on the open island.
pub fn sit_on_settings(app: &AppHandle) {
    if !is_free(app) || !platform::positions_itself() {
        return;
    }
    let shared = app.state::<crate::Shared>();
    if !shared.gate.collapsed.load(std::sync::atomic::Ordering::Relaxed) {
        return;
    }
    let (Some(settings), Some(win)) = (app.get_webview_window("settings"), window(app)) else { return };
    if !settings.is_visible().unwrap_or(false) || settings.is_minimized().unwrap_or(false) {
        return;
    }
    let (Ok(sp), Ok(ss), Ok(bp), Ok(bs), Ok(scale)) =
        (settings.outer_position(), settings.outer_size(), win.outer_position(), win.outer_size(), win.scale_factor())
    else { return };
    let busy = with(|b| {
        if b.perched_from.as_ref().map(|(l, _, _)| l != LABEL).unwrap_or(false) {
            return true;
        }
        if b.perched_from.is_none() {
            b.perched_from = Some((LABEL.to_string(), bp.x, bp.y));
        }
        false
    });
    if busy {
        return;
    }
    let right = sp.x + ss.width as i32 - bs.width as i32 - (90.0 * scale) as i32;
    let x = right.max(sp.x + (8.0 * scale) as i32);
    let y = sp.y + (SEAT * scale) as i32 - bs.height as i32;
    let _ = win.set_position(PhysicalPosition::new(x, y));
    let _ = win.set_always_on_top(true);
}

/// The Settings window closed: the main character goes back to its own spot.
pub fn leave_settings(app: &AppHandle) {
    let from = with(|b| match &b.perched_from {
        Some((l, _, _)) if l == LABEL => b.perched_from.take(),
        _ => None,
    });
    if let (Some((_, x, y)), Some(win)) = (from, window(app)) {
        let _ = win.set_position(PhysicalPosition::new(x, y));
    }
}

/// The window sitting on the open island, if any.
pub fn perched_window(app: &AppHandle) -> Option<WebviewWindow> {
    let label = with(|b| b.perched_from.as_ref().map(|(l, _, _)| l.clone()))?;
    app.get_webview_window(&label)
}

// ── Commands ──────────────────────────────────────────────────────────────────

/// Which task a character page is in charge of ("main" or an integration id).
#[tauri::command]
pub fn buddy_key(window: tauri::Window) -> String {
    let label = window.label().to_string();
    with(|b| b.keys.get(&label).cloned()).unwrap_or_else(|| MAIN.to_string())
}

/// A character was clicked (not dragged): the island opens on its task, or folds.
#[tauri::command]
pub fn buddy_clicked(app: AppHandle, window: tauri::Window) {
    let label = window.label().to_string();
    let (key, was_active) = with(|b| {
        let was = b.active == label;
        b.active = label.clone();
        (b.keys.get(&label).cloned().unwrap_or_else(|| MAIN.to_string()), was)
    });
    // Another character is sitting on the open island: it goes home, this one takes its place.
    if !was_active {
        let from = with(|b| b.perched_from.take());
        if let Some((l, x, y)) = from {
            if let Some(w) = app.get_webview_window(&l) {
                let _ = w.set_position(PhysicalPosition::new(x, y));
            }
        }
        let shared = app.state::<crate::Shared>();
        if !shared.gate.collapsed.load(std::sync::atomic::Ordering::Relaxed) {
            let screen = shared.settings.lock().unwrap().screen.clone();
            crate::island::apply_geometry(&app, &screen, false);
        }
    }
    let _ = app.emit_to(WINDOW_LABEL, "buddy-click", key);
}

/// A character was dropped somewhere: remember the spot (logical px) and, if the island is
/// open on it, move the island along.
#[tauri::command]
pub fn buddy_moved(app: AppHandle, window: tauri::Window, shared: tauri::State<crate::Shared>, x: f64, y: f64) {
    let label = window.label().to_string();
    let key = with(|b| {
        // A drop while sitting on the island is a new home: don't hop back to the old one.
        if b.perched_from.as_ref().map(|(l, _, _)| l == &label).unwrap_or(false) {
            b.perched_from = None;
        }
        b.keys.get(&label).cloned().unwrap_or_else(|| MAIN.to_string())
    });
    let settings = {
        let mut s = shared.settings.lock().unwrap();
        if key == MAIN {
            s.buddy_x = Some(x);
            s.buddy_y = Some(y);
        } else {
            s.buddy_spots.insert(key, [x, y]);
        }
        s.clone()
    };
    if let Err(err) = crate::settings::save(&settings) {
        eprintln!("[coucou] could not save settings: {err}");
    }
    // Keep the other windows' copies in step, or their next save would put it back.
    let _ = app.emit("settings-changed", settings.clone());
    let collapsed = shared.gate.collapsed.load(std::sync::atomic::Ordering::Relaxed);
    if !collapsed && with(|b| b.active == label) {
        crate::island::apply_geometry(&app, &settings.screen, false);
    }
}

/// Right-click on a character: back to the top of the screen, or Settings.
#[tauri::command]
pub fn buddy_menu(app: AppHandle, window: tauri::Window) {
    let built = (|| -> tauri::Result<Menu<tauri::Wry>> {
        let back = MenuItem::with_id(&app, "buddy-back", "Back to the top of the screen", true, None::<&str>)?;
        let all_on = app.state::<crate::Shared>().settings.lock().unwrap().float_all;
        let all = tauri::menu::CheckMenuItem::with_id(&app, "buddy-all", "Show every character", true, all_on, None::<&str>)?;
        let settings = MenuItem::with_id(&app, "buddy-settings", "Settings…", true, None::<&str>)?;
        let sep = PredefinedMenuItem::separator(&app)?;
        Menu::with_items(&app, &[&back, &all, &sep, &settings])
    })();
    match built {
        Ok(menu) => {
            let _ = window.popup_menu(&menu);
        }
        Err(err) => log::line(format!("buddy menu failed: {err}")),
    }
}

/// Menu events from the right-click menu (wired in tray.rs).
pub fn on_menu_event(app: &AppHandle, id: &str) -> bool {
    match id {
        "buddy-back" => {
            let settings = {
                let shared = app.state::<crate::Shared>();
                let mut s = shared.settings.lock().unwrap();
                s.placement = "notch".into();
                s.clone()
            };
            if let Err(err) = crate::settings::save(&settings) {
                eprintln!("[coucou] could not save settings: {err}");
            }
            unperch(app);
            sync(app);
            let collapsed = app
                .state::<crate::Shared>()
                .gate
                .collapsed
                .load(std::sync::atomic::Ordering::Relaxed);
            crate::island::apply_geometry(app, &settings.screen, collapsed);
            let _ = app.emit("settings-changed", settings);
            true
        }
        "buddy-all" => {
            let settings = {
                let shared = app.state::<crate::Shared>();
                let mut s = shared.settings.lock().unwrap();
                s.float_all = !s.float_all;
                s.clone()
            };
            if let Err(err) = crate::settings::save(&settings) {
                eprintln!("[coucou] could not save settings: {err}");
            }
            sync(app);
            let _ = app.emit("settings-changed", settings);
            true
        }
        "buddy-settings" => {
            crate::show_settings_window(app);
            true
        }
        _ => false,
    }
}
