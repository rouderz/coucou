import SwiftUI

/// Settings → WhaTicket: set up the browser extension, the auto-accept rules and the stats.
struct WhaTicketSettingsSection: View {
    @ObservedObject private var appState = AppState.shared
    @State private var autoAccept = WhaTicketSettings.autoAccept
    @State private var queues = Set(WhaTicketSettings.queues)
    @State private var hours = WhaTicketSettings.hours
    @State private var browsers = BrowserExtension.registered
    @State private var installed = BrowserExtension.installed
    @State private var status: String?
    @State private var failed = false

    private var ready: Bool { installed && !browsers.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Coucou reads your whaticket.com queue through a small Chrome / Edge extension that uses the session you already have open — no token, no password, and it never signs you out.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            #if APPSTORE
            Text("The browser extension isn't available in the App Store version.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            #else
            HStack(spacing: 10) {
                Button(ready ? "Set up again" : "Set up browser extension") { install() }
                if installed {
                    Button("Show folder") { BrowserExtension.reveal() }
                }
            }
            if let status {
                Text(verbatim: status).font(.system(size: 11))
                    .foregroundColor(failed ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            } else if ready {
                Text(verbatim: L("Ready for \(browsers.joined(separator: ", ")). Extension folder: \(BrowserExtension.extensionDir.path)"))
                    .font(.system(size: 11)).foregroundColor(.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("1. Click Set up browser extension.")
                Text("2. In Chrome open chrome://extensions (in Edge: edge://extensions) and turn on Developer mode.")
                Text("3. Click Load unpacked and pick the extension folder shown above.")
                Text("4. Keep a whaticket.com tab open, and turn on the WhaTicket pill under Integrations.")
            }
            .font(.system(size: 11)).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            #endif

            Toggle("Auto-accept new tickets as me as soon as they arrive", isOn: $autoAccept)
                .onChange(of: autoAccept) { _, v in WhaTicketSettings.autoAccept = v }

            if appState.whaticketQueues.isEmpty {
                Text("Your queues show here once whaticket.com is open with the extension.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Only from these queues (none ticked = any of yours)")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    ForEach(appState.whaticketQueues) { q in
                        Toggle(isOn: Binding(
                            get: { queues.contains(q.id) },
                            set: { on in
                                if on { queues.insert(q.id) } else { queues.remove(q.id) }
                                WhaTicketSettings.queues = Array(queues).sorted()
                            })) {
                            HStack(spacing: 5) {
                                Circle().fill(Color(hex: q.color.isEmpty ? "#8E939C" : q.color)).frame(width: 7, height: 7)
                                Text(verbatim: q.name)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            HStack {
                Text("Only between")
                TextField("Any time — or e.g. 09:00-18:00", text: $hours)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { WhaTicketSettings.hours = hours.trimmingCharacters(in: .whitespaces) }
                    .onChange(of: hours) { _, v in WhaTicketSettings.hours = v.trimmingCharacters(in: .whitespaces) }
            }

            Text("Only while your whaticket.com tab is open. Never during Do not disturb, never group chats, never tickets an AI agent is handling. Coucou only assigns the ticket — it never writes to the customer.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            WhaTicketStatsView()
        }
        .padding(6)
    }

    private func install() {
        do {
            try BrowserExtension.install()
            failed = false
            status = nil
        } catch {
            failed = true
            status = error.localizedDescription
        }
        browsers = BrowserExtension.registered
        installed = BrowserExtension.installed
    }
}
