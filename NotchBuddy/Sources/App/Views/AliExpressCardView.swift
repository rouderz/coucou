import AppKit
import SwiftUI

/// AliExpress on the overview card: packages by tracking number, with "Invoice" for each one,
/// plus refresh and the CSV export. Same layout as WhaTicketCardView.
struct AliExpressCardView: View {
    @ObservedObject private var appState = AppState.shared

    private var subtitle: String {
        let onTheWay = appState.aliPackages.filter { !$0.delivered }.count
        return L("\(appState.aliPackages.count) packages · \(onTheWay) on the way")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                StatusDot(id: AliExpressBridge.id)
                Text("AliExpress").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                Text(verbatim: subtitle).font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.top, 6).padding(.leading, 108).padding(.trailing, 62)

            HStack(spacing: 8) {
                small(appState.aliSyncing ? L("Reading…") : L("Refresh")) { AliExpressBridge.shared.sync() }
                    .disabled(appState.aliSyncing)
                small(appState.aliBusy.contains("csv") ? "…" : L("Export CSV")) { AliExpressBridge.shared.exportCSV() }
                if let file = appState.aliLastFile {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                    } label: {
                        Text(verbatim: "↓ " + URL(fileURLWithPath: file.path).lastPathComponent)
                            .font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help(L("Show in Finder"))
                }
            }
            .padding(.top, 3).padding(.leading, 108).padding(.trailing, 12)

            if appState.aliPackages.isEmpty {
                NotionHint(dot: "#F5A524", text: L("Open your AliExpress orders in Chrome or Edge once: Coucou reads them from there."))
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(appState.aliPackages.sorted { !$0.delivered && $1.delivered }.prefix(12)) { p in
                        row(p)
                    }
                }
            }
            .frame(maxHeight: 72)
            .padding(.leading, 102).padding(.trailing, 12).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).padding(.top, 4)
    }

    private func row(_ p: AliPackage) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: p.delivered ? "#22C55E" : "#F5A524")).frame(width: 7, height: 7)
            Text(verbatim: p.tracking).font(.system(size: 11, design: .monospaced)).foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(1).truncationMode(.middle).layoutPriority(1)
            Text(verbatim: L("\(p.orders.count) orders · \(p.totalText)"))
                .font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            let busy = appState.aliBusy.contains(p.tracking)
            Button { AliExpressBridge.shared.makeInvoice(p.tracking) } label: {
                Text(verbatim: busy ? "…" : L("Invoice"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .fixedSize()
                    .foregroundColor(Color(hex: "#FFB4B4"))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color(hex: "#FF4747").opacity(0.18))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .layoutPriority(2)
            .disabled(busy)
            .help(L("Make the invoice of this box (PDF in Downloads/Coucou/AliExpress)"))
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .help([p.carrier, p.status, p.lastEvent, p.lastTime].filter { !$0.isEmpty }.joined(separator: " · "))
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = p.orders.first, let url = URL(string: "https://www.aliexpress.com/p/tracking/index.html?tradeOrderId=\(id)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func small(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(verbatim: title).font(.system(size: 10.5, weight: .medium)).foregroundColor(Color(hex: "#C5C8CD"))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.white.opacity(0.07)).clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Settings → AliExpress: the buyer details printed on the invoices, and how it works.
struct AliExpressSettingsSection: View {
    @State private var buyer = AliBuyer.load()
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coucou groups your AliExpress orders by the box they ship in (same tracking number) and makes one invoice per box — PDF to your Downloads/Coucou/AliExpress folder — plus a CSV of every product for Excel or Google Sheets. It reads your own order pages through the browser extension (Settings → WhaTicket → Set up browser extension, then open your AliExpress orders once).")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Printed on the invoices as the buyer:")
                .font(.system(size: 11, weight: .medium))
            TextField(L("Full name"), text: $buyer.name).textFieldStyle(.roundedBorder)
            TextField(L("ID / RUC (cédula)"), text: $buyer.id).textFieldStyle(.roundedBorder)
            TextField(L("Address (several lines are fine)"), text: $buyer.address, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            HStack {
                TextField(L("Email (optional)"), text: $buyer.email).textFieldStyle(.roundedBorder)
                TextField(L("Phone (optional)"), text: $buyer.phone).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Save") { buyer.save(); saved = true }
                    .buttonStyle(.borderedProminent)
                if saved { Text("✓ Saved").font(.system(size: 11)).foregroundColor(.green) }
            }
            Text("The invoice is your own document built from your orders: it lists the AliExpress order numbers it comes from and says it isn't issued by AliExpress. Keep the original order receipts (Download invoice on each order) for customs.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .onChange(of: buyer) { _, _ in saved = false }
    }
}
