import SwiftUI

/// Settings → Characters: the main character, then your team — which integrations have a
/// character of their own (each one a separate entry in the island's rail, with its own chat),
/// which character, which colour, and whether it floats on the desktop.
struct CharactersSettings: View {
    @ObservedObject var state: AppState
    @State private var placement = IslandPlacement.current
    @State private var floatAll = IslandPlacement.floatAll
    @State private var refresh = 0

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    private var integrations: [AgentTask] {
        state.tasks.filter { $0.isIntegration && $0.id != "integration_claude" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Main character") {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(Critter.allCases) { c in mainCard(c) }
                    }
                    Text("It handles Claude Code — Chat and Code — and every integration without a character of its own. The interface calls it by its name: \u{201C}Ask \(botName())\u{201D}, \u{201C}Hey \(botName())\u{201D}.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            }

            GroupBox("Your team") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Give an integration its own character: it gets its own place in the island's rail, its own base and its own chat about what it handles. The same character can work for several integrations; each one is separate, in a colour of its own.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if integrations.isEmpty {
                        Text("Turn on an integration (Integrations tab) to give it a character.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 6)
                    }
                    ForEach(integrations) { task in
                        TeamRow(state: state, task: task, free: placement == .free, refresh: $refresh)
                    }
                }
                .padding(6)
            }

            GroupBox("On the desktop") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Where they live", selection: $placement) {
                        Text("In the notch").tag(IslandPlacement.notch)
                        Text("Free on the desktop").tag(IslandPlacement.free)
                    }
                    .onChange(of: placement) { _, v in IslandPlacement.current = v }
                    if placement == .free {
                        Picker("Floating characters", selection: $floatAll) {
                            Text("All of them").tag(true)
                            Text("Just \(botName()) (the others in the island)").tag(false)
                        }
                        .onChange(of: floatAll) { _, v in IslandPlacement.floatAll = v }
                        HStack {
                            Text("Drag a character anywhere. Click it to open the island next to it, right-click for options.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Reset positions") {
                                NotificationCenter.default.post(name: .freeBuddyReset, object: nil)
                            }
                        }
                    }
                }
                .padding(6)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandPlacementChanged)) { _ in
            placement = IslandPlacement.current
            floatAll = IslandPlacement.floatAll
            refresh += 1
        }
    }

    private func mainCard(_ c: Critter) -> some View {
        let selected = state.critter == c
        return Button { state.critter = c } label: {
            HStack(spacing: 8) {
                CritterPreview(critter: c)
                    .frame(width: 44, height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: c.displayName).font(.system(size: 12, weight: .semibold))
                    Text(verbatim: c.tagline).font(.system(size: 10)).foregroundColor(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(selected ? 0.12 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: c.displayName))
    }
}

/// One integration: handled by the main character, or by a character of its own.
private struct TeamRow: View {
    @ObservedObject var state: AppState
    let task: AgentTask
    let free: Bool
    @Binding var refresh: Int

    private var own: Critter? { state.critterAssignments[task.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                CritterPreview(critter: own ?? state.critter, tint: own == nil ? nil : state.critterTint(for: task.id))
                    .id("\(own?.rawValue ?? "main")-\(state.critterColors[task.id] ?? "")-\(state.critter.rawValue)")
                    .frame(width: 44, height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
                    .opacity(own == nil ? 0.45 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: task.name).font(.system(size: 12.5, weight: .semibold))
                    Text(own.map { "\($0.displayName) · " + L("its own character") }
                         ?? L("Handled by \(state.critter.displayName)"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("Own character", isOn: Binding(
                    get: { own != nil },
                    set: { on in
                        state.critterAssignments[task.id] = on ? Self.suggested(for: task, state: state) : nil
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            if let own {
                HStack(spacing: 6) {
                    ForEach(Critter.allCases) { c in
                        Button { state.critterAssignments[task.id] = c } label: {
                            VStack(spacing: 1) {
                                CritterPreview(critter: c).frame(width: 34, height: 30)
                                Text(verbatim: c.displayName).font(.system(size: 9.5, weight: .semibold))
                            }
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(own == c ? 0.12 : 0.03)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(own == c ? Color.accentColor : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: c.displayName))
                    }
                }
                HStack(spacing: 10) {
                    Text("Colour").font(.system(size: 11)).foregroundColor(.secondary)
                    TintSwatches(selected: state.critterColors[task.id]) { hex in
                        state.critterColors[task.id] = hex
                    }
                    if state.critterColors[task.id] == nil,
                       Critter.autoTint(for: task.id, assigned: state.critterAssignments, main: state.critter) != nil {
                        Text("automatic, to tell it apart").font(.system(size: 10.5)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if free {
                        Toggle("Floats on the desktop", isOn: Binding(
                            get: { _ = refresh; return IslandPlacement.floats(task.id) },
                            set: { IslandPlacement.setFloats(task.id, $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }

    /// A character not used yet, so a new one is separate from the start.
    static func suggested(for task: AgentTask, state: AppState) -> Critter {
        let used = Set(state.critterAssignments.values).union([state.critter])
        return Critter.allCases.first { !used.contains($0) } ?? .lumo
    }
}
