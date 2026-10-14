import AppKit
import SwiftUI

// VPN on the main character's base: the VPNs macOS knows about (System Settings → VPN, and the
// ones apps like Proton VPN install), whether one is on, and a click to turn it on or off.
// Read with `scutil --nc`, only while the island is open; nothing leaves the Mac.

struct VPNService: Identifiable, Equatable {
    let id: String
    let name: String
    let status: Status

    enum Status: String { case connected, connecting, disconnecting, disconnected }
}

@MainActor
final class VPNMonitor: ObservableObject {
    static let shared = VPNMonitor()
    @Published private(set) var services: [VPNService] = []

    private static let scutil = "/usr/sbin/scutil"
    private static let protonApps = ["/Applications/Proton VPN.app", "/Applications/ProtonVPN.app"]

    /// The one to show: the one on, else the Proton one, else the first.
    var main: VPNService? {
        services.first { $0.status != .disconnected }
            ?? services.first { $0.name.localizedCaseInsensitiveContains("proton") }
            ?? services.first
    }

    var protonInstalled: Bool { Self.protonApps.contains { FileManager.default.fileExists(atPath: $0) } }

    func refresh() async {
        let out = await Self.run(Self.scutil, ["--nc", "list"])
        var list = Self.parse(out)
        // Cloudflare WARP, through its own command line.
        if let cli = Self.warpCLI {
            let status = await Self.run(cli, ["status"]).lowercased()
            if status.contains("connected") {
                list.removeAll { $0.name.localizedCaseInsensitiveContains("warp") }
                list.insert(VPNService(id: "warp", name: "Cloudflare WARP",
                                       status: status.contains("disconnected") ? .disconnected : .connected), at: 0)
            }
        }
        services = list
    }

    nonisolated private static var warpCLI: String? {
        ["/usr/local/bin/warp-cli", "/opt/homebrew/bin/warp-cli",
         "/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Turns it on or off. VPNs that only their own app can start (Proton's) open that app.
    func toggle(_ s: VPNService) {
        Task {
            if s.id == "warp", let cli = Self.warpCLI {
                _ = await Self.run(cli, [s.status == .disconnected ? "connect" : "disconnect"])
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await refresh()
                return
            }
            let verb = s.status == .disconnected ? "start" : "stop"
            let out = await Self.run(Self.scutil, ["--nc", verb, s.id])
            if verb == "start", out.localizedCaseInsensitiveContains("no service") || out.localizedCaseInsensitiveContains("failed") {
                openApp()
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await refresh()
        }
    }

    func openApp() {
        if let app = Self.protonApps.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: app))
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// `* (Connected)      3F2…-…  VPN (com.protonvpn.mac) "Proton VPN"   [VPN/…]`
    nonisolated static func parse(_ text: String) -> [VPNService] {
        text.split(separator: "\n").compactMap { line in
            guard let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")"),
                  let q1 = line.firstIndex(of: "\""), let q2 = line[line.index(after: q1)...].firstIndex(of: "\"")
            else { return nil }
            let raw = line[line.index(after: open)..<close].lowercased()
            let status: VPNService.Status = raw.hasPrefix("connected") ? .connected
                : raw.hasPrefix("connecting") ? .connecting
                : raw.hasPrefix("disconnecting") ? .disconnecting : .disconnected
            let after = line[line.index(after: close)...].split(separator: " ", omittingEmptySubsequences: true)
            guard let id = after.first.map(String.init) else { return nil }
            let name = String(line[line.index(after: q1)..<q2])
            return VPNService(id: id, name: name, status: status)
        }
    }

    nonisolated private static func run(_ program: String, _ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: program)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { cont.resume(returning: ""); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}

/// "VPN · Proton VPN" on the main character's base: green while on; click turns it on or off,
/// right-click for the others and the Proton VPN app.
struct VPNChip: View {
    @ObservedObject private var vpn = VPNMonitor.shared
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if let s = vpn.main {
                let on = s.status == .connected
                let busy = s.status == .connecting || s.status == .disconnecting
                Button { vpn.toggle(s) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: on ? "lock.shield.fill" : "lock.shield")
                            .font(.system(size: 10, weight: .semibold))
                        Text(verbatim: "VPN · \(s.name)").lineLimit(1)
                        if busy { ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10) }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(on ? Color(hex: "#5FD38A") : Color(hex: "#C5C8CD"))
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(on ? Color(hex: "#1F3B2A") : Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(on ? L("Connected — click to disconnect") : L("Disconnected — click to connect"))
                .contextMenu {
                    ForEach(vpn.services) { other in
                        Button("\(other.name) — \(other.status == .connected ? L("on") : L("off"))") { vpn.toggle(other) }
                    }
                    if vpn.protonInstalled {
                        Divider()
                        Button(L("Open Proton VPN")) { vpn.openApp() }
                    }
                }
            } else {
                // No VPN yet: Proton VPN (free plan) or Cloudflare WARP, both free.
                Menu {
                    if vpn.protonInstalled {
                        Button(L("Open Proton VPN")) { vpn.openApp() }
                    } else {
                        Button(L("Get Proton VPN — free plan")) { AppLinks.open("https://protonvpn.com/free-vpn") }
                    }
                    Button(L("Get Cloudflare WARP — free")) { AppLinks.open("https://one.one.one.one/") }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield").font(.system(size: 10, weight: .semibold))
                        Text(verbatim: vpn.protonInstalled ? "VPN · Proton" : "VPN")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    /// Checks every 10 s while the island is open (run from the base, which is always there).
    static func watch(_ state: AppState) async {
        guard state.mode == .expanded else { return }
        while !Task.isCancelled {
            await VPNMonitor.shared.refresh()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }
}
