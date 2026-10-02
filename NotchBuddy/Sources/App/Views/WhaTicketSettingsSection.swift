import SwiftUI

/// Settings → WhaTicket: check the sign-in, and the auto-accept rules.
struct WhaTicketSettingsSection: View {
    @State private var autoAccept = WhaTicketSettings.autoAccept
    @State private var queues = Set(WhaTicketSettings.queues)
    @State private var hours = WhaTicketSettings.hours
    @State private var account: WhaTicketAccount?
    @State private var status: String?
    @State private var failed = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("whaticket.com: in WhaTicket go to Integrations → Tokens, create a token with a profile that can view all tickets, view pending ones, transfer tickets and view users; paste it under Integrations with the email you sign in with. Self-hosted WhaTicket: its backend URL, email and password instead.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(busy ? "Signing in…" : "Sign in") { signIn() }.disabled(busy)
                if let status {
                    Text(verbatim: status).font(.system(size: 11))
                        .foregroundColor(failed ? .red : .green)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Sign in to check the connection and load your queues.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }

            Toggle("Auto-accept new tickets as me as soon as they arrive", isOn: $autoAccept)
                .onChange(of: autoAccept) { _, v in WhaTicketSettings.autoAccept = v }

            if let account, !account.queues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Only from these queues (none ticked = any of yours)")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    ForEach(account.queues) { q in
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

            Text("Never during Do not disturb and never group chats. Self-hosted WhaTicket can undo for two minutes (whaticket.com can't put a ticket back in the queue). Coucou only assigns the ticket — it never writes to the customer.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
    }

    private func signIn() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            WhaTicketPoller.shared.reset()
            do {
                let a = try await WhaTicketAPI.login()
                account = a
                failed = false
                let names = a.queues.map(\.name).joined(separator: ", ")
                status = L("Signed in as \(a.name). Queues: \(names.isEmpty ? L("none") : names).")
                WhaTicketPoller.shared.pollNow()
            } catch {
                failed = true
                status = error.localizedDescription
            }
        }
    }
}
