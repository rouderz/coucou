import EventKit
import SwiftUI
import os

/// Do not disturb (#30): while on, Coucou plays no sounds and never opens the island by itself.
/// Finished / failed / approval events only badge the pill (approvals still reveal it, quietly).
/// Manual (for a while, or until turned off) or automatic during calendar events.
@MainActor
final class DoNotDisturb {
    static let shared = DoNotDisturb()

    private let store = EKEventStore()
    private var timer: Timer?
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "dnd")

    var isActive: Bool {
        let s = AppState.shared
        if let until = s.dndUntil, until > .now { return true }
        return s.dndDuringMeetings && s.dndInMeeting
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { DoNotDisturb.shared.refresh() }
        }
    }

    // MARK: Manual

    func turnOn(for duration: TimeInterval?) {
        AppState.shared.dndUntil = duration.map { Date.now.addingTimeInterval($0) } ?? .distantFuture
    }

    func turnOnUntilTomorrowMorning() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: .now) ?? .now
        AppState.shared.dndUntil = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
    }

    func turnOff() {
        let s = AppState.shared
        s.dndUntil = nil
        // Off during a meeting means "not for this one": it comes back on with the next event.
        if s.dndInMeeting { s.dndSkippedMeetingEnd = s.dndMeetingEnd }
        s.dndInMeeting = false
    }

    // MARK: Calendar

    static var calendarAllowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestCalendarAccess() async -> Bool {
        let granted = await Self.askCalendarAccess()
        refresh()
        return granted
    }

    /// The completion runs off the main thread: keep it out of the main actor.
    nonisolated private static func askCalendarAccess() async -> Bool {
        nonisolated(unsafe) let store = EKEventStore()  // kept alive until the answer arrives
        return await withCheckedContinuation { cont in
            store.requestFullAccessToEvents { granted, _ in
                withExtendedLifetime(store) { cont.resume(returning: granted) }
            }
        }
    }

    /// Expired timers off; checks whether a busy calendar event is happening now.
    func refresh() {
        let s = AppState.shared
        if let until = s.dndUntil, until <= .now { s.dndUntil = nil }
        guard s.dndDuringMeetings, Self.calendarAllowed else {
            if s.dndInMeeting { s.dndInMeeting = false }
            return
        }
        let now = Date.now
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                 end: now.addingTimeInterval(60), calendars: nil)
        let current = store.events(matching: predicate).filter {
            !$0.isAllDay && $0.availability != .free && $0.status != .canceled
                && $0.startDate <= now && $0.endDate > now
        }
        let end = current.map(\.endDate).max()
        let inMeeting = end != nil && end != s.dndSkippedMeetingEnd
        if inMeeting != s.dndInMeeting {
            log.info("meeting \(inMeeting ? "started" : "ended", privacy: .public)")
            s.dndInMeeting = inMeeting
        }
        s.dndMeetingEnd = end
    }

    /// "On until 18:30", "On during your meeting"… for the menu and Settings.
    var statusText: String? {
        let s = AppState.shared
        if let until = s.dndUntil, until > .now {
            if until == .distantFuture { return L("On until you turn it off") }
            return L("On until \(until.formatted(date: .omitted, time: .shortened))")
        }
        if s.dndDuringMeetings && s.dndInMeeting { return L("On during your calendar event") }
        return nil
    }
}

/// 🌙 in the island's top bar: click to toggle, menu for how long.
struct DoNotDisturbButton: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        let active = DoNotDisturb.shared.isActive
        Menu {
            if active {
                Button("Turn off Do not disturb") { DoNotDisturb.shared.turnOff() }
            } else {
                Button("For 1 hour") { DoNotDisturb.shared.turnOn(for: 3600) }
                Button("Until tomorrow morning") { DoNotDisturb.shared.turnOnUntilTomorrowMorning() }
                Button("Until I turn it off") { DoNotDisturb.shared.turnOn(for: nil) }
            }
            Divider()
            Toggle("During calendar events", isOn: $state.dndDuringMeetings)
        } label: {
            Image(systemName: active ? "moon.fill" : "moon")
                .font(.system(size: 13))
                .foregroundColor(active ? Color(hex: "#A78BFA") : Color(hex: "#8E939C"))
        } primaryAction: {
            active ? DoNotDisturb.shared.turnOff() : DoNotDisturb.shared.turnOn(for: nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(DoNotDisturb.shared.statusText ?? L("Do not disturb: no sounds, the island doesn't open by itself"))
    }
}
