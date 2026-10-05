import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Time (#114): time per Linear issue from Claude Code sessions, for the timesheet.
/// Day view (today, +/- 15 min, a manual entry) and period view (1–15 / 16–end) with text / CSV
/// export. Everything stays in a file on this Mac; nothing is uploaded.
struct TimeSettingsSection: View {
    @ObservedObject private var tracker = TimeTracker.shared

    private enum Mode: Hashable { case day, period }
    @State private var mode: Mode = .day
    @State private var periodId: String = ""
    @State private var manualKey = ""
    @State private var manualTitle = ""
    @State private var manualMinutes = 30
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active time of your Claude Code sessions per Linear issue (from the session's branch), or per repo @ branch when there's no issue. Gaps over 10 minutes aren't counted. Kept only on this Mac.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Record time per issue", isOn: $tracker.enabled)

            Picker("View", selection: $mode) {
                Text("Day").tag(Mode.day)
                Text("Period").tag(Mode.period)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .day { dayView } else { periodView }

            if let message {
                Text(verbatim: message).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(6)
    }

    // MARK: Day

    private var today: String { TimeTracking.dayKey(.now) }

    @ViewBuilder
    private var dayView: some View {
        let rows = tracker.rows().filter { $0.day == today }
        if rows.isEmpty {
            Text("No time recorded today yet.")
                .font(.system(size: 11)).foregroundColor(.secondary)
        } else {
            ForEach(rows, id: \.key) { row in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: row.issue?.identifier ?? row.key)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        if let title = row.issue?.title, !title.isEmpty {
                            Text(verbatim: title).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(verbatim: TimeTracker.duration(row.seconds))
                        .font(.system(size: 12, design: .monospaced))
                    Button { change(row, by: -15 * 60) } label: { Text(verbatim: "−15") }
                        .controlSize(.small)
                        .help(L("Remove 15 minutes"))
                    Button { change(row, by: 15 * 60) } label: { Text(verbatim: "+15") }
                        .controlSize(.small)
                        .help(L("Add 15 minutes"))
                }
            }
            HStack {
                Text("Total").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(verbatim: TimeTracker.duration(rows.reduce(0) { $0 + $1.seconds }))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
        }

        Divider()
        Text("Add an entry (work outside Claude Code)").font(.system(size: 12.5, weight: .semibold))
        HStack(spacing: 6) {
            TextField("Issue or task (SHO-123)", text: $manualKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
            TextField("Description (optional)", text: $manualTitle)
                .textFieldStyle(.roundedBorder)
        }
        HStack(spacing: 8) {
            Stepper(value: $manualMinutes, in: 15...720, step: 15) {
                Text(verbatim: TimeTracker.duration(TimeInterval(manualMinutes * 60)))
                    .font(.system(size: 12, design: .monospaced))
            }
            Spacer()
            Button("Add") {
                let title = manualTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                tracker.adjust(day: today, key: manualKey.uppercasedIfIssue,
                               seconds: TimeInterval(manualMinutes * 60), title: title.isEmpty ? nil : title)
                manualKey = ""
                manualTitle = ""
                message = L("Entry added.")
            }
            .disabled(manualKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// +/- on a row; taking away never goes below what the row has.
    private func change(_ row: TimeRow, by seconds: TimeInterval) {
        let delta = seconds < 0 ? -min(-seconds, row.seconds) : seconds
        tracker.adjust(day: row.day, key: row.key, seconds: delta, title: row.issue?.title)
        message = nil
    }

    // MARK: Period

    private var periods: [TimePeriod] { TimeTracker.recentPeriods(before: .now, count: 6) }

    private var period: TimePeriod? {
        periods.first { $0.id == periodId } ?? periods.first
    }

    @ViewBuilder
    private var periodView: some View {
        Picker("Period", selection: Binding(get: { period?.id ?? "" }, set: { periodId = $0 })) {
            ForEach(periods) { p in
                Text(verbatim: "\(p.from) – \(p.to)").tag(p.id)
            }
        }
        .pickerStyle(.menu)

        let days = period.map { TimeTracking.groupPeriod(tracker.rows(), from: $0.from, to: $0.to) } ?? []
        if days.isEmpty {
            Text("No time recorded in this period.")
                .font(.system(size: 11)).foregroundColor(.secondary)
        } else {
            ForEach(days, id: \.day) { d in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(verbatim: d.day).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(verbatim: d.rows.map { $0.issue?.identifier ?? $0.key }.joined(separator: ", "))
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                        Spacer()
                        Text(verbatim: "\(TimeTracking.hours(d.seconds)) h").font(.system(size: 12, design: .monospaced))
                    }
                    Text(verbatim: d.description)
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
            }
            HStack {
                Text("Total").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(verbatim: "\(TimeTracking.hours(days.reduce(0) { $0 + $1.seconds })) h")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
        }

        HStack {
            Button("Copy as text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(TimeTracking.text(days), forType: .string)
                message = L("Copied")
            }
            Button("Save CSV…") { saveCSV(days) }
            Spacer()
        }
        .disabled(days.isEmpty)
        Text("Exports stay on this Mac: nothing is sent anywhere.")
            .font(.system(size: 11)).foregroundColor(.secondary)
    }

    private func saveCSV(_ days: [TimePeriodDay]) {
        guard let p = period else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "coucou-time-\(p.from)-\(p.to).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TimeTracking.csv(days).write(to: url, atomically: true, encoding: .utf8)
            message = L("CSV saved.")
        } catch {
            message = error.localizedDescription
        }
    }
}

private extension String {
    /// "sho-123" → "SHO-123"; anything else as typed.
    var uppercasedIfIssue: String {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        return s.range(of: #"^[A-Za-z][A-Za-z0-9]+-\d+$"#, options: .regularExpression) != nil ? s.uppercased() : s
    }
}
