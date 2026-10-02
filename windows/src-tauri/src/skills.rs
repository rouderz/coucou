// Skills: every skill Claude Code (and Codex) can use on this computer, and an
// easy way to add one.
//
// Where they live:
//   personal  ~/.claude/skills/<name>/SKILL.md
//   project   <project>/.claude/skills/<name>/SKILL.md   (projects of the sessions we've seen)
//   plugin    <installPath>/skills/<name>/SKILL.md       (from ~/.claude/plugins/installed_plugins.json)
//   codex     ~/.codex/skills/<name>/SKILL.md
//
// Disabling moves the folder to a sibling `skills-disabled/` (Claude Code only reads
// `skills/<name>/SKILL.md`), so nothing is ever deleted. Plugin skills are read-only:
// they come and go with their plugin.
//
// Adding: a folder, a .zip / .skill file or a GitHub URL is staged first, shown to the
// user (name, description, files, whether it has scripts), and copied only on a click.
// Coucou never runs a skill's scripts.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, UNIX_EPOCH};

use serde::Serialize;
use serde_json::Value;

use crate::platform;

const DISABLED_DIR: &str = "skills-disabled";
const MAX_PROJECTS: usize = 30;
const MAX_SKILL_MD: u64 = 512 * 1024;
const MAX_DOWNLOAD: usize = 50 * 1024 * 1024;
const SCRIPT_EXTS: &[&str] = &["sh", "bash", "zsh", "py", "js", "mjs", "cjs", "ts", "ps1", "psm1", "bat", "cmd", "exe", "rb", "pl", "php"];

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Skill {
    pub name: String,
    pub description: String,
    /// "personal", "project", "plugin" or "codex".
    pub source: String,
    /// The project folder, or the plugin's name.
    pub origin: Option<String>,
    /// The skill's folder.
    pub path: String,
    pub enabled: bool,
    /// Plugin skills can't be disabled one by one.
    pub editable: bool,
    pub has_scripts: bool,
    /// Last change, ms since the epoch.
    pub modified: u64,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    /// "personal", "codex", or a project folder.
    pub id: String,
    pub label: String,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct StagedSkill {
    pub name: String,
    pub description: String,
    pub files: Vec<String>,
    pub has_scripts: bool,
    /// Where it would be installed.
    pub dest: String,
    /// A skill with that name is already there (installing asks to replace it).
    pub exists: bool,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Preview {
    pub token: String,
    pub skills: Vec<StagedSkill>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct SkillText {
    pub name: String,
    pub path: String,
    pub content: String,
    pub files: Vec<String>,
}

// ── Front matter ──────────────────────────────────────────────────────────────

/// `name` and `description` from a SKILL.md's YAML front matter. Handles quoted
/// values and folded / literal blocks (`>` / `|`); everything else is ignored.
pub fn front_matter(text: &str) -> (Option<String>, Option<String>) {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut lines = text.lines();
    if lines.next().map(str::trim) != Some("---") {
        return (None, None);
    }
    let body: Vec<&str> = lines.take_while(|l| l.trim() != "---").collect();
    let mut name = None;
    let mut description = None;
    let mut i = 0;
    while i < body.len() {
        let line = body[i];
        i += 1;
        if line.starts_with(' ') || line.starts_with('\t') {
            continue;
        }
        let Some((key, value)) = line.split_once(':') else { continue };
        let key = key.trim();
        let value = value.trim();
        let value = if value.is_empty() || value.starts_with('>') || value.starts_with('|') {
            // A block: the following indented lines.
            let literal = value.starts_with('|');
            let mut parts = Vec::new();
            while i < body.len() && (body[i].starts_with(' ') || body[i].starts_with('\t') || body[i].trim().is_empty()) {
                let t = body[i].trim();
                if !t.is_empty() {
                    parts.push(t);
                }
                i += 1;
            }
            parts.join(if literal { "\n" } else { " " })
        } else {
            unquote(value)
        };
        match key {
            "name" if !value.is_empty() => name = Some(value),
            "description" if !value.is_empty() => description = Some(value),
            _ => {}
        }
    }
    (name, description)
}

fn unquote(v: &str) -> String {
    let v = v.trim();
    if v.len() >= 2 && ((v.starts_with('"') && v.ends_with('"')) || (v.starts_with('\'') && v.ends_with('\''))) {
        let inner = &v[1..v.len() - 1];
        if v.starts_with('"') {
            inner.replace("\\\"", "\"").replace("\\n", "\n")
        } else {
            inner.replace("''", "'")
        }
    } else {
        v.to_string()
    }
}

/// A safe folder name for a skill: lowercase letters, digits, `-` and `_`.
pub fn folder_name(name: &str) -> String {
    let mut out = String::new();
    for c in name.trim().chars() {
        if c.is_ascii_alphanumeric() || c == '_' {
            out.push(c.to_ascii_lowercase());
        } else if (c == '-' || c == ' ' || c == '.') && !out.ends_with('-') && !out.is_empty() {
            out.push('-');
        }
    }
    let out = out.trim_end_matches('-').to_string();
    if out.is_empty() { "skill".into() } else { out }
}

fn is_script(rel: &str) -> bool {
    let lower = rel.replace('\\', "/").to_lowercase();
    if lower.starts_with("scripts/") || lower.contains("/scripts/") {
        return true;
    }
    Path::new(&lower)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| SCRIPT_EXTS.contains(&e))
        .unwrap_or(false)
}

/// Files under `dir`, relative, sorted; symlinks are skipped. At most 500.
fn list_files(dir: &Path) -> Vec<String> {
    fn walk(base: &Path, dir: &Path, out: &mut Vec<String>, depth: usize) {
        if depth > 8 || out.len() >= 500 {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else { continue };
            let path = entry.path();
            if kind.is_symlink() {
                continue;
            } else if kind.is_dir() {
                walk(base, &path, out, depth + 1);
            } else if kind.is_file() {
                if let Ok(rel) = path.strip_prefix(base) {
                    out.push(rel.to_string_lossy().replace('\\', "/"));
                }
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, dir, &mut out, 0);
    out.sort();
    out
}

fn modified_ms(path: &Path) -> u64 {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn read_skill_md(dir: &Path) -> Option<String> {
    let file = dir.join("SKILL.md");
    let meta = std::fs::metadata(&file).ok()?;
    if !meta.is_file() || meta.len() > MAX_SKILL_MD {
        return None;
    }
    std::fs::read_to_string(file).ok()
}

/// The skills directly inside `root` (each a folder with a SKILL.md).
fn skills_in(root: &Path, source: &str, origin: Option<&str>, enabled: bool, editable: bool) -> Vec<Skill> {
    let Ok(entries) = std::fs::read_dir(root) else { return Vec::new() };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let dir = entry.path();
        if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            continue;
        }
        let Some(text) = read_skill_md(&dir) else { continue };
        let (name, description) = front_matter(&text);
        let folder = entry.file_name().to_string_lossy().to_string();
        let files = list_files(&dir);
        out.push(Skill {
            name: name.unwrap_or(folder),
            description: description.unwrap_or_default(),
            source: source.into(),
            origin: origin.map(str::to_string),
            path: dir.to_string_lossy().to_string(),
            enabled,
            editable,
            has_scripts: files.iter().any(|f| is_script(f)),
            modified: modified_ms(&dir.join("SKILL.md")),
        });
    }
    out
}

// ── Locations ─────────────────────────────────────────────────────────────────

fn claude_dir() -> PathBuf {
    platform::home().join(".claude")
}

fn codex_dir() -> PathBuf {
    platform::home().join(".codex")
}

/// The folder that holds `<root>/skills`: ~/.claude, ~/.codex or <project>/.claude.
fn base_for_target(target: &str) -> Option<PathBuf> {
    match target {
        "personal" => Some(claude_dir()),
        "codex" => Some(codex_dir()),
        project => {
            let p = PathBuf::from(project);
            (p.is_absolute() && p.is_dir()).then(|| p.join(".claude"))
        }
    }
}

/// Every `installPath` in installed_plugins.json (v1 and v2 layouts), with the plugin's name.
pub fn plugin_paths(json: &Value) -> Vec<(String, PathBuf)> {
    let mut out = Vec::new();
    let Some(plugins) = json.get("plugins").and_then(Value::as_object) else { return out };
    for (key, entry) in plugins {
        let name = key.split('@').next().unwrap_or(key).to_string();
        let entries: Vec<&Value> = match entry {
            Value::Array(list) => list.iter().collect(),
            other => vec![other],
        };
        for e in entries {
            if let Some(p) = e.get("installPath").and_then(Value::as_str) {
                out.push((name.clone(), PathBuf::from(p)));
            }
        }
    }
    out
}

fn installed_plugins() -> Vec<(String, PathBuf)> {
    let file = claude_dir().join("plugins").join("installed_plugins.json");
    std::fs::read(file)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .map(|v| plugin_paths(&v))
        .unwrap_or_default()
}

// ── Projects we've seen ──────────────────────────────────────────────────────

static PROJECTS: Mutex<Option<Vec<String>>> = Mutex::new(None);

fn projects_file() -> PathBuf {
    platform::local_dir().join("projects.json")
}

pub fn projects() -> Vec<String> {
    let mut guard = PROJECTS.lock().unwrap();
    if guard.is_none() {
        let list = std::fs::read(projects_file())
            .ok()
            .and_then(|b| serde_json::from_slice::<Vec<String>>(&b).ok())
            .unwrap_or_default();
        *guard = Some(list);
    }
    guard.clone().unwrap_or_default()
}

/// A Claude Code / Codex session ran in `cwd`: remember it for project skills.
/// Writes only when the list changes order or grows.
pub fn note_project(cwd: &str) {
    let cwd = cwd.trim();
    if cwd.is_empty() || !Path::new(cwd).is_absolute() {
        return;
    }
    let mut list = projects();
    if list.first().map(String::as_str) == Some(cwd) {
        return;
    }
    list.retain(|p| p != cwd);
    list.insert(0, cwd.to_string());
    list.truncate(MAX_PROJECTS);
    *PROJECTS.lock().unwrap() = Some(list.clone());
    let _ = std::fs::create_dir_all(platform::local_dir());
    if let Ok(bytes) = serde_json::to_vec_pretty(&list) {
        let _ = std::fs::write(projects_file(), bytes);
    }
}

fn project_label(p: &str) -> String {
    Path::new(p).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| p.to_string())
}

// ── Listing ───────────────────────────────────────────────────────────────────

pub fn list() -> Vec<Skill> {
    let mut out = Vec::new();
    for (base, source) in [(claude_dir(), "personal"), (codex_dir(), "codex")] {
        out.extend(skills_in(&base.join("skills"), source, None, true, true));
        out.extend(skills_in(&base.join(DISABLED_DIR), source, None, false, true));
    }
    for project in projects() {
        let base = Path::new(&project).join(".claude");
        let label = project_label(&project);
        let mut found = skills_in(&base.join("skills"), "project", Some(&project), true, true);
        found.extend(skills_in(&base.join(DISABLED_DIR), "project", Some(&project), false, true));
        for s in &mut found {
            s.origin = Some(format!("{label} — {project}"));
        }
        out.extend(found);
    }
    let mut seen = HashSet::new();
    for (plugin, path) in installed_plugins() {
        if seen.insert(path.clone()) {
            out.extend(skills_in(&path.join("skills"), "plugin", Some(&plugin), true, false));
        }
    }
    out.sort_by(|a, b| {
        let rank = |s: &Skill| match s.source.as_str() {
            "personal" => 0,
            "project" => 1,
            "plugin" => 2,
            _ => 3,
        };
        (rank(a), a.origin.clone(), a.name.to_lowercase()).cmp(&(rank(b), b.origin.clone(), b.name.to_lowercase()))
    });
    out
}

pub fn targets() -> Vec<Target> {
    let mut out = vec![
        Target { id: "personal".into(), label: "Claude Code — personal (~/.claude/skills)".into() },
    ];
    if codex_dir().is_dir() {
        out.push(Target { id: "codex".into(), label: "Codex (~/.codex/skills)".into() });
    }
    for p in projects() {
        if Path::new(&p).is_dir() {
            out.push(Target { label: format!("Project — {}", project_label(&p)), id: p });
        }
    }
    out
}

/// Every folder a skill may live in, to check paths the UI hands back.
fn known_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    for base in [claude_dir(), codex_dir()] {
        roots.push(base.join("skills"));
        roots.push(base.join(DISABLED_DIR));
    }
    for p in projects() {
        let base = Path::new(&p).join(".claude");
        roots.push(base.join("skills"));
        roots.push(base.join(DISABLED_DIR));
    }
    for (_, path) in installed_plugins() {
        roots.push(path.join("skills"));
    }
    roots
}

/// `dir` is a skill folder directly inside one of the known roots.
fn checked_skill_dir(dir: &str) -> Result<PathBuf, String> {
    let dir = PathBuf::from(dir);
    let canon = dir.canonicalize().map_err(|_| "That skill isn't there anymore.".to_string())?;
    let parent = canon.parent().ok_or("Not a skill folder")?;
    let ok = known_roots()
        .iter()
        .filter_map(|r| r.canonicalize().ok())
        .any(|r| r == parent);
    if ok && canon.join("SKILL.md").is_file() {
        Ok(canon)
    } else {
        Err("Not a skill Coucou knows about.".into())
    }
}

pub fn read(dir: &str) -> Result<SkillText, String> {
    let dir = checked_skill_dir(dir)?;
    let content = read_skill_md(&dir).ok_or("SKILL.md can't be read")?;
    let (name, _) = front_matter(&content);
    Ok(SkillText {
        name: name.unwrap_or_else(|| dir.file_name().unwrap_or_default().to_string_lossy().to_string()),
        path: dir.to_string_lossy().to_string(),
        content,
        files: list_files(&dir),
    })
}

/// Moves a skill between `skills/` and `skills-disabled/`.
pub fn set_enabled(dir: &str, enabled: bool) -> Result<(), String> {
    let dir = checked_skill_dir(dir)?;
    let parent = dir.parent().ok_or("Not a skill folder")?;
    let base = parent.parent().ok_or("Not a skill folder")?;
    let here = parent.file_name().and_then(|n| n.to_str()).unwrap_or_default();
    let to = match (here, enabled) {
        ("skills", false) => DISABLED_DIR,
        (DISABLED_DIR, true) => "skills",
        ("skills", true) | (DISABLED_DIR, false) => return Ok(()),
        _ => return Err("Plugin skills come and go with their plugin.".into()),
    };
    let is_plugin = installed_plugins().iter().any(|(_, p)| p.canonicalize().ok().as_deref() == Some(base));
    if is_plugin || base.join(".claude-plugin").exists() {
        return Err("Plugin skills come and go with their plugin.".into());
    }
    let dest_root = base.join(to);
    std::fs::create_dir_all(&dest_root).map_err(|e| e.to_string())?;
    let dest = dest_root.join(dir.file_name().ok_or("Not a skill folder")?);
    if dest.exists() {
        return Err(format!("{} already has a skill with that folder name.", dest_root.display()));
    }
    std::fs::rename(&dir, &dest).map_err(|e| e.to_string())
}

// ── Adding ────────────────────────────────────────────────────────────────────

fn staging_root() -> PathBuf {
    platform::local_dir().join("skills-staging")
}

/// The folders under `root` that hold a SKILL.md: `root` itself, or its
/// sub-folders (a zip with a top folder, a repo with several skills…), up to 4 deep.
pub fn find_skill_dirs(root: &Path) -> Vec<PathBuf> {
    fn walk(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
        if dir.join("SKILL.md").is_file() {
            out.push(dir.to_path_buf());
            return;
        }
        if depth >= 4 {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        let mut dirs: Vec<PathBuf> = entries
            .flatten()
            .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
            .filter(|e| !e.file_name().to_string_lossy().starts_with('.') && e.file_name() != "node_modules")
            .map(|e| e.path())
            .collect();
        dirs.sort();
        for d in dirs {
            walk(&d, depth + 1, out);
        }
    }
    let mut out = Vec::new();
    walk(root, 0, &mut out);
    out
}

/// Copies a folder, without symlinks.
fn copy_dir(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        let dest = to.join(entry.file_name());
        if kind.is_symlink() {
            continue;
        } else if kind.is_dir() {
            copy_dir(&entry.path(), &dest)?;
        } else if kind.is_file() {
            std::fs::copy(entry.path(), dest)?;
        }
    }
    Ok(())
}

/// Every extracted path stays inside `root` (zip-slip guard) — symlinks are dropped.
fn sanitize_tree(root: &Path) -> Result<(), String> {
    let canon_root = root.canonicalize().map_err(|e| e.to_string())?;
    fn walk(dir: &Path, root: &Path) -> Result<(), String> {
        for entry in std::fs::read_dir(dir).map_err(|e| e.to_string())?.flatten() {
            let kind = entry.file_type().map_err(|e| e.to_string())?;
            let path = entry.path();
            if kind.is_symlink() {
                let _ = std::fs::remove_file(&path);
                continue;
            }
            let canon = path.canonicalize().map_err(|e| e.to_string())?;
            if !canon.starts_with(root) {
                return Err("The archive tries to write outside its folder.".into());
            }
            if kind.is_dir() {
                walk(&path, root)?;
            }
        }
        Ok(())
    }
    walk(root, &canon_root)
}

/// `https://github.com/owner/repo[/tree/<ref>/<path>]` → (zip URL, sub-path inside the archive).
pub fn github_archive(url: &str) -> Option<(String, String)> {
    let rest = url.trim().trim_end_matches('/').strip_prefix("https://github.com/")?;
    let parts: Vec<&str> = rest.split('/').filter(|p| !p.is_empty()).collect();
    if parts.len() < 2 {
        return None;
    }
    let ok = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c));
    let (owner, repo) = (parts[0], parts[1].trim_end_matches(".git"));
    if !ok(owner) || !ok(repo) {
        return None;
    }
    let (reference, sub) = if parts.len() >= 4 && (parts[2] == "tree" || parts[2] == "blob") {
        let mut sub = parts[4..].join("/");
        // A link to SKILL.md itself means its folder.
        if sub == "SKILL.md" {
            sub.clear();
        } else if let Some(dir) = sub.strip_suffix("/SKILL.md") {
            sub = dir.to_string();
        }
        (parts[3].to_string(), sub)
    } else {
        ("HEAD".to_string(), String::new())
    };
    if !reference.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c)) || sub.split('/').any(|s| s == "..") {
        return None;
    }
    Some((format!("https://github.com/{owner}/{repo}/archive/{reference}.zip"), sub))
}

async fn download(url: &str, to: &Path) -> Result<(), String> {
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(|e| e.to_string())?
        .get(url)
        .header("User-Agent", "Coucou")
        .send()
        .await
        .map_err(|_| "Can't reach GitHub".to_string())?;
    if !response.status().is_success() {
        return Err(format!("GitHub answered {} — check the link (public repos only).", response.status().as_u16()));
    }
    let bytes = response.bytes().await.map_err(|e| e.to_string())?;
    if bytes.len() > MAX_DOWNLOAD {
        return Err("That repository is too big to be a skill (over 50 MB).".into());
    }
    std::fs::write(to, &bytes).map_err(|e| e.to_string())
}

fn new_token() -> String {
    let nanos = std::time::SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    format!("{}-{nanos}", std::process::id())
}

fn token_dir(token: &str) -> Result<PathBuf, String> {
    if token.is_empty() || !token.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return Err("Unknown preview".into());
    }
    let dir = staging_root().join(token);
    if dir.is_dir() { Ok(dir) } else { Err("That preview expired — preview it again.".into()) }
}

/// Stages `source` (a folder, a .zip / .skill file, or a GitHub URL) and says what
/// installing it into `target` would do. Nothing is installed yet.
pub async fn preview(source: &str, target: &str) -> Result<Preview, String> {
    let source = source.trim().trim_matches('"');
    let base = base_for_target(target).ok_or("Pick where to install it.")?;
    // Only one preview at a time: drop older staging folders.
    let _ = std::fs::remove_dir_all(staging_root());
    let token = new_token();
    let stage = staging_root().join(&token);
    let content = stage.join("content");
    std::fs::create_dir_all(&content).map_err(|e| e.to_string())?;

    let mut search_root = content.clone();
    if source.starts_with("https://") {
        let (zip_url, sub) = github_archive(source).ok_or("Only github.com links to a repository or a folder in one.")?;
        let zip = stage.join("download.zip");
        download(&zip_url, &zip).await?;
        platform::unzip(&zip, &content)?;
        sanitize_tree(&content)?;
        // GitHub wraps everything in one top folder (<repo>-<ref>).
        if let Some(top) = std::fs::read_dir(&content).ok().and_then(|mut d| d.next()).and_then(|e| e.ok()) {
            search_root = top.path().join(&sub);
        }
    } else {
        let path = PathBuf::from(source);
        if path.is_dir() {
            copy_dir(&path, &content).map_err(|e| e.to_string())?;
        } else if path.is_file() {
            let ext = path.extension().and_then(|e| e.to_str()).unwrap_or_default().to_lowercase();
            if path.file_name().map(|n| n == "SKILL.md").unwrap_or(false) {
                copy_dir(path.parent().ok_or("No folder")?, &content).map_err(|e| e.to_string())?;
            } else if ext == "zip" || ext == "skill" {
                platform::unzip(&path, &content)?;
                sanitize_tree(&content)?;
            } else {
                return Err("Drop a skill folder, a .zip or .skill file, or paste a GitHub link.".into());
            }
        } else {
            return Err("Nothing there — check the path.".into());
        }
    }

    let dirs = find_skill_dirs(&search_root);
    if dirs.is_empty() {
        let _ = std::fs::remove_dir_all(&stage);
        return Err("No SKILL.md in there, so it isn't a skill.".into());
    }
    let skills_root = base.join("skills");
    let disabled_root = base.join(DISABLED_DIR);
    let mut skills = Vec::new();
    let mut manifest = Vec::new();
    for dir in dirs.iter().take(50) {
        let text = read_skill_md(dir).unwrap_or_default();
        let (name, description) = front_matter(&text);
        let fallback = dir.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "skill".into());
        let name = name.unwrap_or(fallback);
        let folder = folder_name(&name);
        let files = list_files(dir);
        let dest = skills_root.join(&folder);
        skills.push(StagedSkill {
            description: description.unwrap_or_default(),
            has_scripts: files.iter().any(|f| is_script(f)),
            files,
            exists: dest.exists() || disabled_root.join(&folder).exists(),
            dest: dest.to_string_lossy().to_string(),
            name,
        });
        manifest.push(serde_json::json!({ "from": dir, "dest": dest }));
    }
    std::fs::write(stage.join("manifest.json"), serde_json::to_vec(&manifest).unwrap_or_default())
        .map_err(|e| e.to_string())?;
    Ok(Preview { token, skills })
}

/// Installs what `preview` staged. An existing skill is replaced only with `replace`
/// (the old folder goes to Coucou's own trash, not away).
pub fn install(token: &str, replace: bool) -> Result<Vec<String>, String> {
    let stage = token_dir(token)?;
    let manifest: Vec<Value> = std::fs::read(stage.join("manifest.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .ok_or("That preview expired — preview it again.")?;
    let content = stage.join("content").canonicalize().map_err(|e| e.to_string())?;
    let mut installed = Vec::new();
    for item in manifest {
        let from = PathBuf::from(item["from"].as_str().unwrap_or_default());
        let dest = PathBuf::from(item["dest"].as_str().unwrap_or_default());
        let from = from.canonicalize().map_err(|e| e.to_string())?;
        if !from.starts_with(&content) {
            return Err("Unexpected staged path".into());
        }
        let disabled = dest.parent().and_then(Path::parent).map(|b| b.join(DISABLED_DIR).join(dest.file_name().unwrap_or_default()));
        for existing in [Some(dest.clone()), disabled].into_iter().flatten() {
            if existing.exists() {
                if !replace {
                    return Err(format!("{} already exists.", existing.display()));
                }
                let trash = platform::local_dir()
                    .join("skills-trash")
                    .join(format!("{}-{}", platform::compact_timestamp(), existing.file_name().unwrap_or_default().to_string_lossy()));
                std::fs::create_dir_all(trash.parent().unwrap()).map_err(|e| e.to_string())?;
                if std::fs::rename(&existing, &trash).is_err() {
                    copy_dir(&existing, &trash).map_err(|e| e.to_string())?;
                    std::fs::remove_dir_all(&existing).map_err(|e| e.to_string())?;
                }
            }
        }
        copy_dir(&from, &dest).map_err(|e| e.to_string())?;
        installed.push(dest.to_string_lossy().to_string());
    }
    let _ = std::fs::remove_dir_all(&stage);
    Ok(installed)
}

/// A new skill from a template, in `target`. Returns its folder.
pub fn create(name: &str, target: &str) -> Result<String, String> {
    let base = base_for_target(target).ok_or("Pick where to create it.")?;
    let folder = folder_name(name);
    let dir = base.join("skills").join(&folder);
    if dir.exists() || base.join(DISABLED_DIR).join(&folder).exists() {
        return Err("A skill with that name already exists.".into());
    }
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let body = format!(
        "---\nname: {folder}\ndescription: What this skill does and when Claude should use it (one or two sentences).\n---\n\n# {title}\n\n## Steps\n\n1. …\n2. …\n",
        title = name.trim()
    );
    std::fs::write(dir.join("SKILL.md"), body).map_err(|e| e.to_string())?;
    Ok(dir.to_string_lossy().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("coucou-skills-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn front_matter_plain_and_quoted() {
        let (n, d) = front_matter("---\nname: pdf-tools\ndescription: \"Read PDFs: text, tables\"\n---\n# Body");
        assert_eq!(n.as_deref(), Some("pdf-tools"));
        assert_eq!(d.as_deref(), Some("Read PDFs: text, tables"));
    }

    #[test]
    fn front_matter_folded_block_and_bom() {
        let (n, d) = front_matter("\u{feff}---\nname: x\ndescription: >\n  First line\n  second line\nlicense: MIT\n---\n");
        assert_eq!(n.as_deref(), Some("x"));
        assert_eq!(d.as_deref(), Some("First line second line"));
    }

    #[test]
    fn front_matter_missing() {
        assert_eq!(front_matter("# Just markdown"), (None, None));
    }

    #[test]
    fn folder_names_are_safe() {
        assert_eq!(folder_name("My Skill v2.0"), "my-skill-v2-0");
        assert_eq!(folder_name("../etc"), "etc");
        assert_eq!(folder_name("  "), "skill");
    }

    #[test]
    fn scripts_are_spotted() {
        assert!(is_script("scripts/run.txt"));
        assert!(is_script("tool/convert.py"));
        assert!(!is_script("reference/notes.md"));
    }

    #[test]
    fn github_links() {
        assert_eq!(
            github_archive("https://github.com/anthropics/skills").unwrap(),
            ("https://github.com/anthropics/skills/archive/HEAD.zip".into(), String::new())
        );
        assert_eq!(
            github_archive("https://github.com/o/r/tree/main/skills/pdf/").unwrap(),
            ("https://github.com/o/r/archive/main.zip".into(), "skills/pdf".into())
        );
        assert_eq!(github_archive("https://github.com/o/r/blob/main/a/SKILL.md").unwrap().1, "a");
        assert!(github_archive("https://example.com/o/r").is_none());
        assert!(github_archive("https://github.com/o/r/tree/main/../x").is_none());
    }

    #[test]
    fn plugin_paths_both_layouts() {
        let v2 = serde_json::json!({ "version": 2, "plugins": { "docs@market": [ { "installPath": "/p/docs/1.0" } ] } });
        let v1 = serde_json::json!({ "plugins": { "lint@m": { "installPath": "/p/lint" } } });
        assert_eq!(plugin_paths(&v2), vec![("docs".to_string(), PathBuf::from("/p/docs/1.0"))]);
        assert_eq!(plugin_paths(&v1), vec![("lint".to_string(), PathBuf::from("/p/lint"))]);
    }

    #[test]
    fn finds_nested_skills_and_copies_without_symlinks() {
        let root = tmp("find");
        std::fs::create_dir_all(root.join("pack/a")).unwrap();
        std::fs::create_dir_all(root.join("pack/b/scripts")).unwrap();
        std::fs::write(root.join("pack/a/SKILL.md"), "---\nname: a\n---").unwrap();
        std::fs::write(root.join("pack/b/SKILL.md"), "---\nname: b\n---").unwrap();
        std::fs::write(root.join("pack/b/scripts/x.sh"), "echo").unwrap();
        let found = find_skill_dirs(&root);
        assert_eq!(found, vec![root.join("pack/a"), root.join("pack/b")]);
        let out = root.join("copy");
        copy_dir(&root.join("pack/b"), &out).unwrap();
        assert_eq!(list_files(&out), vec!["SKILL.md".to_string(), "scripts/x.sh".to_string()]);
        let listed = skills_in(&root.join("pack"), "personal", None, true, true);
        assert_eq!(listed.len(), 2);
        assert!(listed.iter().any(|s| s.name == "b" && s.has_scripts));
        let _ = std::fs::remove_dir_all(&root);
    }
}
