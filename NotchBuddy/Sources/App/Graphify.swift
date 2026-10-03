import AppKit
import Foundation

// Graphify (https://github.com/Graphify-Labs/graphify): a knowledge graph of each project.
//
// Coucou finds the `graphify` CLI, shows the state of each project's `graphify-out/`
// (none / fresh / stale against git) and runs Build / Update on a click. Rules:
//   - Coucou never installs Python packages: it only shows the install command.
//   - Builds use `--code-only` (tree-sitter, local, no LLM, no network).
//   - Nothing is written in a project except `graphify-out/`. No `--watch` process, no git hooks.
// Same logic as windows/src/core/graphify.ts (pure functions, tested in GraphifyTests).

struct GraphifyVersion: Equatable, Comparable, Sendable {
    let major: Int, minor: Int, patch: Int
    static func < (a: GraphifyVersion, b: GraphifyVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
    var text: String { "\(major).\(minor).\(patch)" }
}

enum GraphifyCLIStatus: Equatable, Sendable {
    case missing
    case unknown(path: String)
    case old(path: String, version: GraphifyVersion, min: GraphifyVersion)
    case ok(path: String, version: GraphifyVersion)
}

enum GraphifyGraphStatus: Equatable, Sendable {
    case none
    case unknown
    case fresh
    case stale(changed: Int, sample: [String])
}

struct GraphifyStamp: Equatable, Sendable {
    let commit: String
    let builtAt: Double
}

// MARK: - Pure helpers (tested in GraphifyTests)

enum GraphifyLogic {
    static let installCommand = "uv tool install graphifyy"
    static let outDir = "graphify-out"
    /// Written by Coucou after a successful build, inside graphify-out/.
    static let stampFile = ".coucou-build.json"
    /// Default size cap (characters) of a `graphify query` result attached to a chat.
    static let queryCap = 6000

    /// Full paths where `graphify` may live, best first: PATH, uv's tool bin dir, ~/.local/bin.
    static func cliCandidates(home: String, env: [String: String]) -> [String] {
        var dirs: [String] = []
        for d in (env["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let t = d.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { dirs.append(t) }
        }
        for key in ["UV_TOOL_BIN_DIR", "XDG_BIN_HOME"] {
            if let d = env[key]?.trimmingCharacters(in: .whitespaces), !d.isEmpty { dirs.append(d) }
        }
        if !home.isEmpty { dirs.append(home + "/.local/bin") }
        var seen = Set<String>()
        var out: [String] = []
        for d in dirs where seen.insert(d).inserted {
            out.append(d.hasSuffix("/") ? d + "graphify" : d + "/graphify")
        }
        return out
    }

    /// The first `x.y.z` in `graphify --version` output ("graphify 0.4.2", "v0.4.2", "0.4").
    static func parseVersion(_ output: String) -> GraphifyVersion? {
        guard let re = try? NSRegularExpression(pattern: #"(\d+)\.(\d+)(?:\.(\d+))?"#) else { return nil }
        let ns = output as NSString
        guard let m = re.firstMatch(in: output, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func num(_ i: Int) -> Int {
            let r = m.range(at: i)
            return r.location == NSNotFound ? 0 : Int(ns.substring(with: r)) ?? 0
        }
        return GraphifyVersion(major: num(1), minor: num(2), patch: num(3))
    }

    /// `versionOutput` is what `<path> --version` printed, or nil if it didn't run.
    static func cliStatus(path: String?, versionOutput: String?, min: GraphifyVersion? = nil) -> GraphifyCLIStatus {
        guard let path else { return .missing }
        guard let output = versionOutput, let version = parseVersion(output) else { return .unknown(path: path) }
        if let min, version < min { return .old(path: path, version: version, min: min) }
        return .ok(path: path, version: version)
    }

    static func isCommit(_ s: String) -> Bool {
        (7...64).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// Coucou's own stamp file. Anything unexpected is nil (the graph then counts as unknown).
    static func parseStamp(_ text: String) -> GraphifyStamp? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commit = obj["commit"] as? String, isCommit(commit) else { return nil }
        return GraphifyStamp(commit: commit, builtAt: (obj["builtAt"] as? Double) ?? 0)
    }

    static func stampText(commit: String, builtAt: Double) -> String {
        "{\"commit\":\"\(commit)\",\"builtAt\":\(Int(builtAt))}"
    }

    /// Node and edge counts from graph.json. graphify doesn't document the format, so this is best
    /// effort: `nodes` and `edges` (or `links`) as arrays or objects; otherwise nil.
    static func parseGraphCounts(_ text: String) -> (nodes: Int, edges: Int)? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func size(_ v: Any?) -> Int? {
            if let a = v as? [Any] { return a.count }
            if let d = v as? [String: Any] { return d.count }
            return nil
        }
        guard let nodes = size(obj["nodes"]) else { return nil }
        return (nodes, size(obj["edges"] ?? obj["links"]) ?? 0)
    }

    /// git arguments for the files changed between the build and HEAD. Nil for anything that isn't a commit id.
    static func changedFilesArgs(commit: String) -> [String]? {
        isCommit(commit) ? ["diff", "--name-only", "\(commit)..HEAD"] : nil
    }

    /// When there is no stamp: the last commit made before graph.json was written.
    static func builtAtCommitArgs(graphMtime: Double) -> [String] {
        ["rev-list", "-1", "--before=\(Int(max(0, graphMtime.rounded(.down))))", "HEAD"]
    }

    /// Lines of `git diff --name-only`, without graphify-out/ (our own output isn't a change).
    static func parseChangedFiles(_ stdout: String) -> [String] {
        stdout.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/") }
            .filter { !$0.isEmpty && $0 != outDir && !$0.hasPrefix(outDir + "/") }
    }

    /// `changed` is parseChangedFiles of the diff, or nil when git couldn't answer.
    static func graphStatus(hasGraph: Bool, changed: [String]?, sampleSize: Int = 5) -> GraphifyGraphStatus {
        guard hasGraph else { return .none }
        guard let changed else { return .unknown }
        if changed.isEmpty { return .fresh }
        return .stale(changed: changed.count, sample: Array(changed.prefix(sampleSize)))
    }

    /// Cleans and caps `graphify query` output (cap in characters): cut at a line, say how much was left out.
    static func trimQueryOutput(_ raw: String, cap: Int = queryCap) -> String {
        var text = raw
        if let re = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]") {
            text = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        func len(_ s: String) -> Int { s.unicodeScalars.count }
        if len(text) <= cap { return text }
        let lines = text.components(separatedBy: "\n")
        func marker(_ n: Int) -> String { "\n… \(n) more lines left out (capped at \(cap) characters)" }
        let room = max(0, cap - len(marker(lines.count)))
        var kept: [String] = []
        var used = 0
        for line in lines {
            let add = len(line) + (kept.isEmpty ? 0 : 1)
            if used + add > room { break }
            kept.append(line)
            used += add
        }
        if kept.isEmpty {
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: lines[0].unicodeScalars.prefix(max(0, cap - 1)))
            return String(scalars) + "…"
        }
        return kept.joined(separator: "\n") + marker(lines.count - kept.count)
    }
}

// MARK: - Store

struct GraphifyProject: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    var status: GraphifyGraphStatus
    var counts: String?
    var hasReport: Bool
}

@MainActor
final class GraphifyStore: ObservableObject {
    static let shared = GraphifyStore()

    @Published private(set) var cli: GraphifyCLIStatus = .missing
    @Published private(set) var projects: [GraphifyProject] = []
    /// The project being built, if any.
    @Published private(set) var building: String?
    @Published private(set) var message: String?
    @Published private(set) var isError = false

    private var process: Process?

    /// Looks for the CLI and reads each known project's graph. Nothing is run besides `--version` and `git`.
    func refresh() {
        let paths = SkillsStore.shared.projects
        Task.detached(priority: .utility) {
            let cli = Self.detectCLI()
            let projects = paths.filter { FileManager.default.fileExists(atPath: $0) }.map(Self.readProject)
            await MainActor.run {
                GraphifyStore.shared.cli = cli
                GraphifyStore.shared.projects = projects
            }
        }
    }

    /// Build (first time) or update (incremental) with `--code-only`: local, no LLM, no network.
    func build(_ project: GraphifyProject) {
        guard building == nil, case .ok(let exe, _) = cli else { return }
        let path = project.path
        building = path
        message = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["update", ".", "--code-only"]
        p.currentDirectoryURL = URL(fileURLWithPath: path)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            let cancelled = proc.terminationReason == .uncaughtSignal
            Task { @MainActor in GraphifyStore.shared.finished(path: path, status: status, cancelled: cancelled) }
        }
        do {
            try p.run()
            process = p
        } catch {
            building = nil
            fail(L("Couldn't start graphify."))
        }
    }

    func cancel() { process?.terminate() }

    func openGraph(_ project: GraphifyProject) {
        let url = URL(fileURLWithPath: project.path).appendingPathComponent("\(GraphifyLogic.outDir)/graph.html")
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }

    private func finished(path: String, status: Int32, cancelled: Bool) {
        process = nil
        building = nil
        if cancelled {
            fail(L("Build cancelled."))
        } else if status != 0 {
            fail(L("graphify stopped with an error. Run it in a terminal to see why."))
        } else {
            // Remember which commit the graph matches, inside graphify-out/ (the only place we write).
            Task.detached(priority: .utility) {
                if let head = Self.git(path, ["rev-parse", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                   GraphifyLogic.isCommit(head) {
                    let file = URL(fileURLWithPath: path).appendingPathComponent("\(GraphifyLogic.outDir)/\(GraphifyLogic.stampFile)")
                    try? GraphifyLogic.stampText(commit: head, builtAt: Date().timeIntervalSince1970)
                        .write(to: file, atomically: true, encoding: .utf8)
                }
                await MainActor.run { GraphifyStore.shared.refresh() }
            }
            isError = false
            message = L("Graph updated.")
        }
    }

    private func fail(_ text: String) {
        isError = true
        message = text
    }

    // MARK: Off the main thread

    nonisolated private static func detectCLI() -> GraphifyCLIStatus {
        #if APPSTORE
        return .missing
        #else
        let home = NSHomeDirectory()
        let candidates = GraphifyLogic.cliCandidates(home: home, env: ProcessInfo.processInfo.environment)
        // The shell's PATH (Homebrew, pipx, uv) is honoured by CLITool.locate; the candidates are the fallback.
        guard let found = CLITool.locate("graphify", fallbacks: candidates) else { return .missing }
        let out = CLITool.run(found.path, ["--version"], environment: ["PATH": found.pathEnv], timeout: 8)
        return GraphifyLogic.cliStatus(path: found.path, versionOutput: out?.status == 0 ? out?.stdout : nil)
        #endif
    }

    nonisolated private static func git(_ dir: String, _ args: [String]) -> String? {
        #if APPSTORE
        return nil
        #else
        guard let out = CLITool.run("/usr/bin/git", ["-C", dir] + args, timeout: 8), out.status == 0 else { return nil }
        return out.stdout
        #endif
    }

    nonisolated private static func readProject(_ path: String) -> GraphifyProject {
        let fm = FileManager.default
        let out = URL(fileURLWithPath: path).appendingPathComponent(GraphifyLogic.outDir)
        let graph = out.appendingPathComponent("graph.json")
        let hasGraph = fm.fileExists(atPath: graph.path)
        let hasReport = fm.fileExists(atPath: out.appendingPathComponent("GRAPH_REPORT.md").path)
        guard hasGraph else { return GraphifyProject(path: path, status: .none, counts: nil, hasReport: hasReport) }

        var counts: String?
        if let size = (try? fm.attributesOfItem(atPath: graph.path)[.size]) as? Int, size < 50_000_000,
           let text = try? String(contentsOf: graph, encoding: .utf8), let c = GraphifyLogic.parseGraphCounts(text) {
            counts = L("\(c.nodes) nodes · \(c.edges) edges")
        }

        // The commit the graph was built at: our stamp, else the last commit before graph.json was written.
        var commit: String?
        if let text = try? String(contentsOf: out.appendingPathComponent(GraphifyLogic.stampFile), encoding: .utf8) {
            commit = GraphifyLogic.parseStamp(text)?.commit
        }
        if commit == nil, let mtime = (try? fm.attributesOfItem(atPath: graph.path)[.modificationDate]) as? Date,
           let rev = git(path, GraphifyLogic.builtAtCommitArgs(graphMtime: mtime.timeIntervalSince1970))?
               .trimmingCharacters(in: .whitespacesAndNewlines), GraphifyLogic.isCommit(rev) {
            commit = rev
        }
        var changed: [String]?
        if let commit, let args = GraphifyLogic.changedFilesArgs(commit: commit), let diff = git(path, args) {
            changed = GraphifyLogic.parseChangedFiles(diff)
        }
        return GraphifyProject(path: path, status: GraphifyLogic.graphStatus(hasGraph: true, changed: changed),
                               counts: counts, hasReport: hasReport)
    }
}
