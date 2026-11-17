import AlloyLSP
import Foundation
import Observation

/// What the hover popover shows: the server's Markdown, the diagnostics under the pointer, and the byte range the popover
/// points at (the server's range, else the hovered character).
struct HoverPresentation: Identifiable, Equatable {
    let id = UUID()
    var markdown: String
    var diagnostics: [LSPDiagnostic]
    var range: Range<Int>?

    static func == (a: HoverPresentation, b: HoverPresentation) -> Bool { a.id == b.id }
}

/// The one text-anchored presentation of a code view (slot B): the hover popover. Other presentations of the view wait for
/// MetalUI to allow a second one, so nothing else chains onto the view.
@MainActor @Observable
final class PopoverSlotModel {
    var hover: HoverPresentation?
    /// The parsed Markdown of the open hover, kept across the popover's rebuilds.
    @ObservationIgnored let markdownCache = MarkdownCache()
}
