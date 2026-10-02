// What differs between Windows and Linux, in one place (#34).
//
// Everything else in the app — hooks, the island, integrations, chat — calls
// these functions and never touches Win32, GTK or the file system layout itself.

#[cfg(windows)]
mod win;
#[cfg(windows)]
mod win_user;
#[cfg(windows)]
pub use self::win::*;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use self::linux::*;

/// "2026-10-01 20:32:29"
pub fn timestamp() -> String {
    let (y, mo, d, h, mi, s) = local_time();
    format!("{y:04}-{mo:02}-{d:02} {h:02}:{mi:02}:{s:02}")
}

/// "20261001-203229", for backup file names.
pub fn compact_timestamp() -> String {
    let (y, mo, d, h, mi, s) = local_time();
    format!("{y:04}{mo:02}{d:02}-{h:02}{mi:02}{s:02}")
}

/// Where the relay binary is installed for Claude Code to run.
pub fn hook_exe_path() -> std::path::PathBuf {
    local_dir().join("bin").join(HOOK_EXE)
}
