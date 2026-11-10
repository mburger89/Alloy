import AlloyCore
import MetalUI

extension ThemeRGBA {
    /// The same colour as a MetalUI `Hsla` (gamma-encoded sRGB, like the theme file).
    var hsla: Hsla {
        Rgba(r: Float(r), g: Float(g), b: Float(b), a: Float(a)).toHsla()
    }
}

/// Turns a resolved theme into the MetalUI `Theme` a window installs as its `lightTheme` or `darkTheme`.
public enum ThemeApplier {
    private static let bySlotName: [String: ThemeSlot] = Dictionary(uniqueKeysWithValues: ThemeSlots.all.map { ($0.name, $0) })

    /// `Theme.dark` or `Theme.light` (by appearance) with every slot the theme defines set on top. Unknown slot names are
    /// ignored; slots the theme leaves out keep the base value. Session colour *n* (1...12) takes
    /// `sessionColors[(n - 1) % count]`; with no session colours the defaults stay.
    public static func theme(for resolved: ResolvedTheme) -> Theme {
        var theme: Theme = resolved.appearance == .dark ? .dark : .light
        for (name, rgba) in resolved.colors {
            bySlotName[name]?.apply(&theme, rgba)
        }
        let list = resolved.sessionColors
        if !list.isEmpty {
            for (offset, setter) in sessionSetters.enumerated() { setter(&theme, Color(list[offset % list.count].hsla)) }
        }
        return theme
    }

    private static let sessionSetters: [@Sendable (inout Theme, Color) -> Void] = [
        { $0[SessionColor1.self] = $1 }, { $0[SessionColor2.self] = $1 }, { $0[SessionColor3.self] = $1 },
        { $0[SessionColor4.self] = $1 }, { $0[SessionColor5.self] = $1 }, { $0[SessionColor6.self] = $1 },
        { $0[SessionColor7.self] = $1 }, { $0[SessionColor8.self] = $1 }, { $0[SessionColor9.self] = $1 },
        { $0[SessionColor10.self] = $1 }, { $0[SessionColor11.self] = $1 }, { $0[SessionColor12.self] = $1 },
    ]
}
