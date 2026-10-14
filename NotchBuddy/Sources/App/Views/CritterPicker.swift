import SwiftUI

/// Settings → General → Character: one card per character; applies at once.
struct CritterPicker: View {
    @ObservedObject var state: AppState

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Critter.allCases) { c in card(c) }
            }
            Text("The interface calls it by its name: \u{201C}Ask \(botName())\u{201D}, \u{201C}Hey \(botName())\u{201D}.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 4)
            Text("Who handles what").font(.system(size: 12, weight: .semibold))
            assignments
            Text("An integration with its own character gets its place in the island's character rail, with its own chat about it; in free placement it also floats on its own.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
    }

    /// One row per integration on screen: Claude Code has the main character, the others can
    /// have their own (#151).
    private var assignments: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: "Claude Code").font(.system(size: 12))
                Spacer()
                Text(verbatim: state.critter.displayName).font(.system(size: 12)).foregroundColor(.secondary)
            }
            ForEach(state.tasks.filter { $0.isIntegration && $0.id != "integration_claude" }) { task in
                HStack(spacing: 10) {
                    Picker(selection: Binding(
                        get: { state.critterAssignments[task.id]?.rawValue ?? "" },
                        set: { v in state.critterAssignments[task.id] = Critter(rawValue: v) }
                    )) {
                        Text("Same as \(state.critter.displayName)").tag("")
                        ForEach(Critter.allCases) { c in Text(verbatim: c.displayName).tag(c.rawValue) }
                    } label: {
                        Text(verbatim: task.name).font(.system(size: 12))
                    }
                    if state.critterAssignments[task.id] != nil {
                        TintSwatches(selected: state.critterColors[task.id]) { hex in
                            state.critterColors[task.id] = hex
                        }
                    }
                }
            }
        }
    }

    private func card(_ c: Critter) -> some View {
        let selected = state.critter == c
        return Button { state.critter = c } label: {
            HStack(spacing: 8) {
                CritterPreview(critter: c)
                    .frame(width: 44, height: 36)
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

/// A still drawing of a character at rest, for pickers. Draws once: no timeline, no CPU.
struct CritterPreview: View {
    let critter: Critter
    var tint: CGColor? = nil
    @StateObject private var engine = BotEngine()

    var body: some View {
        Canvas { context, size in
            engine.critter = critter
            engine.userTint = tint
            engine.drawHandsBehind(context: context, size: size)
            engine.draw(context: context, size: size)
        }
    }
}

/// A row of colour dots for a character in charge of an integration (#156). The first one,
/// outlined, keeps the character's own colours.
struct TintSwatches: View {
    let selected: String?
    let pick: (String?) -> Void

    var body: some View {
        HStack(spacing: 5) {
            dot(nil)
            ForEach(Critter.tintChoices, id: \.self) { dot($0) }
        }
    }

    private func dot(_ hex: String?) -> some View {
        let on = selected == hex
        return Button { pick(hex) } label: {
            ZStack {
                if let hex {
                    Circle().fill(Color(cgColor: .from(hex)))
                } else {
                    Circle().stroke(Color.secondary, lineWidth: 1)
                    Rectangle().fill(Color.secondary).frame(width: 1, height: 12).rotationEffect(.degrees(45))
                }
            }
            .frame(width: 14, height: 14)
            .padding(2)
            .overlay(Circle().stroke(on ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(hex == nil ? Text("Its own colours") : Text(verbatim: hex!))
    }
}
