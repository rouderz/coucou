import SwiftUI

/// Settings → Chat for the Codex / Gemini CLI engines (#108): found or not, signed in, model.
struct CLIEngineSettings: View {
    let cli: ChatEngineCLI
    @ObservedObject var state: AppState
    @State private var path: String?
    @State private var signedIn: Bool?
    @State private var checking = false

    private var model: Binding<String> {
        cli == .codex ? $state.codexModel : $state.geminiModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(path == nil || signedIn == false ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                Text(verbatim: status)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(checking ? L("Checking…") : L("Check again")) { check(force: true) }
                    .disabled(checking)
            }
            Text(cli == .codex
                 ? L("Uses your Codex sign-in (ChatGPT plan) — no API key needed. Codex runs in its read-only sandbox in an empty folder: it can't touch your files.")
                 : L("Uses your Gemini CLI sign-in (Google account) — no API key needed. It runs in an empty folder, never in your projects."))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Model")
                TextField(L("Default of the CLI"), text: model)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
        .onAppear { check(force: false) }
        .onChange(of: cli) { _, _ in path = nil; signedIn = nil; check(force: false) }
    }

    private var status: String {
        guard let path else { return L("\(cli.name) not found. Install it and sign in, then check again.") }
        if signedIn == false, let login = cli.loginCommand { return L("\(cli.name) isn't signed in · run \(login)") }
        return L("\(cli.name) found: \(path)")
    }

    private func check(force: Bool) {
        checking = true
        let cli = cli
        Task {
            let install = await AgentCLIChat.locate(cli, force: force)
            path = install?.path
            if let install {
                signedIn = await Task.detached(priority: .utility) { cli.isSignedIn(install) }.value
            } else {
                signedIn = nil
            }
            checking = false
        }
    }
}
