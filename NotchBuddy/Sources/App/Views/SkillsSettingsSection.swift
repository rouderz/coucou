#if !APPSTORE
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Skills: what Claude Code and Codex can use on this Mac, and adding new ones.
struct SkillsSettingsSection: View {
    @ObservedObject private var store = SkillsStore.shared
    @State private var search = ""
    @State private var target = "personal"
    @State private var source = ""
    @State private var preview: SkillPreview?
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    @State private var newName = ""
    /// The skill whose SKILL.md is open below its row.
    @State private var viewing: String?
    @State private var dropTargeted = false

    private var shown: [SkillInfo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.skills }
        return store.skills.filter { "\($0.name) \($0.description) \($0.origin ?? "")".lowercased().contains(q) }
    }

    private func groupLabel(_ s: SkillInfo) -> String {
        switch s.source {
        case .personal: return L("Personal")
        case .codex: return L("Codex")
        case .project: return L("Project · \(s.origin ?? "")")
        case .plugin: return L("Plugin · \(s.origin ?? "")")
        }
    }

    private struct Group: Identifiable {
        var id: String { label }
        let label: String
        var skills: [SkillInfo]
    }

    private var groups: [Group] {
        var out: [Group] = []
        for s in shown {
            let g = groupLabel(s)
            if out.last?.label == g { out[out.count - 1].skills.append(s) } else { out.append(Group(label: g, skills: [s])) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What Claude Code and Codex can use on this Mac: your own skills, each project's, and the ones that come with plugins. Turning one off moves it aside; nothing is deleted.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Search skills…", text: $search).textFieldStyle(.roundedBorder)
                Button("Refresh") { store.refresh() }
            }

            if store.skills.isEmpty {
                Text("No skills on this Mac yet. Add one below.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(groups) { group in
                            Text(verbatim: group.label.uppercased())
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                            ForEach(group.skills) { row($0) }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Divider()
            Text("Add a skill").font(.system(size: 12.5, weight: .semibold))
            Picker("Install to", selection: $target) {
                ForEach(store.targets, id: \.id) { Text(verbatim: $0.label).tag($0.id) }
            }
            HStack {
                TextField("Folder, .zip / .skill file, or a GitHub link", text: $source)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runPreview() }
                Button("Choose…") { choose() }
                Button(busy ? "Looking…" : "Preview") { runPreview() }
                    .buttonStyle(.borderedProminent)
                    .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            Text("Or drop a skill folder or a .zip / .skill file here. You see what's inside before anything is installed.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let preview { previewView(preview) }

            if let message {
                Text(verbatim: message)
                    .font(.system(size: 11))
                    .foregroundColor(isError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                TextField("New skill name", text: $newName).textFieldStyle(.roundedBorder)
                Button("Create") {
                    run { try store.create(name: newName, target: target); newName = "" }
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(6)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: dropTargeted ? 2 : 0))
        .onAppear { store.refresh() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let path = url?.path else { return }
                Task { @MainActor in
                    source = path
                    runPreview()
                }
            }
            return true
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ s: SkillInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: s.name).font(.system(size: 12.5, weight: .semibold))
                        if s.hasScripts { tag(L("scripts"), color: .orange) }
                        if !s.enabled { tag(L("off"), color: .gray) }
                    }
                    Text(verbatim: s.description.isEmpty ? L("No description.") : s.description)
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .lineLimit(2)
                }
                .opacity(s.enabled ? 1 : 0.55)
                Spacer(minLength: 6)
                Button(viewing == s.path ? "Hide" : "View") { viewing = viewing == s.path ? nil : s.path }
                    .controlSize(.small)
                Button("Open") { store.open(s.path) }.controlSize(.small).help(L("Open in the editor"))
                Button("Folder") { store.reveal(s.path) }.controlSize(.small)
                if s.editable {
                    Toggle("", isOn: Binding(get: { s.enabled }, set: { on in run { try store.setEnabled(s, on) } }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
            if viewing == s.path {
                ScrollView {
                    Text(verbatim: store.read(s) ?? L("SKILL.md can't be read"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    // MARK: Preview and install

    @ViewBuilder
    private func previewView(_ p: SkillPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(p.skills) { sk in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: sk.name).font(.system(size: 12.5, weight: .semibold))
                    Text(verbatim: sk.description.isEmpty ? L("No description.") : sk.description)
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: L("\(sk.files.count) files: \(sk.files.prefix(12).joined(separator: ", "))\(sk.files.count > 12 ? "…" : "")"))
                        .font(.system(size: 10.5)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: L("Installs to \(sk.dest)"))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundColor(.secondary)
                        .textSelection(.enabled)
                    if sk.hasScripts {
                        Text("It has scripts. Coucou never runs them, but Claude may when it uses the skill — read them first.")
                            .font(.system(size: 11)).foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if sk.exists {
                        Text("A skill with this name is already there; installing replaces it (the old one is kept in Coucou's trash).")
                            .font(.system(size: 11)).foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button(p.skills.count > 1 ? L("Install \(p.skills.count) skills") : L("Install")) {
                    run {
                        try store.install(p)
                        preview = nil
                        source = ""
                        say(L("Installed. Claude Code picks it up in its next session."))
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") { store.cancel(p); preview = nil }
            }
        }
    }

    private func runPreview() {
        let src = source
        guard !src.trimmingCharacters(in: .whitespaces).isEmpty, !busy else { return }
        busy = true
        message = nil
        preview = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                preview = try await store.preview(source: src, target: target)
            } catch {
                say(error.localizedDescription, error: true)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .zip, UTType(filenameExtension: "skill") ?? .zip]
        panel.message = L("Choose a skill folder, or a .zip / .skill file")
        if panel.runModal() == .OK, let url = panel.url {
            source = url.path
            runPreview()
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { say(error.localizedDescription, error: true) }
    }

    private func say(_ text: String, error: Bool = false) {
        message = text
        isError = error
    }
}
#endif
