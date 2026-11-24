import MetalUI

/// A plugin's redacted stderr tail, selectable and copyable. Equal when the text is equal, so it is built once per log
/// change and not with the rest of Settings (a 64 KiB `Text` lays out every glyph when built).
struct PluginLogView: Component, Equatable {
    let text: String
    let identifier: String

    nonisolated static func == (a: Self, b: Self) -> Bool { a.text == b.text && a.identifier == b.identifier }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("PluginLogView")
        Text(verbatim: text.isEmpty ? "No output." : text).font(size: 11).foregroundColor(.mutedInk)
            .textSelection(.enabled)
            .accessibilityIdentifier(identifier)
    }
}
