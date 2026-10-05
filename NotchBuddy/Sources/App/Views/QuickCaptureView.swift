import SwiftUI
import AppKit

// Quick capture (#118): one line in the island becomes a Linear issue.
// The rules live in QuickCapture.swift (`CaptureFlow.reduce`); this runs its effects
// and draws it. Nothing is sent to Linear before the second Enter / the Create click.

// MARK: - Model

@MainActor
final class QuickCaptureModel: ObservableObject {
    static let shared = QuickCaptureModel()

    @Published private(set) var flow: CaptureFlow.State = .initial
    @Published private(set) var teams: [LinearTeam] = []
    @Published private(set) var teamsError: String?
    @Published private(set) var loadingTeams = false
    /// What can go into the description: the window / editor context, or a chat answer.
    @Published private(set) var attachment: CaptureAttachment?
    /// Only sent when on: off for captured context (one click attaches it), on for a chat answer.
    @Published var attach = false
    @Published private(set) var copiedBranch = false
    private var viewerID: String?
    private var teamsLoadedAt: Date?

    private var context: CaptureFlow.Context {
        CaptureFlow.Context(teams: teams, defaultTeamKey: AppState.shared.linearDefaultTeam, now: .now)
    }

    var isBusy: Bool {
        switch flow {
        case .creating, .done: return true
        default: return false
        }
    }

    /// A fresh input, optionally prefilled. Never sends anything.
    func begin(line: String = "", attachment: CaptureAttachment? = nil, attach: Bool = false) {
        flow = .editing(line: line)
        self.attachment = attachment
        self.attach = attach && attachment != nil
        copiedBranch = false
        loadTeams()
    }

    func send(_ event: CaptureFlow.Event) {
        let (next, effect) = CaptureFlow.reduce(flow, event, context)
        flow = next
        switch effect {
        case .create(let chip)?: create(chip)
        case .close?: close()
        case nil: break
        }
    }

    func close() {
        flow = .initial
        attachment = nil
        attach = false
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }

    /// Teams (and your user id for "@me"), kept 10 minutes. Read-only.
    func loadTeams(force: Bool = false) {
        guard LinearAPI.hasKey else {
            teamsError = L("Add your Linear API key in Settings")
            return
        }
        if !force, !teams.isEmpty, let at = teamsLoadedAt, Date.now.timeIntervalSince(at) < 600 { return }
        guard !loadingTeams else { return }
        loadingTeams = true
        Task { @MainActor in
            do {
                let result = try await LinearAPI.teams()
                self.teams = result.teams
                self.viewerID = result.viewerID
                self.teamsError = nil
                self.teamsLoadedAt = .now
                // A preview drawn before the teams arrived is drawn again; this never confirms it.
                if case .preview(let line, _) = self.flow {
                    self.flow = .editing(line: line)
                    self.send(.enter)
                }
            } catch {
                self.teamsError = error.localizedDescription
            }
            self.loadingTeams = false
        }
    }

    func copyBranch(_ issue: CreatedIssue) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issue.branchToCopy, forType: .string)
        copiedBranch = true
    }

    /// Only reached from `.create`, i.e. the second Enter / the Create click.
    private func create(_ chip: PreviewChip) {
        let viewerID = viewerID
        let description = attach ? attachment?.text : nil
        Task { @MainActor in
            do {
                let issue = try await LinearAPI.createIssue(chip, viewerID: viewerID, description: description)
                self.send(.created(issue))
                SoundEngine.shared.play("finish")
                LinearPoller.shared.pollNow()
            } catch {
                self.send(.failed(error.localizedDescription))
                SoundEngine.shared.play("error")
            }
        }
    }

    func problemText(_ problem: PreviewChip.Problem, line: String) -> String {
        switch problem {
        case .emptyTitle:
            return L("Write a title")
        case .unknownTeam:
            let key = QuickCapture.parse(line).teamKey ?? AppState.shared.linearDefaultTeam.uppercased()
            return L("No team with the key \(key)")
        case .noTeam:
            return L("Add #TEAM or pick a default team in Settings")
        case .noTeamsLoaded:
            if let teamsError { return teamsError }
            return loadingTeams ? L("Loading your Linear teams…") : L("No Linear teams loaded")
        }
    }
}

// MARK: - View

struct QuickCaptureView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var model = QuickCaptureModel.shared
    @FocusState private var focused: Bool

    private var line: Binding<String> {
        Binding(get: { model.flow.line },
                set: { new in
                    guard new != model.flow.line else { return }
                    // While creating / once created the line is fixed: redraw it as it was.
                    if model.isBusy { model.objectWillChange.send() } else { model.send(.type(new)) }
                })
    }

    private var hint: String {
        switch model.flow {
        case .editing: return L("#TEAM · p1–p4 · @me · !fri — Enter to preview")
        case .preview(_, let chip): return chip.ready ? L("Enter again to create · Esc to edit") : L("Fix the line, then Enter")
        case .creating: return L("Creating…")
        case .done: return L("Created · Enter to close")
        case .failed: return L("Enter to try again")
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .indigo)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: "#5E6AD2")).frame(width: 7, height: 7)
                    Text("New Linear issue")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                    Text(hint)
                        .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let attachment = model.attachment, !model.isBusy {
                        AttachChip(label: attachment.label, on: model.attach) { model.attach.toggle() }
                    }
                }

                TextField("Fix the cart total #SHO p2 @me !fri", text: line)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit {
                        model.send(.enter)
                        focused = true
                    }
                    .onKeyPress(.escape) {
                        model.send(.escape)
                        return .handled
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .simultaneousGesture(TapGesture().onEnded { focused = true })

                bottomRow
                    .frame(height: 22)
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
        }
        .onAppear { if state.view == .capture { focused = true } }
        .onChange(of: state.view) { _, view in
            if view == .capture { focused = true }
        }
    }

    @ViewBuilder
    private var bottomRow: some View {
        switch model.flow {
        case .editing:
            EmptyView()
        case .preview(let line, let chip):
            HStack(spacing: 6) {
                CapturePreviewChip(chip: chip)
                if let problem = chip.problems.first {
                    Text(model.problemText(problem, line: line))
                        .font(.system(size: 11)).foregroundColor(Color(hex: "#F5A524"))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if chip.ready {
                    CaptureButton(title: "Create", prominent: true) { model.send(.enter) }
                }
            }
        case .creating(_, let chip):
            HStack(spacing: 6) {
                CapturePreviewChip(chip: chip)
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Spacer(minLength: 4)
            }
        case .done(_, let issue):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundColor(Color(hex: "#22C55E"))
                Text(verbatim: issue.identifier)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(hex: "#B4BAF5"))
                Text(verbatim: issue.title)
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#C5C8CD"))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                CaptureButton(title: "Open", prominent: true) { AppLinks.open(issue.url) }
                CaptureButton(title: model.copiedBranch ? "Copied" : "Copy branch name", prominent: false) {
                    model.copyBranch(issue)
                }
                .help(issue.branchToCopy)
            }
        case .failed(_, _, let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundColor(Color(hex: "#F4505E"))
                Text(verbatim: message)
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#F4505E"))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
            }
        }
    }
}

/// Team · title · priority · assignee · due date, as Linear would get them.
private struct CapturePreviewChip: View {
    let chip: PreviewChip

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: chip.team?.key ?? "?")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: chip.team == nil ? "#F5A524" : "#B4BAF5"))
            if !chip.title.isEmpty {
                Text(verbatim: chip.title)
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1).truncationMode(.tail)
            }
            if chip.priority > 0 {
                Text(chip.priorityLabel).font(.system(size: 10.5)).foregroundColor(Color(hex: "#C5C8CD"))
            }
            if chip.assignToMe {
                Text("Me").font(.system(size: 10.5)).foregroundColor(Color(hex: "#C5C8CD"))
            }
            if let due = chip.dueDate {
                Text("Due \(due)").font(.system(size: 10.5)).foregroundColor(Color(hex: "#C5C8CD"))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color(hex: "#5E6AD2").opacity(0.18))
        .clipShape(Capsule())
        .layoutPriority(1)
    }
}

/// "+ app.ts:42": click to put the context in the description (off until clicked).
private struct AttachChip: View {
    let label: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: on ? "paperclip.circle.fill" : "paperclip")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(verbatim: label)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
            }
            .foregroundColor(on ? Color(hex: "#B4BAF5") : Color(hex: "#8E939C"))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((on ? Color(hex: "#5E6AD2") : Color.white).opacity(on ? 0.22 : 0.08))
            .clipShape(Capsule())
            .frame(maxWidth: 200)
        }
        .buttonStyle(.plain)
        .help(on ? L("Attached to the description · click to remove") : L("Click to add this to the description"))
    }
}

private struct CaptureButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(prominent ? Color(hex: "#0B0C0E") : Color(hex: "#F5F6F8"))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(prominent ? Color(hex: "#F5F6F8") : Color.white.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}
