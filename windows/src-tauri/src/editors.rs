// "Open terminal" / "Open project": which editor opens the session's folder
// (#75, the macOS editor picker from #54). The user's pick first, then whichever
// known editor is installed, then the file manager.

use serde::Serialize;

use crate::platform;

/// (command on PATH, name shown in Settings)
pub const EDITORS: &[(&str, &str)] = &[
    ("code", "VS Code"),
    ("cursor", "Cursor"),
    ("windsurf", "Windsurf"),
    ("zed", "Zed"),
];

#[derive(Serialize, Clone)]
pub struct EditorInfo {
    pub id: String,
    pub name: String,
}

/// The known editors found on this machine, in the order of `EDITORS`.
pub fn installed() -> Vec<EditorInfo> {
    EDITORS
        .iter()
        .filter(|(cmd, _)| platform::find_program(cmd).is_some())
        .map(|(cmd, name)| EditorInfo { id: cmd.to_string(), name: name.to_string() })
        .collect()
}

/// The order editors are tried in: the preferred one, then the rest.
pub fn order(preferred: &str) -> Vec<&'static str> {
    let mut list: Vec<&'static str> = EDITORS.iter().map(|(cmd, _)| *cmd).collect();
    if let Some(i) = list.iter().position(|c| *c == preferred) {
        let pick = list.remove(i);
        list.insert(0, pick);
    }
    list
}

/// Opens `path` in an editor; falls back to the file manager. True when an editor opened it.
pub fn open(path: Option<&str>, preferred: &str) -> bool {
    for cmd in order(preferred) {
        if let Some(program) = platform::find_program(cmd) {
            let args: Vec<&str> = path.into_iter().collect();
            if platform::spawn_quiet(&program, &args) {
                return true;
            }
        }
    }
    if let Some(p) = path {
        platform::open_folder(p);
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_pick_comes_first_and_nothing_is_lost() {
        assert_eq!(order("zed")[0], "zed");
        assert_eq!(order("zed").len(), EDITORS.len());
        assert_eq!(order("")[0], "code", "no pick: VS Code first, as before");
        assert_eq!(order("notepad")[0], "code");
    }
}
