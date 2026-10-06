import AppKit
import os

// AliExpress: your orders grouped by the box they ship in, and one invoice per box.
//
// The Coucou browser extension (extensions/whaticket: aliexpress-core.js, aliexpress.js,
// aliexpress-bg.js) reads your own AliExpress order pages in Chrome / Edge, groups the orders by
// tracking number and checks in here through native messaging (kind "aliexpress"). Coucou shows the
// packages and answers with what to do — make a package's invoice, export a CSV, refresh — which
// the extension does in the browser, saving the files to Downloads/Coucou/AliExpress.
//
// Coucou makes no AliExpress requests of its own and stores no AliExpress credentials. The buyer
// details printed on the invoices are the user's own, kept in the Keychain.

struct AliPackage: Identifiable, Equatable, Sendable {
    var id: String { tracking }
    let tracking: String
    let carrier: String
    let status: String
    let lastEvent: String
    let lastTime: String
    let orders: [String]
    let items: Int
    let total: Double
    let currency: String

    var delivered: Bool { status.range(of: #"deliver|entreg"#, options: [.regularExpression, .caseInsensitive]) != nil }
    var totalText: String { (currency == "USD" ? "$" : currency + " ") + String(format: "%.2f", total) }
}

struct AliFile: Equatable, Sendable {
    let path: String
    let tracking: String?
    let number: String?
    let csv: Bool
}

/// The buyer details printed on the invoices (Settings → AliExpress).
struct AliBuyer: Codable, Equatable, Sendable {
    var name = ""
    var id = ""
    var address = ""
    var email = ""
    var phone = ""

    static let key = "aliexpress-buyer"
    static func load() -> AliBuyer {
        guard let text = Secrets.store.get(key), let data = text.data(using: .utf8),
              let b = try? JSONDecoder().decode(AliBuyer.self, from: data) else { return AliBuyer() }
        return b
    }
    func save() {
        guard let data = try? JSONEncoder().encode(self), let text = String(data: data, encoding: .utf8) else { return }
        Secrets.store.set(Self.key, value: text)
    }
    var dictionary: [String: String] { ["name": name, "id": id, "address": address, "email": email, "phone": phone] }
}

enum AliExpressRules {
    private static func text(_ v: Any?, max: Int = 200) -> String { String((v as? String ?? "").prefix(max)) }

    /// The packages of a check-in, keeping only well-formed ones.
    static func packages(_ msg: [String: Any]) -> [AliPackage] {
        let list = (msg["packages"] as? [[String: Any]] ?? []).compactMap { p -> AliPackage? in
            let tracking = text(p["tracking"], max: 60)
            guard validTracking(tracking) else { return nil }
            return AliPackage(tracking: tracking, carrier: text(p["carrier"], max: 60), status: text(p["status"], max: 120),
                              lastEvent: text(p["lastEvent"], max: 200), lastTime: text(p["lastTime"], max: 40),
                              orders: (p["orders"] as? [String] ?? []).filter { $0.allSatisfy(\.isNumber) }.prefix(50).map { $0 },
                              items: p["items"] as? Int ?? 0, total: (p["total"] as? NSNumber)?.doubleValue ?? 0,
                              currency: text(p["currency"], max: 4).isEmpty ? "USD" : text(p["currency"], max: 4))
        }
        return Array(list.prefix(200))
    }

    static func files(_ msg: [String: Any]) -> [AliFile] {
        (msg["files"] as? [[String: Any]] ?? []).compactMap { f in
            guard let path = f["path"] as? String, !path.isEmpty else { return nil }
            return AliFile(path: path, tracking: f["tracking"] as? String, number: f["number"] as? String, csv: f["csv"] as? Bool ?? false)
        }
    }

    /// Tracking numbers are letters and digits; nothing else goes back to the browser.
    static func validTracking(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 60 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

@MainActor
final class AliExpressBridge {
    static let shared = AliExpressBridge()
    static let id = "integration_aliexpress"
    private var queued: [[String: Any]] = []
    private var seenFiles: Set<String> = []
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "aliexpress")

    private var enabled: Bool { AppState.shared.activeIntegrations.contains(Self.id) }

    /// One check-in from the extension; the answer carries the queued commands.
    func handle(_ msg: [String: Any]) -> [String: Any] {
        guard enabled else { return ["commands": [Any](), "interval": 600] }
        let state = AppState.shared
        let packages = AliExpressRules.packages(msg)
        let before = Dictionary(uniqueKeysWithValues: state.aliPackages.map { ($0.tracking, $0.status) })
        state.aliPackages = packages
        state.aliOrders = msg["orders"] as? Int ?? 0
        state.aliSyncing = msg["syncing"] as? Bool ?? false
        state.aliSeenAt = .now
        state.aliLoaded = true

        // A file the extension just saved: say so once, so it can be opened.
        for f in AliExpressRules.files(msg) where !seenFiles.contains(f.path) {
            seenFiles.insert(f.path)
            state.aliLastFile = f
            state.aliBusy.remove(f.tracking ?? (f.csv ? "csv" : ""))
        }
        // A box delivered since the last check-in.
        let newlyDelivered = packages.first { p in
            guard p.delivered, let old = before[p.tracking] else { return false }
            return old.range(of: #"deliver|entreg"#, options: [.regularExpression, .caseInsensitive]) == nil
        }
        if let p = newlyDelivered {
            announce(L("Package delivered · \(p.carrier)"), p.tracking)
        }
        let commands = queued
        queued = []
        return ["commands": commands, "interval": commands.isEmpty ? 30 : 15]
    }

    // MARK: Actions (on a click)

    func makeInvoice(_ tracking: String) {
        guard AliExpressRules.validTracking(tracking) else { return }
        queued.append(["op": "invoice", "tracking": tracking, "buyer": AliBuyer.load().dictionary, "lang": Self.lang])
        AppState.shared.aliBusy.insert(tracking)
        log.info("invoice queued for a package")
    }

    func exportCSV() {
        queued.append(["op": "csv"])
        AppState.shared.aliBusy.insert("csv")
    }

    func sync() {
        queued.append(["op": "sync"])
    }

    private static var lang: String {
        // The language the interface runs in (Settings → Language, or the Mac's).
        (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("es") ? "es" : "en"
    }

    private func announce(_ label: String, _ detail: String?) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.id }) else { return }
        state.tasks[idx].state = .finished
        state.tasks[idx].steps = detail.map { [label, $0] } ?? [label]
        if state.focusId != Self.id { state.tasks[idx].pillBadge = .finished }
        guard !DoNotDisturb.shared.isActive else { return }
        SoundEngine.shared.play("finish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = state.tasks.firstIndex(where: { $0.id == Self.id }), state.tasks[i].state == .finished else { return }
            state.tasks[i].state = .idle
            state.tasks[i].steps = []
            state.tasks[i].pillBadge = nil
        }
    }
}
