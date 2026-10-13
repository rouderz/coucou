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
            Text("Mochi is the original Coucou character and isn't covered by the open-source licence: keep it for your own use, pick another one in builds you share.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
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
    @StateObject private var engine = BotEngine()

    var body: some View {
        Canvas { context, size in
            engine.critter = critter
            engine.drawHandsBehind(context: context, size: size)
            engine.draw(context: context, size: size)
        }
    }
}
