import AppKit
import SwiftUI

/// WhaTicket on the overview card: the queue (with Accept) and my open tickets, as of the browser
/// extension's last check-in. Same layout as LinearCardView.
struct WhaTicketCardView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var busy: Set<String> = []

    private var subtitle: String {
        var s = L("Waiting \(appState.whaticketPendingCount) · Mine \(appState.whaticketMineCount)")
        if WhaTicketSettings.autoAccept { s += " · Auto" }
        return s
    }

    /// The tab is closed or asleep: the extension stopped checking in.
    private var stale: Bool {
        appState.whaticketSeenAt.map { Date.now.timeIntervalSince($0) > WhaTicketBridge.staleAfter } ?? true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                StatusDot(id: WhaTicketBridge.id)
                Text("WhaTicket").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                Text(verbatim: subtitle).font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
            }
            .padding(.top, 6).padding(.leading, 108).padding(.trailing, 36)

            if let error = appState.whaticketError {
                NotionHint(dot: "#F4505E", text: error)
            } else if stale {
                NotionHint(dot: "#F5A524", text: L("Open whaticket.com in Chrome or Edge"))
            } else if appState.whaticketPending.isEmpty && appState.whaticketMine.isEmpty {
                NotionHint(dot: "#25D366", text: L("No tickets waiting."))
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(appState.whaticketPending.prefix(4)) { t in
                        row(t, color: t.queueColor.isEmpty ? "#F5A524" : t.queueColor,
                            tag: [t.queue, t.updatedAt.map(Self.ago) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")) {
                            acceptButton(t.id)
                        }
                    }
                    ForEach(appState.whaticketMine.prefix(4)) { t in
                        row(t, color: "#25D366", tag: t.unread > 0 ? L("\(t.unread) new") : (t.updatedAt.map(Self.ago) ?? "")) {
                            EmptyView()
                        }
                    }
                }
            }
            .frame(maxHeight: 76)
            .padding(.leading, 102).padding(.trailing, 12).padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).padding(.top, 4)
    }

    private func row<Trailing: View>(_ t: WhaTicketTicket, color: String, tag: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: color)).frame(width: 7, height: 7)
            Text(verbatim: t.name).font(.system(size: 11)).foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            Text(verbatim: tag).font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(t.lastMessage)
        .onTapGesture { if let url = WhaTicketRules.webURL(t.id) { NSWorkspace.shared.open(url) } }
    }

    /// Accept is queued here and sent by the extension at its next check-in (a few seconds).
    private func acceptButton(_ id: String) -> some View {
        let waiting = busy.contains(id) || appState.whaticketAccepting.contains(id)
        return Button {
            busy.insert(id)
            do { try WhaTicketBridge.shared.accept(id) } catch {
                busy.remove(id)
                appState.noteMessage = error.localizedDescription
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.note)
            }
        } label: {
            Text(verbatim: waiting ? "…" : L("Accept"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color(hex: "#6EE7A0"))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color(hex: "#25D366").opacity(0.18))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(waiting || stale)
        .onChange(of: appState.whaticketAccepting) { _, now in
            if !now.contains(id) { busy.remove(id) }
        }
    }

    private static func ago(_ date: Date) -> String {
        let s = Date.now.timeIntervalSince(date)
        if s < 60 { return L("just now") }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}
