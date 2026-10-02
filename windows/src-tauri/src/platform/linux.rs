// Linux (#34–#36): XDG folders, xdg-open, libc for the time, GTK for the window.
//
// The island is a GTK window. On X11 it behaves like on Windows: we place it at
// the top centre and follow the global cursor. Wayland gives applications neither
// a global cursor nor a say in where their windows go, so there the island is a
// layer-shell surface anchored to the top edge (#36) and the page itself reports
// the pointer ("dom" mode) while the input region follows the island's shape.

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::OnceLock;

use gtk::prelude::*;
use gtk_layer_shell::LayerShell;
use tauri::{AppHandle, WebviewWindow};

pub const HOOK_EXE: &str = "coucou-hook";
pub const PLATFORM: &str = "linux";

/// True when GTK talks to a Wayland compositor (not XWayland). Settled on the
/// main thread at startup (prepare_island); GDK can't be asked from elsewhere.
pub fn is_wayland() -> bool {
    static WAYLAND: OnceLock<bool> = OnceLock::new();
    if let Some(known) = WAYLAND.get() {
        return *known;
    }
    if !gtk::is_initialized_main_thread() {
        // Not settled yet and not on the GTK thread: the environment's best guess.
        return std::env::var_os("WAYLAND_DISPLAY").is_some()
            && std::env::var("GDK_BACKEND").map(|b| !b.starts_with("x11")).unwrap_or(true);
    }
    *WAYLAND.get_or_init(|| {
        gtk::gdk::Display::default()
            .map(|d| d.type_().name().contains("Wayland"))
            .unwrap_or(false)
    })
}

/// "poll": Rust follows the global cursor (X11). "dom": the page reports it (Wayland).
pub fn pointer_mode() -> &'static str {
    if is_wayland() { "dom" } else { "poll" }
}

pub fn local_time() -> (u16, u16, u16, u16, u16, u16) {
    unsafe {
        let now = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&now, &mut tm).is_null() {
            return (1970, 1, 1, 0, 0, 0);
        }
        (
            (tm.tm_year + 1900) as u16,
            (tm.tm_mon + 1) as u16,
            tm.tm_mday as u16,
            tm.tm_hour as u16,
            tm.tm_min as u16,
            tm.tm_sec as u16,
        )
    }
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

fn xdg(var: &str, fallback: &str) -> PathBuf {
    std::env::var_os(var)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home().join(fallback))
}

/// ~/.config/coucou — settings.
pub fn config_dir() -> PathBuf {
    xdg("XDG_CONFIG_HOME", ".config").join("coucou")
}

/// ~/.local/share/coucou — the relay, the log, dropped files.
pub fn local_dir() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share").join("coucou")
}

pub fn cursor_physical(app: &AppHandle) -> Option<(f64, f64)> {
    let p = app.cursor_position().ok()?;
    Some((p.x, p.y))
}

/// GTK delivers drags to the window under the pointer whatever its input shape
/// says about clicks, so no early warning is needed.
pub fn left_button_down() -> bool {
    false
}

pub fn unblock_webview_drops(_app: &AppHandle) {}

fn on_gtk(win: &WebviewWindow, f: impl FnOnce(&gtk::ApplicationWindow) + Send + 'static) {
    let target = win.clone();
    let _ = win.run_on_main_thread(move || {
        if let Ok(gtk_win) = target.gtk_window() {
            f(&gtk_win);
        }
    });
}

/// Clicks never take the focus away from what the user is doing, and the island
/// stays out of the taskbar and the window switcher.
pub fn make_non_activating(win: &WebviewWindow) {
    on_gtk(win, |w| {
        w.set_accept_focus(false);
        w.set_focus_on_map(false);
        w.set_skip_taskbar_hint(true);
        w.set_skip_pager_hint(true);
        w.set_keep_above(true);
    });
}

/// Temporarily accept the keyboard so the chat field can be typed in.
pub fn set_activating(win: &WebviewWindow, activating: bool) {
    let wayland = is_wayland();
    on_gtk(win, move |w| {
        w.set_accept_focus(activating);
        if wayland && w.is_layer_window() {
            w.set_keyboard_mode(if activating {
                gtk_layer_shell::KeyboardMode::OnDemand
            } else {
                gtk_layer_shell::KeyboardMode::None
            });
        }
    });
}

/// Wayland: turns the island into a layer-shell surface on the overlay layer,
/// anchored to the top edge (the compositor centres it), above full-screen
/// windows and never reserving space. Must run before the window is shown.
pub fn prepare_island(win: &WebviewWindow) {
    if !is_wayland() {
        return;
    }
    let Ok(w) = win.gtk_window() else { return };
    if !gtk_layer_shell::is_supported() {
        crate::log::line("Wayland compositor without layer-shell: the island floats as a normal window");
        return;
    }
    w.hide();
    w.init_layer_shell();
    w.set_namespace("coucou");
    w.set_layer(gtk_layer_shell::Layer::Overlay);
    w.set_anchor(gtk_layer_shell::Edge::Top, true);
    w.set_exclusive_zone(0);
    w.set_keyboard_mode(gtk_layer_shell::KeyboardMode::None);
}

/// On Wayland the compositor places the island; we only size it.
pub fn positions_itself() -> bool {
    !is_wayland()
}

/// Wayland: only the island shape (window-logical, plus margin) takes the mouse;
/// the rest of the transparent window lets clicks through. `None` = whole window.
pub fn set_input_rect(win: &WebviewWindow, rect: Option<(f64, f64, f64, f64)>) {
    if !is_wayland() {
        return;
    }
    on_gtk(win, move |w| {
        let region = rect.map(|(x, y, width, height)| {
            gtk::cairo::Region::create_rectangle(&gtk::cairo::RectangleInt::new(
                x.floor() as i32,
                y.floor() as i32,
                width.ceil().max(1.0) as i32,
                height.ceil().max(1.0) as i32,
            ))
        });
        w.input_shape_combine_region(region.as_ref());
    });
}

fn spawn_detached(program: &PathBuf, arg: Option<&str>) -> bool {
    let mut cmd = Command::new(program);
    if let Some(a) = arg {
        cmd.arg(a);
    }
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().is_ok()
}

pub fn open_url(url: &str) {
    if let Some(open) = find_on_path("xdg-open") {
        spawn_detached(&open, Some(url));
    }
}

/// Opens a folder in VS Code when `code` is on PATH, in the file manager otherwise.
pub fn open_in_editor(path: Option<&str>) -> bool {
    if let Some(code) = find_on_path("code") {
        if spawn_detached(&code, path) {
            return true;
        }
    }
    if let (Some(p), Some(open)) = (path, find_on_path("xdg-open")) {
        spawn_detached(&open, Some(p));
    }
    false
}

/// An executable on PATH, without a shell.
fn find_on_path(name: &str) -> Option<PathBuf> {
    let dirs = std::env::var_os("PATH")?;
    std::env::split_paths(&dirs).map(|d| d.join(name)).find(|p| {
        std::fs::metadata(p)
            .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    })
}

pub fn current_uid() -> u32 {
    unsafe { libc::getuid() }
}

/// Before GTK starts: GNOME's compositor has no layer-shell, so a Wayland island
/// there could neither stay on top nor sit at the top centre. Run it through
/// XWayland instead, unless the user chose a backend themselves.
pub fn choose_backend() {
    let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
    let chosen = std::env::var_os("GDK_BACKEND").is_some();
    let gnome = std::env::var("XDG_CURRENT_DESKTOP")
        .map(|d| d.to_ascii_uppercase().contains("GNOME"))
        .unwrap_or(false);
    if wayland && !chosen && gnome {
        std::env::set_var("GDK_BACKEND", "x11");
    }
}
