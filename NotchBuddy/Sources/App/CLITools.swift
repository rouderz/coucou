import Foundation

/// Finds and runs the user's command-line tools (`claude`, `gh`) the way their shell
/// would, so Homebrew, nvm and other custom PATHs work from a menu-bar app.
enum CLITool {
    /// Where a tool lives and the PATH it needs (taken from the user's login shell).
    struct Install: Sendable, Equatable {
        let path: String
        let pathEnv: String
    }

    /// Looks `name` up through the login shell first, then in `fallbacks`.
    /// Blocking (up to a few seconds): call it off the main thread.
    static func locate(_ name: String, fallbacks: [String]) -> Install? {
        #if APPSTORE
        return nil  // The sandbox can't launch other executables.
        #else
        let fm = FileManager.default
        var pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"

        // 1. Ask the user's shell, so nvm / Homebrew / custom PATHs are honoured.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__COUCOU__"
        if let out = run(shell, ["-ilc", "printf '\(marker)%s\\n\(marker)%s\\n' \"$(command -v \(name))\" \"$PATH\""],
                         timeout: 6)?.stdout {
            let values = out.components(separatedBy: "\n")
                .filter { $0.hasPrefix(marker) }
                .map { String($0.dropFirst(marker.count)) }
            if values.count == 2 {
                if !values[1].isEmpty { pathEnv = values[1] }
                if values[0].hasPrefix("/"), fm.isExecutableFile(atPath: values[0]) {
                    return Install(path: values[0], pathEnv: pathEnv)
                }
            }
        }

        // 2. Usual install locations.
        for path in fallbacks where fm.isExecutableFile(atPath: path) {
            let dir = (path as NSString).deletingLastPathComponent
            return Install(path: path, pathEnv: "\(dir):\(pathEnv)")
        }
        return nil
        #endif
    }

    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stdoutData: Data
    }

    /// Runs a short command and returns its output, or nil if it can't start or times out.
    /// Blocking: call it off the main thread.
    static func run(_ exe: String, _ args: [String],
                    environment: [String: String]? = nil,
                    timeout: TimeInterval) -> Output? {
        #if APPSTORE
        return nil
        #else
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let environment { p.environment = environment }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        // Read stdout while the process runs, so a large reply can't fill the pipe and stall it.
        final class Buffer: @unchecked Sendable { var data = Data(); let lock = NSLock() }
        let buffer = Buffer()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            buffer.lock.lock(); buffer.data.append(chunk); buffer.lock.unlock()
        }
        defer { out.fileHandleForReading.readabilityHandler = nil }

        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { p.terminate(); return nil }

        out.fileHandleForReading.readabilityHandler = nil
        let rest = out.fileHandleForReading.readDataToEndOfFile()
        buffer.lock.lock(); buffer.data.append(rest); let data = buffer.data; buffer.lock.unlock()
        return Output(status: p.terminationStatus,
                      stdout: String(data: data, encoding: .utf8) ?? "",
                      stdoutData: data)
        #endif
    }
}

// MARK: - GitHub CLI

/// Uses the user's signed-in GitHub CLI (`gh`) for the GitHub integration, so no
/// Personal Access Token is needed. Requests go through `gh api`: Coucou never reads,
/// stores or forwards the GitHub credential.
enum GitHubCLI {
    enum Status: Sendable, Equatable {
        case missing
        case signedOut
        case signedIn
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var install: CLITool.Install?
        var looked = false
    }
    private static let cache = Cache()

    /// Finds `gh` once per launch (or again with `force`). Blocking.
    static func locate(force: Bool = false) -> CLITool.Install? {
        cache.lock.lock()
        if cache.looked && !force { defer { cache.lock.unlock() }; return cache.install }
        cache.lock.unlock()

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let found = CLITool.locate("gh", fallbacks: [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "\(home)/.local/bin/gh",
            "/opt/local/bin/gh",
        ])
        cache.lock.lock()
        cache.install = found
        cache.looked = true
        cache.lock.unlock()
        return found
    }

    /// Whether `gh` is installed and signed in to github.com. Blocking.
    static func status(force: Bool = false) -> Status {
        guard let gh = locate(force: force) else { return .missing }
        let result = CLITool.run(gh.path, ["auth", "status", "--hostname", "github.com"],
                                 environment: environment(for: gh), timeout: 10)
        return result?.status == 0 ? .signedIn : .signedOut
    }

    /// `gh api <path>`: the parsed JSON body, or nil when gh is missing, signed out or fails.
    /// Blocking: call it off the main thread.
    static func api(_ path: String) -> Any? {
        guard let gh = locate() else { return nil }
        guard let out = CLITool.run(gh.path, ["api", path],
                                    environment: environment(for: gh), timeout: 20),
              out.status == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: out.stdoutData)
    }

    /// PATCH / POST / DELETE through gh (e.g. marking a notification as read). True on success.
    @discardableResult
    static func send(_ method: String, _ path: String) -> Bool {
        guard let gh = locate(),
              let out = CLITool.run(gh.path, ["api", "-X", method, path], environment: environment(for: gh), timeout: 20)
        else { return false }
        return out.status == 0
    }

    /// Any read-only `gh` command that prints JSON (e.g. `gh search prs … --json …`), parsed.
    /// Blocking: call it off the main thread.
    static func json(_ args: [String]) -> Any? {
        guard let gh = locate(),
              let out = CLITool.run(gh.path, args, environment: environment(for: gh), timeout: 25),
              out.status == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: out.stdoutData)
    }

    // MARK: Conditional requests (#8)

    private static let etagLock = NSLock()
    nonisolated(unsafe) private static var etagCache: [String: (etag: String, body: Data)] = [:]

    /// Like `api`, but sends the last ETag: unchanged data comes back as 304, which doesn't
    /// count against GitHub's rate limit, and the cached body is reused.
    static func apiCached(_ path: String) -> Any? {
        guard let gh = locate() else { return nil }
        etagLock.lock(); let cached = etagCache[path]; etagLock.unlock()

        var args = ["api", "--include", path]
        if let cached { args += ["-H", "If-None-Match: \(cached.etag)"] }
        guard let out = CLITool.run(gh.path, args, environment: environment(for: gh), timeout: 20) else { return nil }
        let response = GitHubHTTP.split(out.stdoutData)

        if response.status == 304, let cached {
            return try? JSONSerialization.jsonObject(with: cached.body)
        }
        guard out.status == 0, response.status == 200 else { return nil }
        if let etag = response.headers["etag"] {
            etagLock.lock(); etagCache[path] = (etag, response.body); etagLock.unlock()
        }
        return try? JSONSerialization.jsonObject(with: response.body)
    }

    private static func environment(for gh: CLITool.Install) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = gh.pathEnv
        env["GH_PROMPT_DISABLED"] = "1"     // never wait for input
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        env["GH_PAGER"] = "cat"
        return env
    }
}


/// Splits `gh api --include` output (status line, headers, blank line, body).
enum GitHubHTTP {
    static func split(_ data: Data) -> (status: Int, headers: [String: String], body: Data) {
        let crlf = Data("\r\n\r\n".utf8), lf = Data("\n\n".utf8)
        let r1 = data.range(of: crlf), r2 = data.range(of: lf)
        let sep = [r1, r2].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
        guard let sep else { return (0, [:], data) }
        let head = String(decoding: data[..<sep.lowerBound], as: UTF8.self)
        let body = data[sep.upperBound...]
        var lines = head.split(whereSeparator: \.isNewline).map(String.init)
        let statusLine = lines.isEmpty ? "" : lines.removeFirst()
        let parts = statusLine.split(separator: " ")
        let status = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (status, headers, Data(body))
    }
}
