import AppKit
import SwiftUI
import os

// MARK: - Model

/// Something that needs you: a review request, a mention, an assignment, a comment.
struct InboxItem: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable { case github, linear }
    enum Kind: String, Sendable, CaseIterable { case review, mention, assigned, comment, other }

    let id: String              // "github:<thread id>" / "linear:<notification id>"
    let remoteID: String
    let source: Source
    let kind: Kind
    let title: String
    let subtitle: String        // "rouderz/coucou #80" / "SHO-123"
    let actor: String?
    let url: String
    let date: Date

    var kindLabel: String {
        switch kind {
        case .review: return L("Review requested")
        case .mention: return L("Mentioned you")
        case .assigned: return L("Assignment")
        case .comment: return L("New comment")
        case .other: return L("Update")
        }
    }

    var icon: String {
        switch kind {
        case .review: return "eye"
        case .mention: return "at"
        case .assigned: return "person.crop.circle.badge.checkmark"
        case .comment: return "bubble.left"
        case .other: return "bell"
        }
    }
}

// MARK: - Sources

enum GitHubInbox {
    /// Unread notifications you're participating in, through your gh login.
    /// Uses ETags, so an unchanged inbox costs nothing against the rate limit.
    static func fetch() -> [InboxItem]? {
        guard let list = GitHubCLI.apiCached("notifications?participating=true&per_page=30") as? [[String: Any]] else {
            return nil
        }
        return list.compactMap { n in
            guard let id = n["id"] as? String, n["unread"] as? Bool != false,
                  let subject = n["subject"] as? [String: Any],
                  let title = subject["title"] as? String else { return nil }
            let repo = (n["repository"] as? [String: Any])?["full_name"] as? String ?? ""
            let kind: InboxItem.Kind
            switch n["reason"] as? String {
            case "review_requested": kind = .review
            case "mention", "team_mention": kind = .mention
            case "assign": kind = .assigned
            case "comment", "author": kind = .comment
            default: kind = .other
            }
            let web = webURL(subject["url"] as? String) ?? ((n["repository"] as? [String: Any])?["html_url"] as? String)
                ?? "https://github.com/notifications"
            let number = web.split(separator: "/").last.flatMap { Int($0) }.map { " #\($0)" } ?? ""
            let date = (n["updated_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .now
            return InboxItem(id: "github:\(id)", remoteID: id, source: .github, kind: kind, title: title,
                             subtitle: repo + number, actor: nil, url: web, date: date)
        }
    }

    /// api.github.com/repos/o/r/pulls/80 → github.com/o/r/pull/80
    static func webURL(_ api: String?) -> String? {
        guard let api, api.hasPrefix("https://api.github.com/repos/") else { return nil }
        return api.replacingOccurrences(of: "https://api.github.com/repos/", with: "https://github.com/")
            .replacingOccurrences(of: "/pulls/", with: "/pull/")
            .replacingOccurrences(of: "/commits/", with: "/commit/")
    }

    static func markRead(_ item: InboxItem) {
        DispatchQueue.global(qos: .utility).async { GitHubCLI.send("PATCH", "notifications/threads/\(item.remoteID)") }
    }
}

enum LinearInbox {
    static func fetch() async -> [InboxItem]? {
        guard LinearAPI.hasKey else { return [] }
        let q = """
        query { notifications(first: 30) { nodes { id type readAt createdAt actor { name }
          ... on IssueNotification { issue { identifier title url } } } } }
        """
        guard let data = try? await LinearAPI.query(q),
              let nodes = (data["notifications"] as? [String: Any])?["nodes"] as? [[String: Any]] else { return nil }
        return nodes.compactMap { n in
            guard let id = n["id"] as? String, n["readAt"] == nil || n["readAt"] is NSNull,
                  let issue = n["issue"] as? [String: Any],
                  let identifier = issue["identifier"] as? String else { return nil }
            let type = (n["type"] as? String ?? "").lowercased()
            let kind: InboxItem.Kind =
                type.contains("mention") ? .mention :
                type.contains("assigned") ? .assigned :
                type.contains("comment") ? .comment :
                type.contains("review") ? .review : .other
            return InboxItem(id: "linear:\(id)", remoteID: id, source: .linear, kind: kind,
                             title: issue["title"] as? String ?? identifier, subtitle: identifier,
                             actor: (n["actor"] as? [String: Any])?["name"] as? String,
                             url: issue["url"] as? String ?? "https://linear.app",
                             date: (n["createdAt"] as? String).flatMap(LinearAPI.date) ?? .now)
        }
    }

    static func markRead(_ item: InboxItem) {
        let now = ISO8601DateFormatter().string(from: .now)
        Task.detached {
            _ = try? await LinearAPI.query(
                "mutation($id: String!, $at: DateTime!) { notificationUpdate(id: $id, input: { readAt: $at }) { success } }",
                variables: ["id": item.remoteID, "at": now])
        }
    }
}

// MARK: - Store and poller

/// Mochi's inbox: polls GitHub and Linear every minute and announces what's new.
@MainActor
final class InboxStore: ObservableObject {
    static let shared = InboxStore()
    @Published private(set) var items: [InboxItem] = []

    private var announced: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "inboxAnnounced") ?? [])
    private var firstRun = true
    private var timer: Timer?
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "inbox")

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard PollGate.shared.allow("inbox", every: 60) else { return }
                InboxStore.shared.refresh()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { InboxStore.shared.refresh() }
    }

    func refresh() {
        let state = AppState.shared
        guard state.inboxEnabled else { items = []; return }
        Task { @MainActor in
            var g: [InboxItem]? = []
            if state.inboxGitHub { g = await Task.detached(priority: .utility) { GitHubInbox.fetch() }.value }
            var l: [InboxItem]? = []
            if state.inboxLinear { l = await LinearInbox.fetch() }
            // A source that failed keeps its previous items.
            var merged = (g ?? items.filter { $0.source == .github }) + (l ?? items.filter { $0.source == .linear })
            merged = merged.filter { state.inboxKinds.contains($0.kind.rawValue) }
                           .sorted { $0.date > $1.date }
            items = merged
            announceNew()
        }
    }

    func open(_ item: InboxItem) {
        AppLinks.open(item.url)
        dismiss(item)
    }

    func dismiss(_ item: InboxItem) {
        items.removeAll { $0.id == item.id }
        switch item.source {
        case .github: GitHubInbox.markRead(item)
        case .linear: LinearInbox.markRead(item)
        }
    }

    func dismissAll() { items.forEach(dismiss) }

    /// "GitHub. Review requested: Fix cart" (or "3 new notifications. Latest, GitHub…").
    static func spoken(_ item: InboxItem, count: Int) -> String {
        let source = item.source == .github ? "GitHub" : "Linear"
        let title = item.title.count > 80 ? String(item.title.prefix(80)) : item.title
        let line = "\(source). \(item.kindLabel): \(title)"
        return count > 1 ? L("\(count) new notifications. Latest, \(line)") : line
    }

    /// New since last time: Mochi peeks out with the newest one (badge only in Do not disturb).
    private func announceNew() {
        let fresh = items.filter { !announced.contains($0.id) }
        announced.formUnion(items.map(\.id))
        UserDefaults.standard.set(Array(announced.suffix(500)), forKey: "inboxAnnounced")
        defer { firstRun = false }
        guard !firstRun, let newest = fresh.first else { return }   // no burst at launch
        log.info("new: \(fresh.count) (\(newest.kind.rawValue, privacy: .public))")
        if DoNotDisturb.shared.isActive { return }
        // Its own sound (not the approval one), a surprised Mochi, and optionally a spoken notice.
        SoundEngine.shared.play(newest.kind == .review || newest.kind == .mention ? "question" : "pop")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.surprised)
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.inbox)
        if AppState.shared.inboxSpeak {
            VoiceOutput.shared.say(Self.spoken(newest, count: fresh.count), locale: VoiceSession.locale(for: AppState.shared))
        }
    }
}

// MARK: - Views

/// 🔔 in the island's top bar, with the unread count.
struct InboxButton: View {
    @ObservedObject private var store = InboxStore.shared
    @ObservedObject private var state = AppState.shared

    var body: some View {
        if state.inboxEnabled {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .inbox }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: store.items.isEmpty ? "bell" : "bell.fill")
                        .font(.system(size: 13))
                        .foregroundColor(store.items.isEmpty ? Color(hex: "#8E939C") : Color(hex: "#F5F6F8"))
                    if !store.items.isEmpty {
                        Text("\(min(store.items.count, 9))")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 13, height: 13)
                            .background(Circle().fill(Color(hex: "#F4505E")))
                            .offset(x: 7, y: -6)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(store.items.isEmpty ? L("Inbox: nothing waiting for you") : L("Inbox: \(store.items.count) waiting for you"))
        }
    }
}

/// Reviews, mentions and assignments from GitHub and Linear.
struct InboxView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store = InboxStore.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "bell.fill").font(.system(size: 11)).foregroundColor(Color(hex: "#F5A524"))
                    Text("Inbox").font(.system(size: 12.5, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                    if !store.items.isEmpty {
                        Text("\(store.items.count)").font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
                    }
                    Spacer()
                    if !store.items.isEmpty {
                        Button("Mark all read") { store.dismissAll() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(Color(hex: "#8E939C"))
                    }
                    Button { store.refresh() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(hex: "#8E939C"))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                }
                if store.items.isEmpty {
                    Text("Nothing waiting for you. Review requests, mentions and assignments from GitHub and Linear show up here.")
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(store.items) { InboxRow(item: $0) }
                        }
                    }
                }
            }
            .padding(.leading, 98).padding(.trailing, 14).padding(.top, 8)
        }
    }
}

private struct InboxRow: View {
    let item: InboxItem
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: item.icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(item.kind == .review ? Color(hex: "#F5A524") : Color(hex: "#A3A8B0"))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color(hex: "#E6E8EB"))
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: item.source == .github ? "#F4505E" : "#5E6AD2")).frame(width: 5, height: 5)
                    Text([item.kindLabel, item.subtitle, item.actor].compactMap { $0 }.filter { !$0.isEmpty }
                            .joined(separator: " · "))
                        .lineLimit(1).truncationMode(.middle)
                    Text(item.date.formatted(.relative(presentation: .named)))
                        .fixedSize()
                }
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#6B7079"))
            }
            Spacer(minLength: 4)
            if hover {
                Button { InboxStore.shared.dismiss(item) } label: {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                .help("Mark as read")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.white.opacity(hover ? 0.06 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { InboxStore.shared.open(item) }
        .onHover { hover = $0 }
        .help(item.url)
    }
}
