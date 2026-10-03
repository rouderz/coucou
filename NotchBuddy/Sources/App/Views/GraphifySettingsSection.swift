#if !APPSTORE
import AppKit
import SwiftUI

/// Settings → Graphify: is the CLI there, and the knowledge graph of each project Claude Code ran in.
/// Coucou never installs graphify: it shows the command to run.
struct GraphifySettingsSection: View {
    @ObservedObject private var store = GraphifyStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Graphify builds a knowledge graph of a project that Claude can query instead of re-reading whole files. Builds run locally (code only, no LLM, no network) and write only into the project's graphify-out folder.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(verbatim: cliText).font(.system(size: 12))
                Spacer()
                Button("Refresh") { store.refresh() }.controlSize(.small)
            }

            if case .missing = store.cli {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Coucou doesn't install it. Run this in a terminal, then press Refresh:")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    HStack {
                        Text(verbatim: GraphifyLogic.installCommand)
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(GraphifyLogic.installCommand, forType: .string)
                        }.controlSize(.small)
                    }
                }
            }

            Divider()
            Text("Projects").font(.system(size: 12.5, weight: .semibold))
            if store.projects.isEmpty {
                Text("No projects yet. They appear here once a Claude Code or Codex session has run in a folder.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                ForEach(store.projects) { row($0) }
            }

            if let message = store.message {
                Text(verbatim: message)
                    .font(.system(size: 11))
                    .foregroundColor(store.isError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6)
        .onAppear { store.refresh() }
    }

    private var cliText: String {
        switch store.cli {
        case .missing: return L("graphify isn't installed")
        case .unknown(let path): return L("graphify found at \(path), but its version can't be read")
        case .old(_, let v, let min): return L("graphify \(v.text) is too old (\(min.text) or newer needed)")
        case .ok(_, let v): return L("graphify \(v.text) found")
        }
    }

    private func statusText(_ p: GraphifyProject) -> String {
        switch p.status {
        case .none: return L("No graph yet")
        case .unknown: return L("Graph present, freshness unknown")
        case .fresh: return L("Graph is up to date")
        case .stale(let n, let sample): return L("Stale: \(n) files changed (\(sample.joined(separator: ", ")))")
        }
    }

    private var canBuild: Bool {
        if case .ok = store.cli { return store.building == nil }
        return false
    }

    @ViewBuilder
    private func row(_ p: GraphifyProject) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: (p.path as NSString).lastPathComponent).font(.system(size: 12.5, weight: .semibold))
                Text(verbatim: statusText(p)).font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let counts = p.counts {
                    Text(verbatim: counts).font(.system(size: 10.5)).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 6)
            if store.building == p.path {
                ProgressView().controlSize(.small)
                Button("Cancel") { store.cancel() }.controlSize(.small)
            } else {
                if case .none = p.status {} else {
                    Button("Open graph") { store.openGraph(p) }.controlSize(.small)
                }
                Button(p.status == .none ? "Build graph" : "Update graph") { store.build(p) }
                    .controlSize(.small)
                    .disabled(!canBuild)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
#endif
