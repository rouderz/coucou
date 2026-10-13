import SwiftUI

// What an integration's character shows on its base when it has the island to itself (design C):
// more room than the card in the notch, so a chart for WhaTicket and the repositories for GitHub.

// MARK: - WhaTicket: today, hour by hour

/// The last 12 hours as bars — arrived (soft) and accepted (bright) — that grow in when shown
/// and move as tickets come and go, with today's numbers beside them.
struct WhaTicketChart: View {
    @ObservedObject private var log = WhaTicketLog.shared
    @State private var grown = false

    private var summary: WhaTicketSummary {
        let r = WhaTicketStats.range(.today, now: .now)
        return WhaTicketStats.summary(log.events, from: r.from, to: r.to)
    }

    var body: some View {
        let s = summary
        let now = Calendar.current.component(.hour, from: .now)
        let hours = (0..<12).map { (now - 11 + $0 + 24) % 24 }
        let top = max(1, hours.map { max(s.hours[$0].arrived, s.hours[$0].accepted) }.max() ?? 1)

        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                stat(L("Arrived"), "\(s.arrived)", "#8E939C")
                stat(L("Accepted"), "\(s.accepted)", "#25D366")
                stat(L("Avg wait"), s.averageWait.map(Self.duration) ?? "–", "#F5A524")
            }
            .frame(width: 92, alignment: .leading)

            VStack(spacing: 3) {
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(Array(hours.enumerated()), id: \.offset) { i, h in
                        let arrived = CGFloat(s.hours[h].arrived) / CGFloat(top)
                        let accepted = CGFloat(s.hours[h].accepted) / CGFloat(top)
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.06))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(hex: "#25D366").opacity(0.28))
                                .frame(height: grown ? max(2, 58 * arrived) : 2)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(LinearGradient(colors: [Color(hex: "#6EE7A0"), Color(hex: "#25D366")],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(width: 6, height: grown ? max(accepted > 0 ? 3 : 0, 58 * accepted) : 0)
                        }
                        .frame(height: 58)
                        .frame(maxWidth: .infinity)
                        .animation(.spring(response: 0.55, dampingFraction: 0.75).delay(Double(i) * 0.025), value: grown)
                        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: s.hours[h])
                        .help(L("\(h):00 · ↓\(s.hours[h].arrived) ✓\(s.hours[h].accepted)"))
                    }
                }
                HStack(spacing: 5) {
                    ForEach(Array(hours.enumerated()), id: \.offset) { i, h in
                        Text(verbatim: i % 3 == 0 || i == 11 ? "\(h)h" : "")
                            .font(.system(size: 8.5).monospacedDigit())
                            .foregroundColor(Color(hex: "#6B7079"))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .onAppear { grown = true }
        .onDisappear { grown = false }
    }

    private func stat(_ label: String, _ value: String, _ color: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: color)).frame(width: 6, height: 6)
            Text(verbatim: label).font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C"))
            Spacer(minLength: 2)
            Text(verbatim: value).font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(Color(hex: "#F5F6F8"))
                .contentTransition(.numericText())
        }
    }

    static func duration(_ seconds: Int) -> String {
        seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m"
            : seconds >= 60 ? "\(seconds / 60)m" : "\(seconds)s"
    }
}

// MARK: - GitHub: your repositories

struct GitHubRepo: Identifiable, Decodable, Equatable {
    let id: Int
    let name: String
    let fullName: String
    let htmlURL: String
    let language: String?
    let stars: Int
    let pushedAt: Date?
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, language
        case fullName = "full_name", htmlURL = "html_url", stars = "stargazers_count"
        case pushedAt = "pushed_at", isPrivate = "private"
    }
}

/// The repositories you pushed to last, through `gh api` (your GitHub CLI login) or the token
/// in Settings; loaded when shown, kept for 5 minutes.
@MainActor
final class GitHubRepos: ObservableObject {
    static let shared = GitHubRepos()
    @Published private(set) var repos: [GitHubRepo] = []
    @Published private(set) var error: String?
    private var loadedAt: Date?

    func load() async {
        if let at = loadedAt, Date.now.timeIntervalSince(at) < 300 { return }
        loadedAt = .now
        let path = "user/repos?sort=pushed&per_page=8&affiliation=owner,collaborator,organization_member"
        var data = await Task.detached(priority: .utility) { GitHubCLI.raw(path, timeout: 20) }.value
        if data == nil, let token = Secrets.store.get("github-token"), !token.isEmpty,
           let url = URL(string: "https://api.github.com/" + path) {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            data = try? await URLSession.shared.data(for: req).0
        }
        guard let data else {
            error = L("Sign in with the GitHub CLI (gh auth login) or add a token in Settings.")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            repos = try decoder.decode([GitHubRepo].self, from: data)
            error = nil
        } catch {
            self.error = L("Couldn't read the repositories.")
        }
    }
}

struct GitHubRepoList: View {
    @ObservedObject private var store = GitHubRepos.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let error = store.error, store.repos.isEmpty {
                Text(verbatim: error).font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
            }
            ForEach(store.repos.prefix(5)) { r in
                Button { AppLinks.open(r.htmlURL) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: r.isPrivate ? "lock.fill" : "book.closed")
                            .font(.system(size: 9.5))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .frame(width: 12)
                        Text(verbatim: r.name).font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(Color(hex: "#E8E9EC")).lineLimit(1)
                        if let lang = r.language {
                            Text(verbatim: lang).font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
                        }
                        Spacer(minLength: 4)
                        if r.stars > 0 {
                            Text(verbatim: "★ \(r.stars)").font(.system(size: 10)).foregroundColor(Color(hex: "#F5C842"))
                        }
                        if let at = r.pushedAt {
                            Text(at, style: .relative).font(.system(size: 10)).foregroundColor(Color(hex: "#6B7079"))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 8).frame(height: 21)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(r.fullName)
            }
        }
        .task { await store.load() }
    }
}
