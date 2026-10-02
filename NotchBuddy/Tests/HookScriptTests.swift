import XCTest
@testable import Coucou

/// Runs the real nb-hook script against a fake Coucou socket and checks what it tells Claude Code.
final class HookScriptTests: XCTestCase {
    private var dir: URL!
    private var script: URL!
    private var socketPath: String!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/tmp/nbt-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        script = dir.appendingPathComponent("nb-hook")
        try HookServer.hookScriptSource.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        socketPath = dir.appendingPathComponent("s.sock").path  // short: sun_path is 104 bytes
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Permission decisions

    func testAllowDecision() throws {
        let out = try run(event: permission, reply: #"{"permissionDecision":"allow"}"#)
        XCTAssertEqual(decision(out)?["behavior"] as? String, "allow")
    }

    func testDenyDecisionCarriesAMessage() throws {
        let out = try run(event: permission, reply: #"{"permissionDecision":"deny"}"#)
        let d = decision(out)
        XCTAssertEqual(d?["behavior"] as? String, "deny")
        XCTAssertNotNil(d?["message"] as? String)
    }

    func testAlwaysPassesClaudeCodesSuggestedRules() throws {
        var event = permission
        event["permission_suggestions"] = [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                            "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]]]]
        let out = try run(event: event, reply: #"{"permissionDecision":"always"}"#)
        let d = decision(out)
        XCTAssertEqual(d?["behavior"] as? String, "allow")
        let rules = (d?["updatedPermissions"] as? [[String: Any]])?.first?["rules"] as? [[String: Any]]
        XCTAssertEqual(rules?.first?["ruleContent"] as? String, "npm test:*")
    }

    func testAskPrintsNothingSoClaudeCodeAsksInTheTerminal() throws {
        let out = try run(event: permission, reply: #"{"permissionDecision":"ask"}"#)
        XCTAssertTrue(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testNoAppRunningPrintsNothing() throws {
        let out = try run(event: permission, reply: nil)  // nothing listening on the socket
        XCTAssertTrue(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: Forwarding

    func testEventsAreForwardedWithTheirName() throws {
        let server = try FakeCoucou(path: socketPath, reply: #"{"ok":true}"#)
        _ = try exec(["hook_event_name": "PreToolUse", "tool_name": "Read", "session_id": "s1", "cwd": "/tmp"])
        let got = server.received()
        XCTAssertEqual(got?["hook_event_name"] as? String, "PreToolUse")
        XCTAssertEqual(got?["session_id"] as? String, "s1")
    }

    func testMochisOwnChatOnlyForwardsApprovals() throws {
        let server = try FakeCoucou(path: socketPath, reply: #"{"ok":true}"#)
        _ = try exec(["hook_event_name": "PreToolUse", "tool_name": "Read"], fromChat: true)
        XCTAssertNil(server.received(timeout: 0.5), "chat activity must not reach the island")

        let server2 = try FakeCoucou(path: socketPath, reply: #"{"permissionDecision":"allow"}"#)
        _ = try exec(permission, fromChat: true)
        XCTAssertEqual(server2.received()?["coucou_internal"] as? Bool, true)
    }

    // MARK: Codex CLI (#44)

    func testCodexEventsAreTagged() throws {
        let server = try FakeCoucou(path: socketPath, reply: #"{"ok":true}"#)
        _ = try exec(["hook_event_name": "PreToolUse", "tool_name": "apply_patch", "session_id": "c1"],
                     args: ["--agent", "codex"])
        XCTAssertEqual(server.received()?["agent"] as? String, "codex")
    }

    func testAlwaysWithoutSuggestionsIsAPlainAllow() throws {
        let out = try run(event: permission, reply: #"{"permissionDecision":"always"}"#)
        let d = decision(out)
        XCTAssertEqual(d?["behavior"] as? String, "allow")
        XCTAssertNil(d?["updatedPermissions"], "Codex has no rules to save")
    }

    // MARK: Transport (#17)

    func testUnixSocketTransportCarriesTheDecision() throws {
        let transport = UnixSocketTransport(path: socketPath)
        let got = Got()
        transport.start { raw, connection in
            got.set((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any])
            connection.reply(#"{"permissionDecision":"deny"}"#)
        }
        Thread.sleep(forTimeInterval: 0.3)  // let it bind
        let out = try exec(permission)
        XCTAssertEqual(decision(out)?["behavior"] as? String, "deny")
        XCTAssertEqual(got.value?["tool_name"] as? String, "Bash")
    }

    // MARK: Helpers

    private var permission: [String: Any] {
        ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "session_id": "s1", "cwd": "/tmp",
         "tool_input": ["command": "npm test"]]
    }

    private func run(event: [String: Any], reply: String?) throws -> String {
        let server = try reply.map { try FakeCoucou(path: socketPath, reply: $0) }
        defer { _ = server }
        return try exec(event)
    }

    private func exec(_ event: [String: Any], fromChat: Bool = false, args: [String] = []) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script.path] + args
        var env = ProcessInfo.processInfo.environment
        env["COUCOU_SOCKET"] = socketPath
        env["COUCOU_INTERNAL"] = fromChat ? "1" : nil
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: event))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func decision(_ out: String) -> [String: Any]? {
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let specific = json["hookSpecificOutput"] as? [String: Any] else { return nil }
        return specific["decision"] as? [String: Any]
    }
}

private final class Got: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Any]?
    func set(_ v: [String: Any]?) { lock.withLock { stored = v } }
    var value: [String: Any]? { lock.withLock { stored } }
}

/// A one-shot Unix socket server standing in for Coucou: reads one line, answers `reply`.
private final class FakeCoucou: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var line: [String: Any]?
    private let done = DispatchSemaphore(value: 0)

    init(path: String, reply: String) throws {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in path.utf8CString.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 && listen(fd, 1) == 0
            }
        }
        guard ok else { throw NSError(domain: "FakeCoucou", code: 1) }
        let server = fd
        Thread.detachNewThread { [self] in
            let client = accept(server, nil, nil)
            guard client >= 0 else { done.signal(); return }
            var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
            while !data.contains(UInt8(ascii: "\n")) {
                let n = recv(client, &buf, buf.count, 0)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
            }
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            lock.lock(); line = parsed; lock.unlock()
            _ = (reply + "\n").withCString { send(client, $0, strlen($0), 0) }
            close(client)
            done.signal()
        }
    }

    deinit { close(fd) }

    func received(timeout: TimeInterval = 5) -> [String: Any]? {
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return line
    }
}
