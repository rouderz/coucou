import AppKit
import SwiftUI

/// CI pill (#115) on the overview card: your open PRs with their latest check runs. A failed
/// Actions job gets "Open log", "Ask Mochi why" (its log tail goes to the chat) and "Re-run".
struct CICardView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var busy: String?
    @State private var rerunning: Set<Int> = []

    private var subtitle: String {
        let pill = appState.ciPill
        switch pill.color {
        case .failed:  return L("Failing · \(pill.count)")
        case .running: return L("Running · \(pill.count)")
        default:       return appState.ciPRs.isEmpty ? L("Your open PRs") : L("Open PRs · \(appState.ciPRs.count)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                StatusDot(id: CIPoller.id)
                Text(verbatim: "CI").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                Text(verbatim: subtitle)
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
            }
            .padding(.top, 6).padding(.leading, 108).padding(.trailing, 36)

            if let error = appState.ciError {
                NotionHint(dot: "#F4505E", text: error)
            } else if appState.ciPRs.isEmpty {
                NotionHint(dot: "#F5A524", text: L("No open pull requests."))
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(appState.ciPRs) { pr in
                        prRow(pr)
                        ForEach(pr.runs, id: \.id) { run in
                            runRow(pr, run)
                        }
                    }
                }
            }
            .frame(maxHeight: 76)
            .padding(.leading, 102).padding(.trailing, 12).padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).padding(.top, 4)
    }

    // MARK: Rows

    private func prRow(_ pr: CIPullRequest) -> some View {
        Button { AppLinks.open(pr.url) } label: {
            HStack(spacing: 6) {
                Circle().fill(Self.color(pr.summary.state)).frame(width: 7, height: 7)
                Text(verbatim: "\(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo)#\(pr.number)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1).fixedSize()
                Text(verbatim: pr.title)
                    .font(.system(size: 11, weight: .medium)).foregroundColor(Color(hex: "#C5C8CD"))
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Spacer(minLength: 4)
                if pr.summary.total > 0 {
                    Text(verbatim: "\(pr.summary.passed)/\(pr.summary.total)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .fixedSize()
                        .help(L("Checks passed: \(pr.summary.passed) of \(pr.summary.total)"))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pr.summary.total == 0 ? L("No checks on this commit") : pr.title)
    }

    @ViewBuilder
    private func runRow(_ pr: CIPullRequest, _ run: CheckRun) -> some View {
        let state = run.state
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(verbatim: Self.symbol(state))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Self.color(state))
                    .frame(width: 10)
                Text(verbatim: run.name)
                    .font(.system(size: 10.5)).foregroundColor(Color(hex: "#A3A8B0"))
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Spacer(minLength: 4)
                Text(verbatim: Self.statusText(run))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(1).fixedSize()
            }
            if state == .failed {
                HStack(spacing: 6) {
                    if let url = run.htmlURL {
                        action(L("Open log"), help: L("Open log")) { AppLinks.open(url) }
                    }
                    action(busy == "ask\(run.id)" ? "…" : L("Ask Mochi why"), help: L("Ask Mochi why")) { ask(pr, run) }
                    let runId = CICore.parseJobURL(run.htmlURL)?.runId
                    if let runId {
                        action(rerunning.contains(runId) ? L("Re-running…") : busy == "rerun\(run.id)" ? "…" : L("Re-run"),
                               help: L("Re-run failed jobs")) { rerun(pr, run, runId: runId) }
                            .disabled(rerunning.contains(runId))
                    }
                }
                .padding(.leading, 15)
            }
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 1)
    }

    private func action(_ title: String, help: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(verbatim: title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(hex: "#F6A39B"))
                .padding(.horizontal, 7).padding(.vertical, 1.5)
                .background(Color(hex: "#F4505E").opacity(0.16))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
        .help(help)
    }

    // MARK: Actions (explicit clicks only)

    private func ask(_ pr: CIPullRequest, _ run: CheckRun) {
        busy = "ask\(run.id)"
        Task { @MainActor in
            defer { busy = nil }
            do { try await CIPoller.shared.askWhy(pr, run) } catch { show(error) }
        }
    }

    private func rerun(_ pr: CIPullRequest, _ run: CheckRun, runId: Int) {
        busy = "rerun\(run.id)"
        Task { @MainActor in
            defer { busy = nil }
            do {
                try await CIPoller.shared.rerunFailed(pr, run)
                rerunning.insert(runId)
            } catch { show(error) }
        }
    }

    private func show(_ error: any Error) {
        appState.noteMessage = error.localizedDescription
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.note)
    }

    // MARK: Look

    static func color(_ s: PRCIState) -> Color {
        switch s {
        case .failed: return Color(hex: "#F4505E")
        case .running: return Color(hex: "#4C8DFF")
        case .passed: return Color(hex: "#22C55E")
        case .cancelled, .neutral: return Color(hex: "#6B7079")
        }
    }

    static func color(_ s: CheckState) -> Color {
        switch s {
        case .failed: return Color(hex: "#F4505E")
        case .running: return Color(hex: "#4C8DFF")
        case .passed: return Color(hex: "#22C55E")
        case .cancelled, .skipped, .neutral: return Color(hex: "#6B7079")
        }
    }

    static func symbol(_ s: CheckState) -> String {
        switch s {
        case .failed: return "✗"
        case .running: return "●"
        case .passed: return "✓"
        case .cancelled, .skipped, .neutral: return "–"
        }
    }

    /// Duration when known; otherwise what the check is doing.
    static func statusText(_ run: CheckRun) -> String {
        let duration = CICore.formatDuration(run.durationSeconds())
        switch run.state {
        case .running: return run.startedAt == nil ? L("queued") : duration
        case .skipped: return L("skipped")
        case .cancelled: return L("cancelled")
        case .neutral: return duration.isEmpty ? L("neutral") : duration
        case .passed, .failed: return duration
        }
    }
}
