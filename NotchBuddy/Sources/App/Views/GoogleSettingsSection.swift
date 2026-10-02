import SwiftUI

/// Settings → Google: your own OAuth client, connecting the account, and the Gmail search.
struct GoogleSettingsSection: View {
    @State private var clientID = Secrets.store.get(GoogleAPI.clientIDKey) ?? ""
    @State private var clientSecret = Secrets.store.get(GoogleAPI.clientSecretKey) ?? ""
    @State private var connected = GoogleAPI.isConnected
    @State private var email = UserDefaults.standard.string(forKey: "googleEmail") ?? ""
    @State private var query = UserDefaults.standard.string(forKey: "gmailQuery") ?? "is:unread in:inbox"
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gmail in the island and your Drive files in the chat (type @ and a file name). Read-only: Coucou never sends mail or changes files.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("One-time setup, free: in console.cloud.google.com create a project, turn on the Gmail API and the Google Drive API, set up the OAuth consent screen (External, add yourself as a test user, then Publish it so the sign-in doesn't expire every 7 days), and create an OAuth client ID of type \"Desktop app\". Paste its ID and secret here.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Client ID  (….apps.googleusercontent.com)", text: $clientID)
                .textFieldStyle(.roundedBorder)
            SecureField("Client secret  (GOCSPX-…)", text: $clientSecret)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                if connected {
                    Text(verbatim: email.isEmpty ? L("Connected.") : L("Connected as \(email)."))
                        .font(.system(size: 11.5)).foregroundColor(.green)
                    Button("Disconnect") {
                        Task { @MainActor in
                            await GoogleAPI.disconnect()
                            connected = false
                            email = ""
                        }
                    }
                } else {
                    Button(busy ? "Finish signing in in your browser…" : "Connect Google…") { connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let message {
                Text(verbatim: message).font(.system(size: 11)).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Gmail shows")
                TextField("is:unread in:inbox", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveQuery() }
                    .onChange(of: query) { _, _ in saveQuery() }
            }
            Text("A Gmail search, e.g. is:unread in:inbox, or is:important is:unread. Turn on the Gmail pill under Integrations.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
    }

    private func saveQuery() {
        UserDefaults.standard.set(query.trimmingCharacters(in: .whitespaces), forKey: "gmailQuery")
        GmailPoller.shared.reset()
    }

    private func connect() {
        Secrets.store.set(GoogleAPI.clientIDKey, value: clientID.trimmingCharacters(in: .whitespaces))
        Secrets.store.set(GoogleAPI.clientSecretKey, value: clientSecret.trimmingCharacters(in: .whitespaces))
        busy = true
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                email = try await GoogleAPI.connect()
                connected = true
                GmailPoller.shared.reset()
                GmailPoller.shared.pollNow()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
