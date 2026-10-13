// Free placement (Settings → General → Where it lives → Free): the character floats in a
// small window of its own that you drag anywhere. A click opens the island next to it, a
// second click folds it; right-click offers to go back to the top of the screen. Port of
// NotchBuddy/Sources/App/FreeBuddy.swift.
//
// Like the settings window, the buddy window is created hidden at launch, before the
// island's webview (a WebView2 window created later comes up blank in this app), and is
// only shown and hidden afterwards.
//
// Wayland: the compositor places windows, so the character goes where the compositor puts
// it (you can still drag it) and the island keeps opening at the top of the screen.

use std::sync::Mutex;

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use crate::island::WINDOW_LABEL;
use crate::{log, platform};

pub const LABEL: &str = "buddy";
/// Logical size of the character's window.
pub const W: f64 = 104.0;
pub const H: f64 = 112.0;

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

pub fn create(app: &AppHandle, browser_args: &str) {
    match WebviewWindowBuilder::new(app, LABEL, page_url(app))
        .additional_browser_args(browser_args)
        .title("Coucou")
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
        Err(err) => log::line(format!("buddy window failed: {err}")),
    }
}

/// True when the user picked the free placement.
pub fn is_free(app: &AppHandle) -> bool {
    app.try_state::<crate::Shared>()
        .map(|s| s.settings.lock().unwrap().placement == "free")
        .unwrap_or(false)
}

/// Shows or hides the character to match the setting, at its saved spot.
pub fn sync(app: &AppHandle) {
    let Some(win) = window(app) else { return };
    if !is_free(app) {
        let _ = win.hide();
        return;
    }
    if platform::positions_itself() {
        let (x, y) = saved_or_default(app);
        let _ = win.set_position(tauri::LogicalPosition::new(x, y));
    }
    let _ = win.set_size(tauri::LogicalSize::new(W, H));
    let _ = win.show();
    let _ = win.set_always_on_top(true);
}

/// The saved top-left corner, if it still lands on a monitor; else the bottom-right
/// corner of the primary monitor.
fn saved_or_default(app: &AppHandle) -> (f64, f64) {
    let saved = app.try_state::<crate::Shared>().and_then(|s| {
        let s = s.settings.lock().unwrap();
        Some((s.buddy_x?, s.buddy_y?))
    });
    let monitors = app.available_monitors().unwrap_or_default();
    if let Some((x, y)) = saved {
        let (cx, cy) = (x + W / 2.0, y + H / 2.0);
        let on_screen = monitors.iter().any(|m| {
            let s = m.scale_factor();
            let (mx, my) = (m.position().x as f64 / s, m.position().y as f64 / s);
            let (mw, mh) = (m.size().width as f64 / s, m.size().height as f64 / s);
            cx >= mx && cx < mx + mw && cy >= my && cy < my + mh
        });
        if on_screen {
            return (x, y);
        }
    }
    match app.primary_monitor().ok().flatten().or_else(|| monitors.into_iter().next()) {
        Some(m) => {
            let s = m.scale_factor();
            let (mx, my) = (m.position().x as f64 / s, m.position().y as f64 / s);
            let (mw, mh) = (m.size().width as f64 / s, m.size().height as f64 / s);
            (mx + mw - W - 40.0, my + mh - H - 80.0)
        }
        None => (100.0, 100.0),
    }
}

/// Where the window was before it hopped onto the open island (physical px).
static PERCHED_FROM: Mutex<Option<(i32, i32)>> = Mutex::new(None);

/// How far above the window's bottom edge the character's feet are (logical px): the
/// island's top edge goes there, so the character looks like it sits on it.
pub const SEAT: f64 = 30.0;
/// Room kept for the open island when the character sits low on the screen (logical px).
const ISLAND_ROOM: f64 = 250.0;

/// The character's rectangle in physical pixels: (x, y, w, h) — where the user left it,
/// even while it sits on the open island.
pub fn frame(app: &AppHandle) -> Option<(i32, i32, u32, u32)> {
    let win = window(app)?;
    if !win.is_visible().unwrap_or(false) {
        return None;
    }
    let p = win.outer_position().ok()?;
    let s = win.outer_size().ok()?;
    let (x, y) = PERCHED_FROM.lock().unwrap().unwrap_or((p.x, p.y));
    Some((x, y, s.width, s.height))
}

/// Where the island's window goes in free placement: centred on the character, its top
/// edge where the character's feet are. Low on the screen, the island goes as low as it
/// fits and the character hops onto it (see perch). Physical pixels.
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

/// The island opened with its top edge at `island_top`: the character sits on it, in front.
pub fn perch(app: &AppHandle, island_top: i32) {
    let Some(win) = window(app) else { return };
    let (Ok(p), Ok(s), Ok(scale)) = (win.outer_position(), win.outer_size(), win.scale_factor()) else { return };
    let y = island_top + (SEAT * scale) as i32 - s.height as i32;
    {
        let mut from = PERCHED_FROM.lock().unwrap();
        if from.is_none() {
            *from = Some((p.x, p.y));
        }
    }
    if p.y != y {
        let _ = win.set_position(PhysicalPosition::new(p.x, y));
    }
    // Last in the always-on-top band, so it stays in front of the island.
    let _ = win.set_always_on_top(true);
    platform::keep_on_top(&win);
}

/// The island folded: back to where the user left it.
pub fn unperch(app: &AppHandle) {
    let Some(win) = window(app) else { return };
    if let Some((x, y)) = PERCHED_FROM.lock().unwrap().take() {
        let _ = win.set_position(PhysicalPosition::new(x, y));
    }
}

/// True while the character sits on the open island.
pub fn is_perched() -> bool {
    PERCHED_FROM.lock().unwrap().is_some()
}

// ── Commands ──────────────────────────────────────────────────────────────────

/// The character was clicked (not dragged): the island opens or folds.
#[tauri::command]
pub fn buddy_clicked(app: AppHandle) {
    let _ = app.emit_to(WINDOW_LABEL, "buddy-click", ());
}

/// The character was dropped somewhere: remember the spot (logical px) and, if the
/// island is open, move it along.
#[tauri::command]
pub fn buddy_moved(app: AppHandle, shared: tauri::State<crate::Shared>, x: f64, y: f64) {
    // A drop while sitting on the island is a new home: don't hop back to the old one.
    PERCHED_FROM.lock().unwrap().take();
    let settings = {
        let mut s = shared.settings.lock().unwrap();
        s.buddy_x = Some(x);
        s.buddy_y = Some(y);
        s.clone()
    };
    if let Err(err) = crate::settings::save(&settings) {
        eprintln!("[coucou] could not save settings: {err}");
    }
    // Keep the other windows' copies in step, or their next save would put it back.
    let _ = app.emit("settings-changed", settings.clone());
    let collapsed = shared.gate.collapsed.load(std::sync::atomic::Ordering::Relaxed);
    if !collapsed {
        crate::island::apply_geometry(&app, &settings.screen, false);
    }
}

/// Right-click on the character: back to the top of the screen, or Settings.
#[tauri::command]
pub fn buddy_menu(app: AppHandle) {
    let Some(win) = window(&app) else { return };
    let built = (|| -> tauri::Result<Menu<tauri::Wry>> {
        let back = MenuItem::with_id(&app, "buddy-back", "Back to the top of the screen", true, None::<&str>)?;
        let settings = MenuItem::with_id(&app, "buddy-settings", "Settings…", true, None::<&str>)?;
        let sep = PredefinedMenuItem::separator(&app)?;
        Menu::with_items(&app, &[&back, &sep, &settings])
    })();
    match built {
        Ok(menu) => {
            let _ = win.popup_menu(&menu);
        }
        Err(err) => log::line(format!("buddy menu failed: {err}")),
    }
}

/// Menu events from the right-click menu (wired in lib.rs).
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
        "buddy-settings" => {
            crate::show_settings_window(app);
            true
        }
        _ => false,
    }
}
