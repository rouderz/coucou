import AppKit
import SwiftUI

/// Gmail on the overview card: the mails matching your search, with "Ask" to hand one to Mochi.
struct GmailCardView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var busy: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                StatusDot(id: GmailPoller.id)
                Text("Gmail").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                Text(verbatim: appState.gmailTotal > 0 ? L("Unread · \(appState.gmailTotal)") : L("Inbox"))
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
            }
            .padding(.top, 6).padding(.leading, 108).padding(.trailing, 36)

            if let error = appState.gmailError {
                NotionHint(dot: "#F4505E", text: error)
            } else if appState.gmailMails.isEmpty {
                NotionHint(dot: "#22C55E", text: L("Nothing new in your inbox."))
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(appState.gmailMails) { mail in
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: "#EA4335")).frame(width: 7, height: 7)
                            Text(verbatim: mail.from).font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(Color(hex: "#8E939C")).lineLimit(1).fixedSize()
                            Text(verbatim: mail.subject.isEmpty ? L("(no subject)") : mail.subject)
                                .font(.system(size: 11)).foregroundColor(Color(hex: "#C5C8CD"))
                                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                            Spacer(minLength: 4)
                            Button { ask(mail) } label: {
                                Text(verbatim: busy == mail.id ? "…" : L("Ask"))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(Color(hex: "#F6A39B"))
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(Color(hex: "#EA4335").opacity(0.18))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(busy != nil)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .help(mail.snippet)
                        .onTapGesture { AppLinks.open("https://mail.google.com/mail/u/0/#inbox/\(mail.threadId)") }
                    }
                }
            }
            .frame(maxHeight: 76)
            .padding(.leading, 102).padding(.trailing, 12).padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).padding(.top, 4)
    }

    private func ask(_ mail: GmailMessage) {
        busy = mail.id
        Task { @MainActor in
            defer { busy = nil }
            do {
                GoogleAPI.attach(try await GoogleAPI.mailFile(mail.id), fresh: true)
            } catch {
                appState.noteMessage = error.localizedDescription
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.note)
            }
        }
    }
}
