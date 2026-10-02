import AppKit
import Foundation

// Skills: every skill Claude Code (and Codex) can use on this Mac, and an easy way to add one.
//
//   personal  ~/.claude/skills/<name>/SKILL.md
//   project   <project>/.claude/skills/<name>/SKILL.md   (projects of the sessions Coucou has seen)
//   plugin    <installPath>/skills/<name>/SKILL.md       (~/.claude/plugins/installed_plugins.json)
//   codex     ~/.codex/skills/<name>/SKILL.md
//
// Turning a skill off moves its folder to a sibling `skills-disabled/` (Claude Code only reads
// `skills/<name>/SKILL.md`), so nothing is ever deleted. Plugin skills are read-only.
// Adding stages a folder, a .zip / .skill file or a GitHub link, shows what's in it, and copies
// it only on a click. Coucou never runs a skill's scripts. Same behaviour as windows/src-tauri/src/skills.rs.

struct SkillInfo: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable { case personal, project, plugin, codex }
    var id: String { path }
    let name: String
    let description: String
    let source: Source
    /// The project folder, or the plugin's name.
    let origin: String?
    /// The skill's folder.
    let path: String
    let enabled: Bool
    let editable: Bool
    let hasScripts: Bool
}

/// A skill picked with "/" in the chat; its SKILL.md goes with the next question.
struct SkillRef: Equatable, Sendable {
    let name: String
    let path: String
}

struct StagedSkill: Identifiable, Sendable {
    var id: String { dest }
    let name: String
    let description: String
    let files: [String]
    let hasScripts: Bool
    let source: String
    let dest: String
    let exists: Bool
}

struct SkillPreview: Sendable {
    let staging: String
    let skills: [StagedSkill]
}

enum SkillError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

// MARK: - Pure helpers (tested in LogicTests)

enum SkillFiles {
    static let disabledDir = "skills-disabled"
    static let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "py", "js", "mjs", "cjs", "ts", "ps1", "psm1",
                                                "bat", "cmd", "exe", "rb", "pl", "php"]

    /// `name` and `description` from a SKILL.md's YAML front matter (quoted values and `>` / `|` blocks).
    static func frontMatter(_ raw: String) -> (name: String?, description: String?) {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }
        lines.removeFirst()
        var body: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            body.append(line)
        }
        func indented(_ l: String) -> Bool { l.hasPrefix(" ") || l.hasPrefix("\t") }
        var name: String?, description: String?
        var i = 0
        while i < body.count {
            let line = body[i]
            i += 1
            guard !indented(line), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value.hasPrefix(">") || value.hasPrefix("|") {
                let literal = value.hasPrefix("|")
                var parts: [String] = []
                while i < body.count, indented(body[i]) || body[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    let t = body[i].trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { parts.append(t) }
                    i += 1
                }
                value = parts.joined(separator: literal ? "\n" : " ")
            } else {
                value = unquote(value)
            }
            guard !value.isEmpty else { continue }
            if key == "name" { name = value }
            if key == "description" { description = value }
        }
        return (name, description)
    }

    static func unquote(_ v: String) -> String {
        guard v.count >= 2, let f = v.first, let l = v.last, f == l, f == "\"" || f == "'" else { return v }
        let inner = String(v.dropFirst().dropLast())
        return f == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
                         : inner.replacingOccurrences(of: "''", with: "'")
    }

    /// A safe folder name: lowercase letters, digits, `-` and `_`.
    static func folderName(_ name: String) -> String {
        var out = ""
        for c in name.trimmingCharacters(in: .whitespaces) {
            if c.isASCII, c.isLetter || c.isNumber || c == "_" {
                out.append(Character(c.lowercased()))
            } else if c == "-" || c == " " || c == ".", !out.isEmpty, !out.hasSuffix("-") {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "skill" : out
    }

    static func isScript(_ rel: String) -> Bool {
        let lower = rel.lowercased()
        if lower.hasPrefix("scripts/") || lower.contains("/scripts/") { return true }
        return scriptExtensions.contains((lower as NSString).pathExtension)
    }

    /// `https://github.com/owner/repo[/tree/<ref>/<path>]` → (zip URL, sub-path inside the archive).
    static func githubArchive(_ link: String) -> (url: URL, subpath: String)? {
        var s = link.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        guard s.hasPrefix("https://github.com/") else { return nil }
        let parts = s.dropFirst("https://github.com/".count).split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let safe = { (p: String) in !p.isEmpty && p.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        guard safe(parts[0]), safe(repo) else { return nil }
        var ref = "HEAD", sub = ""
        if parts.count >= 4, parts[2] == "tree" || parts[2] == "blob" {
            ref = parts[3]
            sub = parts.dropFirst(4).joined(separator: "/")
            if sub == "SKILL.md" { sub = "" } else if sub.hasSuffix("/SKILL.md") { sub.removeLast("/SKILL.md".count) }
        }
        guard safe(ref), !sub.split(separator: "/").contains("..") else { return nil }
        guard let url = URL(string: "https://github.com/\(parts[0])/\(repo)/archive/\(ref).zip") else { return nil }
        return (url, sub)
    }

    /// Plugins from installed_plugins.json (v1 and v2 layouts): (plugin name, install folder).
    static func pluginPaths(_ json: Any) -> [(String, String)] {
        guard let root = json as? [String: Any], let plugins = root["plugins"] as? [String: Any] else { return [] }
        var out: [(String, String)] = []
        for key in plugins.keys.sorted() {
            let name = String(key.split(separator: "@").first ?? Substring(key))
            guard let value = plugins[key] else { continue }
            let entries: [Any] = (value as? [Any]) ?? [value]
            for e in entries {
                if let path = (e as? [String: Any])?["installPath"] as? String { out.append((name, path)) }
            }
        }
        return out
    }

    /// Skills whose name or description match what follows "/" (enabled ones, names first).
    static func match(_ skills: [SkillInfo], typed: String) -> [SkillInfo] {
        let q = (typed.hasPrefix("/") ? String(typed.dropFirst()) : typed).trimmingCharacters(in: .whitespaces).lowercased()
        let on = skills.filter(\.enabled)
        guard !q.isEmpty else { return Array(on.prefix(6)) }
        let starts = on.filter { $0.name.lowercased().hasPrefix(q) }
        let rest = on.filter { s in !starts.contains(s) && "\(s.name) \(s.description)".lowercased().contains(q) }
        return Array((starts + rest).prefix(6))
    }

    /// The question sent with a picked skill: its instructions, then the request.
    static func withSkill(name: String, path: String, content: String, query: String) -> String {
        "Use the skill \"\(name)\" for this request (its folder: \(path)). Its instructions:\n\n<skill>\n"
            + content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n</skill>\n\nRequest: \(query)"
    }

    // MARK: File system

    static func readSkillMD(_ dir: URL) -> String? {
        let file = dir.appendingPathComponent("SKILL.md")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber,
              size.intValue <= 512 * 1024 else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// Files under `dir`, relative and sorted, without symlinks; at most 500.
    static func listFiles(_ dir: URL) -> [String] {
        let base = dir.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: dir.resolvingSymlinksInPath(),
                                                           includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { walker.skipDescendants(); continue }
            guard values?.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            if path.hasPrefix(base + "/") { out.append(String(path.dropFirst(base.count + 1))) }
            if out.count >= 500 { break }
        }
        return out.sorted()
    }

    /// The folders under `root` holding a SKILL.md: `root` itself or sub-folders, up to 4 deep.
    static func findSkillDirs(_ root: URL, depth: Int = 0) -> [URL] {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("SKILL.md").path) { return [root] }
        guard depth < 4,
              let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else { return [] }
        return items
            .filter { url in
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return v?.isDirectory == true && v?.isSymbolicLink != true
                    && !url.lastPathComponent.hasPrefix(".") && url.lastPathComponent != "node_modules"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { findSkillDirs($0, depth: depth + 1) }
    }

    /// Copies a folder without its symlinks.
    static func copyDir(_ from: URL, to: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let v = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let dest = to.appendingPathComponent(item.lastPathComponent)
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true { try copyDir(item, to: dest) } else { try fm.copyItem(at: item, to: dest) }
        }
    }

    /// Drops symlinks and refuses anything that escaped `root` (zip-slip guard).
    static func sanitize(_ root: URL) throws {
        let base = root.resolvingSymlinksInPath().path
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                try? fm.removeItem(at: url)
                walker.skipDescendants()
                continue
            }
            let path = url.resolvingSymlinksInPath().path
            guard path == base || path.hasPrefix(base + "/") else {
                throw SkillError.message(L("The archive tries to write outside its folder."))
            }
        }
    }

    /// Extracts a .zip with ditto (refuses paths outside `dest`).
    static func unzip(_ zip: URL, to dest: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", zip.path, dest.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw SkillError.message(L("The archive couldn't be opened.")) }
    }
}

// MARK: - Store

@MainActor
final class SkillsStore: ObservableObject {
    static let shared = SkillsStore()

    @Published private(set) var skills: [SkillInfo] = []

    private let fm = FileManager.default
    private var home: URL { fm.homeDirectoryForCurrentUser }
    private var claudeDir: URL { home.appendingPathComponent(".claude") }
    private var codexDir: URL { home.appendingPathComponent(".codex") }
    private var supportDir: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Coucou")
    }
    private var stagingDir: URL { supportDir.appendingPathComponent("skills-staging") }

    // MARK: Projects we've seen

    private static let projectsKey = "skillsProjects"

    var projects: [String] { UserDefaults.standard.stringArray(forKey: Self.projectsKey) ?? [] }

    /// A Claude Code / Codex session ran in `cwd`: its .claude/skills show in Settings → Skills.
    static func noteProject(_ cwd: String) {
        guard cwd.hasPrefix("/") else { return }
        var list = UserDefaults.standard.stringArray(forKey: projectsKey) ?? []
        guard list.first != cwd else { return }
        list.removeAll { $0 == cwd }
        list.insert(cwd, at: 0)
        UserDefaults.standard.set(Array(list.prefix(30)), forKey: projectsKey)
    }

    // MARK: Listing

    private func scan(_ root: URL, source: SkillInfo.Source, origin: String?, enabled: Bool, editable: Bool) -> [SkillInfo] {
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return items.compactMap { dir in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let text = SkillFiles.readSkillMD(dir) else { return nil }
            let meta = SkillFiles.frontMatter(text)
            return SkillInfo(name: meta.name ?? dir.lastPathComponent,
                             description: meta.description ?? "",
                             source: source, origin: origin, path: dir.path,
                             enabled: enabled, editable: editable,
                             hasScripts: SkillFiles.listFiles(dir).contains(where: SkillFiles.isScript))
        }
    }

    private func installedPlugins() -> [(String, String)] {
        let file = claudeDir.appendingPathComponent("plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return SkillFiles.pluginPaths(json)
    }

    func refresh() {
        var out: [SkillInfo] = []
        for (base, source) in [(claudeDir, SkillInfo.Source.personal), (codexDir, .codex)] {
            out += scan(base.appendingPathComponent("skills"), source: source, origin: nil, enabled: true, editable: true)
            out += scan(base.appendingPathComponent(SkillFiles.disabledDir), source: source, origin: nil, enabled: false, editable: true)
        }
        for project in projects {
            let base = URL(fileURLWithPath: project).appendingPathComponent(".claude")
            let label = "\(URL(fileURLWithPath: project).lastPathComponent) — \(project)"
            out += scan(base.appendingPathComponent("skills"), source: .project, origin: label, enabled: true, editable: true)
            out += scan(base.appendingPathComponent(SkillFiles.disabledDir), source: .project, origin: label, enabled: false, editable: true)
        }
        var seen = Set<String>()
        for (plugin, path) in installedPlugins() where seen.insert(path).inserted {
            out += scan(URL(fileURLWithPath: path).appendingPathComponent("skills"), source: .plugin, origin: plugin, enabled: true, editable: false)
        }
        let rank: [SkillInfo.Source: Int] = [.personal: 0, .project: 1, .plugin: 2, .codex: 3]
        skills = out.sorted {
            (rank[$0.source]!, $0.origin ?? "", $0.name.lowercased()) < (rank[$1.source]!, $1.origin ?? "", $1.name.lowercased())
        }
    }

    /// Where a new skill can go: "personal", "codex" or a project folder.
    var targets: [(id: String, label: String)] {
        var out: [(id: String, label: String)] = [("personal", L("Claude Code — personal (~/.claude/skills)"))]
        if fm.fileExists(atPath: codexDir.path) { out.append(("codex", L("Codex (~/.codex/skills)"))) }
        for p in projects where fm.fileExists(atPath: p) {
            out.append((p, L("Project — \(URL(fileURLWithPath: p).lastPathComponent)")))
        }
        return out
    }

    private func base(for target: String) -> URL? {
        switch target {
        case "personal": return claudeDir
        case "codex": return codexDir
        default:
            var isDir: ObjCBool = false
            guard target.hasPrefix("/"), fm.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue else { return nil }
            return URL(fileURLWithPath: target).appendingPathComponent(".claude")
        }
    }

    // MARK: Reading, turning on and off

    /// The SKILL.md of a skill in the list (and only those).
    func read(_ skill: SkillInfo) -> String? {
        guard skills.contains(skill) else { return nil }
        return SkillFiles.readSkillMD(URL(fileURLWithPath: skill.path))
    }

    func read(_ ref: SkillRef) -> (content: String, path: String)? {
        guard let skill = skills.first(where: { $0.path == ref.path }), let text = read(skill) else { return nil }
        return (text, skill.path)
    }

    func setEnabled(_ skill: SkillInfo, _ on: Bool) throws {
        guard skill.editable, skill.enabled != on else { return }
        let dir = URL(fileURLWithPath: skill.path)
        let base = dir.deletingLastPathComponent().deletingLastPathComponent()
        let destRoot = base.appendingPathComponent(on ? "skills" : SkillFiles.disabledDir)
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
        let dest = destRoot.appendingPathComponent(dir.lastPathComponent)
        guard !fm.fileExists(atPath: dest.path) else {
            throw SkillError.message(L("There's already a skill with that folder name."))
        }
        try fm.moveItem(at: dir, to: dest)
        refresh()
    }

    // MARK: Adding

    /// Stages a folder, .zip / .skill file or GitHub link and says what installing it would do.
    func preview(source raw: String, target: String) async throws -> SkillPreview {
        let source = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespacesAndNewlines))
        guard let base = base(for: target) else { throw SkillError.message(L("Pick where to install it.")) }
        try? fm.removeItem(at: stagingDir)
        let stage = stagingDir.appendingPathComponent(UUID().uuidString)
        let content = stage.appendingPathComponent("content")
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        var searchRoot = content

        if source.hasPrefix("https://") {
            guard let archive = SkillFiles.githubArchive(source) else {
                throw SkillError.message(L("Only github.com links to a repository or a folder in one."))
            }
            let sub = archive.subpath
            var request = URLRequest(url: archive.url, timeoutInterval: 60)
            request.setValue("Coucou", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw SkillError.message(L("GitHub answered \(code) — check the link (public repos only).")) }
            guard data.count <= 50 * 1024 * 1024 else { throw SkillError.message(L("That repository is too big to be a skill (over 50 MB).")) }
            let zip = stage.appendingPathComponent("download.zip")
            try data.write(to: zip)
            try await Task.detached { try SkillFiles.unzip(zip, to: content); try SkillFiles.sanitize(content) }.value
            if let top = try fm.contentsOfDirectory(at: content, includingPropertiesForKeys: nil).first {
                searchRoot = sub.isEmpty ? top : top.appendingPathComponent(sub)
            }
        } else {
            let path = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path.path, isDirectory: &isDir) else { throw SkillError.message(L("Nothing there — check the path.")) }
            let ext = path.pathExtension.lowercased()
            if isDir.boolValue {
                try SkillFiles.copyDir(path, to: content)
            } else if path.lastPathComponent == "SKILL.md" {
                try SkillFiles.copyDir(path.deletingLastPathComponent(), to: content)
            } else if ext == "zip" || ext == "skill" {
                try await Task.detached { try SkillFiles.unzip(path, to: content); try SkillFiles.sanitize(content) }.value
            } else {
                throw SkillError.message(L("Drop a skill folder, a .zip or .skill file, or paste a GitHub link."))
            }
        }

        let dirs = SkillFiles.findSkillDirs(searchRoot)
        guard !dirs.isEmpty else {
            try? fm.removeItem(at: stage)
            throw SkillError.message(L("No SKILL.md in there, so it isn't a skill."))
        }
        let skillsRoot = base.appendingPathComponent("skills")
        let disabledRoot = base.appendingPathComponent(SkillFiles.disabledDir)
        let staged = dirs.prefix(50).map { dir -> StagedSkill in
            let meta = SkillFiles.frontMatter(SkillFiles.readSkillMD(dir) ?? "")
            let name = meta.name ?? dir.lastPathComponent
            let folder = SkillFiles.folderName(name)
            let files = SkillFiles.listFiles(dir)
            let dest = skillsRoot.appendingPathComponent(folder)
            return StagedSkill(name: name, description: meta.description ?? "", files: files,
                               hasScripts: files.contains(where: SkillFiles.isScript), source: dir.path, dest: dest.path,
                               exists: fm.fileExists(atPath: dest.path) || fm.fileExists(atPath: disabledRoot.appendingPathComponent(folder).path))
        }
        return SkillPreview(staging: stage.path, skills: staged)
    }

    /// Installs what `preview` staged — only ever after the user clicked Install. A skill being
    /// replaced goes to Coucou's own trash folder first.
    func install(_ preview: SkillPreview) throws {
        let stage = URL(fileURLWithPath: preview.staging)
        guard stage.path.hasPrefix(stagingDir.path + "/"), fm.fileExists(atPath: stage.path) else {
            throw SkillError.message(L("That preview expired — preview it again."))
        }
        for skill in preview.skills {
            let dest = URL(fileURLWithPath: skill.dest)
            let disabled = dest.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(SkillFiles.disabledDir).appendingPathComponent(dest.lastPathComponent)
            for existing in [dest, disabled] where fm.fileExists(atPath: existing.path) {
                let trash = supportDir.appendingPathComponent("skills-trash")
                    .appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(existing.lastPathComponent)")
                try fm.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: existing, to: trash)
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SkillFiles.copyDir(URL(fileURLWithPath: skill.source), to: dest)
        }
        try? fm.removeItem(at: stage)
        refresh()
    }

    func cancel(_ preview: SkillPreview) {
        try? fm.removeItem(at: URL(fileURLWithPath: preview.staging))
    }

    /// A new skill from a template, opened in the editor.
    func create(name: String, target: String) throws {
        guard let base = base(for: target) else { throw SkillError.message(L("Pick where to create it.")) }
        let folder = SkillFiles.folderName(name)
        let dir = base.appendingPathComponent("skills").appendingPathComponent(folder)
        guard !fm.fileExists(atPath: dir.path),
              !fm.fileExists(atPath: base.appendingPathComponent(SkillFiles.disabledDir).appendingPathComponent(folder).path) else {
            throw SkillError.message(L("A skill with that name already exists."))
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = "---\nname: \(folder)\ndescription: What this skill does and when Claude should use it (one or two sentences).\n---\n\n# \(name.trimmingCharacters(in: .whitespaces))\n\n## Steps\n\n1. …\n2. …\n"
        try body.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        refresh()
        open(dir.path)
    }

    func open(_ path: String) {
        if let editor = Editor.preferred(AppState.shared.preferredEditor) {
            editor.open(folder: path)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
