import AppKit
import CryptoKit
import SwiftUI
import os

/// Update check (#40) and self-update: compares this build with the latest release on GitHub,
/// then downloads the app, checks its Ed25519 signature (UpdateKey), swaps it in place and
/// relaunches. Without a key, or when the app's folder isn't writable, it offers the DMG instead.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()
    static let repo = "rouderz/coucou"

    struct Release: Equatable {
        let version: String
        let pageURL: String
        let dmgURL: String?
        /// The app as a zip, and its signature: what the self-update installs.
        let zipURL: String?
        let signatureURL: String?
        let notes: String
        let published: Date?
    }

    @Published private(set) var latest: Release?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var checking = false
    @Published private(set) var error: String?
    /// "Downloading…", "Checking the signature…", "Restarting…" while installing.
    @Published private(set) var installStep: String?

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

    // MARK: Self-update

    /// The running app's bundle can be replaced by this user (it lives in a folder they can write).
    nonisolated static var canReplaceApp: Bool {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parent)
            && !Bundle.main.bundlePath.hasPrefix("/Volumes/")      // not running from the DMG
    }

    /// Installs and restarts by itself (signed release, key in this build, writable folder).
    var canInstall: Bool {
        guard let new = available else { return false }
        return !UpdateKey.macPublicKey.isEmpty && new.zipURL != nil && new.signatureURL != nil && Self.canReplaceApp
    }

    /// The signature is Ed25519 over the zip's bytes, with UpdateKey's private half.
    nonisolated static func signatureIsValid(_ signatureB64: String, for data: Data, publicKey: String) -> Bool {
        guard let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let sig = Data(base64Encoded: signatureB64.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    /// Download → check the signature → unzip → check it's Coucou, that version → swap and relaunch.
    func installAndRestart() {
        guard installStep == nil, let release = available, canInstall,
              let zipURL = release.zipURL.flatMap(URL.init(string:)),
              let sigURL = release.signatureURL.flatMap(URL.init(string:)) else { return }
        error = nil
        installStep = L("Downloading…")
        Task { @MainActor in
            do {
                let (zipFile, _) = try await URLSession.shared.download(from: zipURL)
                let (sigData, _) = try await URLSession.shared.data(from: sigURL)
                installStep = L("Checking the signature…")
                let zip = try Data(contentsOf: zipFile)
                guard Self.signatureIsValid(String(decoding: sigData, as: UTF8.self), for: zip,
                                            publicKey: UpdateKey.macPublicKey) else {
                    throw UpdateError(L("The download isn't signed by Coucou's key. Nothing was installed."))
                }
                let newApp = try Self.unzip(zipFile, expecting: release.version)
                installStep = L("Restarting…")
                try Self.swapAndRelaunch(with: newApp)
                log.info("updating to \(release.version, privacy: .public)")
                NSApp.terminate(nil)
            } catch {
                installStep = nil
                self.error = (error as? UpdateError)?.message ?? error.localizedDescription
            }
        }
    }

    struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Unzips into a fresh temporary folder and checks the app inside is Coucou at `version`.
    nonisolated static func unzip(_ zip: URL, expecting version: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, dir.path]
        try ditto.run()
        ditto.waitUntilExit()
        let app = dir.appendingPathComponent("Coucou.app")
        guard ditto.terminationStatus == 0,
              let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError(L("The downloaded app isn't the expected Coucou version. Nothing was installed."))
        }
        return app
    }

    /// A small script waits for this process to quit, swaps the bundle (putting the old one
    /// back if anything fails) and opens the new one.
    nonisolated static func swapAndRelaunch(with newApp: URL) throws {
        let target = Bundle.main.bundleURL.path
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf \(q(target + ".old"))
        if mv \(q(target)) \(q(target + ".old")) && /usr/bin/ditto \(q(newApp.path)) \(q(target)); then
          rm -rf \(q(target + ".old"))
        else
          rm -rf \(q(target)); mv \(q(target + ".old")) \(q(target))
        fi
        /usr/bin/xattr -dr com.apple.quarantine \(q(target)) 2>/dev/null
        /usr/bin/open \(q(target))
        rm -rf \(q(newApp.deletingLastPathComponent().path))
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-update-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = [file.path]
        try sh.run()   // outlives us: launchd adopts it when Coucou quits
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
        func asset(_ suffix: String) -> String? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }?["browser_download_url"] as? String
        }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       pageURL: json["html_url"] as? String ?? "https://github.com/\(repo)/releases",
                       dmgURL: asset(".dmg"),
                       zipURL: asset("-macOS.zip"),
                       signatureURL: asset("-macOS.zip.sig"),
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
                if updates.canInstall {
                    HStack {
                        Button(updates.installStep ?? L("Install and restart")) { updates.installAndRestart() }
                            .buttonStyle(.borderedProminent)
                            .disabled(updates.installStep != nil)
                        Text("Coucou updates itself and opens again in a few seconds.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                } else {
                    HStack {
                        Button(new.dmgURL != nil ? "Download the DMG" : "Open the release page") { updates.download() }
                            .buttonStyle(.borderedProminent)
                        Text("Open it and drag Coucou to Applications, replacing this one.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
            }
            if let error = updates.error {
                Text(error).font(.system(size: 11)).foregroundColor(.orange)
            }
            Toggle("Check for updates automatically (every 6 hours, GitHub releases)", isOn: $state.updateChecks)
        }
    }
}
