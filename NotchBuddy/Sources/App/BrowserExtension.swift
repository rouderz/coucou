import AppKit

// Coucou's browser extensions (Chrome, Edge, Brave, Chromium, Arc): Coucou for WhaTicket and
// Coucou for AliExpress, two separate extensions on one native-messaging host. Same as
// windows/src-tauri/src/browser.rs.
//
// Setting it up puts three things in place:
//   • the unpacked extension in ~/Library/Application Support/NotchBuddy/browser-extension/, for the
//     user to load once from chrome://extensions or edge://extensions ("Load unpacked");
//   • coucou-native-host, a small python3 relay (like nb-hook) the browser starts when the
//     extension calls us: one length-prefixed JSON message in, forwarded to nb.sock, one answer out;
//   • the native-messaging host manifest in each browser's NativeMessagingHosts folder.
// Only our own extension id may start the host (`allowed_origins`).
//
// Not available in the App Store build: the sandbox can't write into other apps' folders.

/// One of Coucou's browser extensions: its files ship in the app (Resources/<resources>) and are
/// copied to ~/Library/Application Support/NotchBuddy/<dirName> for "Load unpacked".
struct ChromeExtension: Sendable {
    let name: String
    /// Fixed by the public `key` in the extension's manifest.json.
    let id: String
    let resources: String
    let dirName: String
    let files: [String]

    var dir: URL { HookServer.supportDir.appendingPathComponent(dirName) }

    /// The extension files shipped in the app.
    func bundled(_ file: String) -> Data? {
        let base = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        return Bundle.main.url(forResource: base, withExtension: ext, subdirectory: resources)
            .flatMap { try? Data(contentsOf: $0) }
    }

    /// The extension files are written and match the ones in this build.
    var installed: Bool {
        files.allSatisfy { file in
            guard let mine = bundled(file) else { return false }
            return (try? Data(contentsOf: dir.appendingPathComponent(file))) == mine
        }
    }
}

enum BrowserExtension {
    static let host = "fr.louisraille.coucou"

    /// Coucou for WhaTicket (extensions/whaticket).
    static let whaticket = ChromeExtension(
        name: "Coucou for WhaTicket", id: "jcdddeeehgafiakcgaabpiocfdijekce", resources: "whaticket",
        dirName: "browser-extension", files: ["manifest.json", "background.js", "content.js"])
    /// Coucou for AliExpress (extensions/aliexpress): a separate extension on the same host.
    static let aliexpress = ChromeExtension(
        name: "Coucou for AliExpress", id: "fkdhifnmpmkjgkaacobdgohnnnlpgmil", resources: "aliexpress",
        dirName: "aliexpress-extension", files: ["manifest.json", "background.js", "content.js", "aliexpress-core.js"])
    static let all = [whaticket, aliexpress]

    // The WhaTicket extension, as before.
    static var extensionID: String { whaticket.id }
    static var extensionDir: URL { whaticket.dir }
    static var installed: Bool { whaticket.installed }

    static var hostScriptURL: URL { HookServer.supportDir.appendingPathComponent("coucou-native-host") }

    /// (name, the browser's folder under ~/Library/Application Support)
    static let browsers: [(String, String)] = [
        ("Chrome", "Google/Chrome"),
        ("Chrome Beta", "Google/Chrome Beta"),
        ("Edge", "Microsoft Edge"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Chromium", "Chromium"),
        ("Arc", "Arc/User Data"),
        ("Vivaldi", "Vivaldi"),
    ]

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// The host manifest the browsers read: either of our extensions may start the host.
    static func hostManifest(path: String) -> String {
        let body: [String: Any] = [
            "name": host,
            "description": "Coucou — WhaTicket and AliExpress in the notch",
            "path": path,
            "type": "stdio",
            "allowed_origins": all.map { "chrome-extension://\($0.id)/" },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Browsers the host is registered with, and that let `ext` in (an older manifest only knew WhaTicket).
    static func registered(for ext: ChromeExtension) -> [String] {
        browsers.filter { _, folder in
            let url = appSupport.appendingPathComponent(folder).appendingPathComponent("NativeMessagingHosts/\(host).json")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains(ext.id)
        }.map(\.0)
    }
    static var registered: [String] { registered(for: whaticket) }

    /// Read once per extension (the card and the status light ask on every render), again after `install`.
    nonisolated(unsafe) private static var setUp: [String: Bool] = [:]

    static func isSetUp(_ ext: ChromeExtension) -> Bool {
        #if APPSTORE
        return false
        #else
        if let known = setUp[ext.id] { return known }
        let now = ext.installed && !registered(for: ext).isEmpty
        setUp[ext.id] = now
        return now
        #endif
    }
    static var isSetUp: Bool { isSetUp(whaticket) }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    /// Writes the extension, the relay and the host manifests. Returns the browsers set up.
    @discardableResult
    static func install(_ ext: ChromeExtension = whaticket) throws -> [String] {
        #if APPSTORE
        throw Failure.message(L("The browser extension isn't available in the App Store version."))
        #else
        defer { setUp = [:] }
        let fm = FileManager.default
        try fm.createDirectory(at: ext.dir, withIntermediateDirectories: true)
        for file in ext.files {
            guard let data = ext.bundled(file) else {
                throw Failure.message(L("This build of Coucou doesn't include the browser extension."))
            }
            try data.write(to: ext.dir.appendingPathComponent(file), options: .atomic)
        }
        try nativeHostScript.write(to: hostScriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: hostScriptURL.path)

        let manifest = hostManifest(path: hostScriptURL.path)
        var done: [String] = []
        for (name, folder) in browsers {
            let root = appSupport.appendingPathComponent(folder)
            // Only browsers this user actually has: their folder exists.
            guard fm.fileExists(atPath: root.path) else { continue }
            let hosts = root.appendingPathComponent("NativeMessagingHosts")
            do {
                try fm.createDirectory(at: hosts, withIntermediateDirectories: true)
                try manifest.write(to: hosts.appendingPathComponent("\(host).json"), atomically: true, encoding: .utf8)
                done.append(name)
            } catch {
                continue
            }
        }
        guard !done.isEmpty else {
            throw Failure.message(L("No Chrome, Edge, Brave or Chromium found for this user"))
        }
        return done
        #endif
    }

    static func reveal(_ ext: ChromeExtension = whaticket) {
        NSWorkspace.shared.activateFileViewerSelecting([ext.dir])
    }
}

/// coucou-native-host: the browser's door into Coucou. Chrome / Edge start it with the extension's
/// origin as the first argument and speak native messaging on stdin / stdout (a 4-byte native-endian
/// length, then UTF-8 JSON). It forwards the one message to nb.sock as a `WhaTicketBrowser` event and
/// hands Coucou's answer back — or says Coucou isn't running.
private let nativeHostScript = """
#!/usr/bin/env python3
# coucou-native-host — native-messaging host for the Coucou browser extensions (WhaTicket, AliExpress).
import sys, json, os, socket, struct

MAX = 1 << 20

def read_message():
    head = sys.stdin.buffer.read(4)
    if len(head) != 4:
        return None
    size = struct.unpack('=I', head)[0]
    if size == 0 or size > MAX:
        return None
    body = sys.stdin.buffer.read(size)
    if len(body) != size:
        return None
    try:
        value = json.loads(body)
    except Exception:
        return None
    return value if isinstance(value, dict) else None

def write_message(value):
    data = json.dumps(value).encode()
    sys.stdout.buffer.write(struct.pack('=I', len(data)) + data)
    sys.stdout.buffer.flush()

def main():
    message = read_message()
    if message is None:
        write_message({'error': 'bad message'})
        return
    message['hook_event_name'] = 'WhaTicketBrowser'
    message['origin'] = sys.argv[1] if len(sys.argv) > 1 else ''
    path = os.environ.get('COUCOU_SOCKET') or os.path.expanduser(
        '~/Library/Application Support/NotchBuddy/nb.sock'
    )
    answer = None
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect(path)
        s.sendall((json.dumps(message) + '\\n').encode())
        chunks = []
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
            if b'\\n' in chunk:
                break
        s.close()
        text = b''.join(chunks).decode().strip()
        answer = json.loads(text) if text else None
    except Exception:
        answer = None
    if not isinstance(answer, dict):
        answer = {'unreachable': "Coucou isn't running"}
    write_message(answer)

main()
"""
