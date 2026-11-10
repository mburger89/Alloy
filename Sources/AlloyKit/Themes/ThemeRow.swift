import AlloyCore
import MetalUI

extension Color {
    /// A colour from a theme file's own value. The one place a view shows colours that are not the applied palette: a
    /// theme row's swatches show that theme, whichever theme is applied. Nothing else should use it.
    init(themeRGBA rgba: ThemeRGBA) { self.init(rgba.hsla) }
}

/// One theme in the Settings list: five swatches of the theme's own colours, its name, "Built-in" or the author, and a
/// checkmark when it is the selected one.
struct ThemeRow: Component {
    let entry: ThemeEntry
    let resolved: ResolvedTheme?
    let selected: Bool
    let identifier: String
    let choose: @MainActor () -> Void

    private var subtitle: String { entry.isBuiltIn ? "Built-in" : (entry.file.author ?? "Custom") }

    private var swatches: [Color] {
        guard let resolved else { return [] }
        let keys = ["chatFill", "accent", "syntax.keyword", "syntax.string"]
        var rgba = keys.compactMap { resolved.colors[$0] }
        if let first = resolved.sessionColors.first { rgba.append(first) }
        return rgba.map { Color(themeRGBA: $0) }
    }

    var content: some ElementGroup {
        let choose = choose, swatches = swatches
        Button { choose() } label: {
            HStack(spacing: Pixels(8)) {
                HStack(spacing: Pixels(3)) {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                        Rectangle().fill(color).frame(width: Pixels(12), height: Pixels(12))
                            .border(Color.controlBorder, width: Pixels(1))
                    }
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: Pixels(1)) {
                    Text(verbatim: entry.file.name).font(size: 13).lineLimit(1)
                    Text(verbatim: subtitle).font(size: 11).foregroundColor(.mutedInk).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 12)).foregroundColor(Color(ColorToken.accent))
                }
            }
            .padding(Pixels(6))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
