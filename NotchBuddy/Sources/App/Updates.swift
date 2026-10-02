import AppKit
import SwiftUI
import os

/// Update check (#40): compares this build with the latest release on GitHub and offers the DMG.
/// Installing stays manual (open the DMG, drag to Applications) until the app is signed (#38).
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()
    static let repo = "rouderz/coucou"

    struct Release: Equatable {
        let version: String
        let pageURL: String
        let dmgURL: String?
        let notes: String
        let published: Date?
    }

    @Published private(set) var latest: Release?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var checking = false
    @Published private(set) var error: String?

    private var timer: Timer?
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "updates")

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// A newer release than the running build, if any.
    var available: Release? {
        guard let latest, Self.isNewer(latest.version, than: Self.currentVersion) else { return nil }
        return latest
    }

    func start() {
        guard AppState.shared.updateChecks else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { Updates.shared.check(announce: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard AppState.shared.updateChecks else { return }
                Updates.shared.check(announce: true)
            }
        }
    }

    func check(announce: Bool = false) {
        guard !checking, let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        checking = true
        error = nil
        Task { @MainActor in
            defer { checking = false; lastCheck = .now }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 { latest = nil; return }   // no release published yet
                guard code == 200, let release = Self.parse(data) else {
                    error = L("Couldn't check for updates (\(code))")
                    return
                }
                let wasKnown = latest?.version == release.version
                latest = release
                if announce, !wasKnown, available != nil, !DoNotDisturb.shared.isActive {
                    log.info("update available: \(release.version, privacy: .public)")
                    AppState.shared.noteMessage = L("Coucou \(release.version) is available · Settings → Updates")
                    NotificationCenter.default.post(name: .hookExpand, object: IslandView.note)
                }
            } catch {
                self.error = APIError.describe(error)
            }
        }
    }

    func download() {
        guard let release = available ?? latest else { return }
        NSWorkspace.shared.open(URL(string: release.dmgURL ?? release.pageURL)!)
    }

    // MARK: Parsing and comparing

    static func parse(_ data: Data) -> Release? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }?["browser_download_url"] as? String
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       pageURL: json["html_url"] as? String ?? "https://github.com/\(repo)/releases",
                       dmgURL: dmg,
                       notes: json["body"] as? String ?? "",
                       published: (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    /// "0.10.0" > "0.9.3"; extra parts count ("1.2.1" > "1.2").
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Settings → Updates.
struct UpdatesSection: View {
    @ObservedObject private var updates = Updates.shared
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(updates.available != nil ? Color.orange : Color.green).frame(width: 8, height: 8)
                if let new = updates.available {
                    Text("Coucou \(new.version) is available (you have \(Updates.currentVersion))")
                        .font(.system(size: 12.5, weight: .semibold))
                } else {
                    Text("Coucou \(Updates.currentVersion)")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(updates.lastCheck == nil ? "" : L("up to date"))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Button(updates.checking ? "Checking…" : "Check now") { updates.check() }
                    .disabled(updates.checking)
            }
            if let new = updates.available {
                if !new.notes.isEmpty {
                    ScrollView {
                        Text(new.notes)
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 90)
                }
                HStack {
                    Button(new.dmgURL != nil ? "Download the DMG" : "Open the release page") { updates.download() }
                        .buttonStyle(.borderedProminent)
                    Text("Open it and drag Coucou to Applications, replacing this one.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            if let error = updates.error {
                Text(error).font(.system(size: 11)).foregroundColor(.orange)
            }
            Toggle("Check for updates automatically (every 6 hours, GitHub releases)", isOn: $state.updateChecks)
        }
    }
}
