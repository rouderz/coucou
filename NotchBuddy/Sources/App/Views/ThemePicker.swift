import SwiftUI

/// Settings → Appearance: one swatch per theme; applies at once.
struct ThemePicker: View {
    @ObservedObject var state: AppState

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                swatch(id: "system", name: L("System"), palette: nil)
                ForEach(Theme.all, id: \.id) { p in
                    swatch(id: p.id, name: p.id == "dark" ? L("Dark") : p.id == "light" ? L("Light") : p.name, palette: p)
                }
            }
            Text("Colours of the island's cards and text. The top of the island stays black so it blends with the notch.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
    }

    private func swatch(id: String, name: String, palette: ThemePalette?) -> some View {
        let selected = state.theme == id
        return Button { state.theme = id } label: {
            HStack(spacing: 8) {
                preview(palette)
                Text(verbatim: name).font(.system(size: 11.5)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(selected ? 0.12 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    /// A tiny card in the theme's colours (half dark, half light for System). Raw colours: not themed.
    @ViewBuilder
    private func preview(_ p: ThemePalette?) -> some View {
        if let p {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(raw(p.card))
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(raw(p.ink)).frame(width: 18, height: 3)
                    Capsule().fill(raw(p.dim)).frame(width: 12, height: 3)
                    Capsule().fill(raw(p.accent)).frame(width: 8, height: 3)
                }
                .padding(.leading, 5)
            }
            .frame(width: 30, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
        } else {
            HStack(spacing: 0) { raw(Theme.dark.card); raw(Theme.light.card) }
                .frame(width: 30, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
        }
    }

    /// The exact colour, bypassing the theme mapping in Color(hex:).
    private func raw(_ hex: String) -> Color {
        let v = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
