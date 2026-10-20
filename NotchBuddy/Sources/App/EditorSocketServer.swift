import Foundation
import Network
import Security
import os

// MARK: - EditorSocketServer
// A local WebSocket for the editor plugins that can't open Lumo's Unix socket: Godot
// (GDScript has WebSocketPeer, no Unix sockets) and Aseprite (its Lua has a WebSocket client).
//
//   • Listens on 127.0.0.1 only — never on the network — on port 47615, or any free port.
//   • Every message carries a token that Lumo makes at launch and writes, with the port, to
//     ~/Library/Application Support/NotchBuddy/editor-bridge.json (mode 0600). Only the user's
//     own programs can read it, so a web page can't talk to Lumo even though it can reach localhost.
//   • Handshakes that come with a web Origin (a browser) are refused before any message.
//   • Only the editor events are accepted (`EditorContext`, `EditorAsk`): nothing that reaches
//     here can approve a Claude Code permission or touch a session.
//
// One JSON text message per event, the same shape as on the socket:
//   {"token":"…","hook_event_name":"EditorAsk","appName":"Godot","file":"/…/player.gd",
//    "workspace":"/…/my-game","language":"gdscript","line":12,"selection":"…",
//    "diagnostics":[…],"details":"…","image":"/tmp/…/frame.png"}
// Lumo answers {"ok":true} or {"ok":false,"error":"…"}.

final class EditorSocketServer: @unchecked Sendable {
    static let shared = EditorSocketServer()

    static let preferredPort: UInt16 = 47615
    static var infoPath: URL { HookServer.supportDir.appendingPathComponent("editor-bridge.json") }
    static let acceptedEvents: Set<String> = ["EditorContext", "EditorAsk"]
    private static let maxConnections = 8
    private static let maxMessage = 1 << 20

    private let queue = DispatchQueue(label: "fr.louisraille.NotchBuddy.editor-socket")
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "editor-socket")
    // Touched on `queue` only.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var token = ""

    private init() {}

    func start() {
        #if !APPSTORE
        queue.async { [self] in
            token = Self.makeToken()
            listen(on: Self.preferredPort)
        }
        #endif
    }

    // MARK: - Listening (queue)

    private func listen(on port: UInt16) {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = Self.maxMessage
        // A browser always sends its page's Origin (http/https): no web page gets past the
        // handshake. Godot sends none; Aseprite's IXWebSocket sends `ws://127.0.0.1:<port>`.
        ws.setClientRequestHandler(queue) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value.lowercased() ?? ""
            let fromWeb = origin.hasPrefix("http://") || origin.hasPrefix("https://")
            return NWProtocolWebSocket.Response(status: fromWeb ? .reject : .accept, subprotocol: nil)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                 port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            log.error("cannot open the editor socket: \(error.localizedDescription, privacy: .public)")
            if port != 0 { listen(on: 0) }
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                let actual = listener?.port?.rawValue ?? port
                self.writeInfo(port: actual)
                self.log.info("editor socket on 127.0.0.1:\(actual)")
            case .failed(let error):
                self.log.error("editor socket failed: \(error.localizedDescription, privacy: .public)")
                listener?.cancel()
                // Our port is taken (another app, or a second Lumo): any free one will do,
                // the plugins read it from editor-bridge.json.
                if port != 0 { self.listen(on: 0) }
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[id] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            switch meta?.opcode {
            case .close?:
                connection.cancel()
                return
            case .text?, .binary?:
                if let content { self.handle(content, on: connection) }
            default:
                break
            }
            self.receive(on: connection)
        }
    }

    // MARK: - Messages (queue)

    private func handle(_ data: Data, on connection: NWConnection) {
        guard var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return reply(["ok": false, "error": "not JSON"], on: connection)
        }
        guard let given = payload.removeValue(forKey: "token") as? String, Self.same(given, token) else {
            return reply(["ok": false, "error": "bad token: read it again from editor-bridge.json"], on: connection)
        }
        // A plugin checking that Lumo is there and the token is right.
        let event = payload["hook_event_name"] as? String ?? ""
        if event == "Ping" { return reply(["ok": true, "app": "Lumo"], on: connection) }
        guard Self.acceptedEvents.contains(event) else {
            return reply(["ok": false, "error": "unknown event"], on: connection)
        }
        let sendable = SendablePayload(payload)
        Task { @MainActor in EditorBridge.shared.handle(event: event, payload: sendable.value) }
        reply(["ok": true], on: connection)
    }

    private func reply(_ object: [String: Any], on connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "reply", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    // MARK: - Token and info file

    private func writeInfo(port: UInt16) {
        let info: [String: Any] = ["port": Int(port), "token": token, "version": 1]
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: HookServer.supportDir, withIntermediateDirectories: true)
        let path = Self.infoPath.path
        // Create it private, then write: the token is never readable by anyone else.
        fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try? data.write(to: Self.infoPath)
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison.
    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !y.isEmpty else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// JSON from JSONSerialization is plists of Foundation values: safe to hand to the main actor.
private struct SendablePayload: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}
