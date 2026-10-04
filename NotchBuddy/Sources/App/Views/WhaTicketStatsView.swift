import SwiftUI

/// Settings → WhaTicket → Stats: tickets that arrived in the queue and the ones we accepted, from the
/// local log (WhaTicketStats.swift). Bars are plain shapes — no chart library.
struct WhaTicketStatsView: View {
    @ObservedObject private var log = WhaTicketLog.shared
    @State private var period: WhaTicketStats.Period = .today
    @State private var from = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now
    @State private var to = Date.now
    @State private var confirmReset = false

    private var range: (from: Date, to: Date) {
        WhaTicketStats.range(period, now: .now, from: from, to: to)
    }

    var body: some View {
        let r = range
        let s = WhaTicketStats.summary(log.events, from: r.from, to: r.to)
        VStack(alignment: .leading, spacing: 10) {
            Text("Stats").font(.system(size: 12, weight: .semibold))

            Picker("", selection: $period) {
                Text("Today").tag(WhaTicketStats.Period.today)
                Text("Last 7 days").tag(WhaTicketStats.Period.week)
                Text("Last 30 days").tag(WhaTicketStats.Period.month)
                Text("Custom").tag(WhaTicketStats.Period.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            if period == .custom {
                HStack {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                }
                .frame(maxWidth: 420)
            }

            numbers(s)

            if s.arrived + s.accepted > 0 {
                Text("By hour of day").font(.system(size: 11)).foregroundColor(.secondary)
                bars(s.hours.map { Double($0.arrived) }, s.hours.map { Double($0.accepted) },
                     labels: (0..<24).map { $0 % 6 == 0 ? "\($0)h" : "" })

                if s.days.count > 1 {
                    Text("By day").font(.system(size: 11)).foregroundColor(.secondary)
                    bars(s.days.map { Double($0.arrived) }, s.days.map { Double($0.accepted) },
                         labels: s.days.enumerated().map { i, d in
                             i == 0 || i == s.days.count - 1 || s.days.count <= 10 ? String(d.day.suffix(5)) : ""
                         })
                }

                HStack(spacing: 12) {
                    legend("#F5A524", L("Arrived"))
                    legend("#25D366", L("Accepted"))
                }

                queues(s.queues)
            } else {
                Text("No tickets in this period.").font(.system(size: 11)).foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Button("Export CSV") { log.exportCSV(from: r.from, to: r.to) }
                    .disabled(s.arrived + s.accepted == 0)
                Button("Reset stats") { confirmReset = true }
                    .disabled(log.events.isEmpty)
            }
            .confirmationDialog("Delete all WhaTicket stats?", isPresented: $confirmReset) {
                Button("Reset stats", role: .destructive) { log.reset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }

            Text("Counts only cover the time your whaticket.com tab was open with the extension. Kept on this Mac for a year, never uploaded: ticket ids, queues and times only — no names, phone numbers or messages.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pieces

    private func numbers(_ s: WhaTicketSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 18) {
                stat(L("Arrived"), "\(s.arrived)")
                stat(L("Accepted"), "\(s.accepted)")
                stat(L("Acceptance rate"), s.rate.map { "\(Int(($0 * 100).rounded())) %" } ?? "—")
                stat(L("Average wait"), WhaTicketStats.duration(s.averageWait))
                stat(L("Median wait"), WhaTicketStats.duration(s.medianWait))
            }
            Text(verbatim: L("From Coucou \(s.click) · Auto-accepted \(s.auto) · Elsewhere \(s.web)"))
                .font(.system(size: 11)).foregroundColor(.secondary)
            if s.backlog > 0 {
                Text(verbatim: L("\(s.backlog) were already waiting when the tab opened (not in the per-hour chart or the waits)."))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
            Text(verbatim: label).font(.system(size: 10.5)).foregroundColor(.secondary)
        }
    }

    private func legend(_ color: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: color)).frame(width: 9, height: 9)
            Text(verbatim: label).font(.system(size: 10.5)).foregroundColor(.secondary)
        }
    }

    /// Two bars per slot (arrived, accepted), scaled to the busiest slot.
    private func bars(_ arrived: [Double], _ accepted: [Double], labels: [String]) -> some View {
        let top = max(1, (arrived + accepted).max() ?? 1)
        let height: CGFloat = 70
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(arrived.indices, id: \.self) { i in
                    HStack(alignment: .bottom, spacing: 1) {
                        bar(arrived[i], top: top, height: height, color: "#F5A524")
                        bar(i < accepted.count ? accepted[i] : 0, top: top, height: height, color: "#25D366")
                    }
                    .frame(maxWidth: .infinity)
                    .help(L("\(Int(arrived[i])) arrived · \(Int(i < accepted.count ? accepted[i] : 0)) accepted"))
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack(spacing: 2) {
                ForEach(labels.indices, id: \.self) { i in
                    Text(verbatim: labels[i]).font(.system(size: 9)).foregroundColor(.secondary)
                        .lineLimit(1).fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func bar(_ value: Double, top: Double, height: CGFloat, color: String) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color(hex: color))
            .frame(height: value > 0 ? max(2, height * value / top) : 0)
            .frame(maxWidth: .infinity)
    }

    private func queues(_ rows: [WhaTicketSummary.Queue]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
            GridRow {
                Text("Queue")
                Text("Arrived")
                Text("Accepted")
                Text("Average wait")
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundColor(.secondary)
            ForEach(rows) { q in
                GridRow {
                    Text(verbatim: q.name.isEmpty ? L("No queue") : q.name).lineLimit(1)
                    Text(verbatim: "\(q.arrived)").monospacedDigit()
                    Text(verbatim: "\(q.accepted)").monospacedDigit()
                    Text(verbatim: WhaTicketStats.duration(q.averageWait)).monospacedDigit()
                }
                .font(.system(size: 11))
            }
        }
    }
}
