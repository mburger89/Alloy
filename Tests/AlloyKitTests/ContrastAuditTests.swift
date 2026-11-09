import AlloyHighlight
@testable import AlloyKit
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// Reads colours through the window's own theme and scheme (`LayoutPass.environment`, then `Color.resolve(in:)`), the
/// way MetalUI resolves them for paint, and hands them back.
final class ResolvedBox: @unchecked Sendable {
    var colors: [Color.Resolved] = []
}

struct ColorProbe: ProposalElement {
    let colors: [Color]
    let box: ResolvedBox
    struct Layout { var node: LayoutNodeID }

    mutating func requestProposalLayout(_ id: GlobalElementID, pass: inout LayoutPass) -> (ProposalNodeID, Layout) {
        let environment = pass.environment
        box.colors = colors.map { $0.resolve(in: environment) }
        let node = pass.requestNativeLeaf { _ in LayoutMeasurement(size: SizeD(width: 1, height: 1)) }
        return (node, Layout(node: node.layoutNodeID))
    }
    mutating func prepaint(_ id: GlobalElementID, bounds: Bounds<Pixels>, layout: inout Layout, pass: inout PrepaintPass) {}
    mutating func paint(_ id: GlobalElementID, bounds: Bounds<Pixels>, layout: inout Layout, prepaint: inout Void,
                        pass: inout PaintPass) {}
}

/// `colors` resolved by a real window in the given scheme (the window's own theme and scheme).
@MainActor
func resolvedInWindow(_ colors: [Color], dark: Bool) throws -> [Color.Resolved] {
    let box = ResolvedBox()
    let window = try TestWindow(size: Size(width: Pixels(100), height: Pixels(100)), colorScheme: dark ? .dark : .light) {
        ColorProbe(colors: colors, box: box)
    }
    window.tick()
    return box.colors
}

/// Who can change a colour: Alloy's own tokens must pass; a MetalUI-owned one is reported as a gap.
private enum Owner { case alloy, metalUI }

private struct Pair {
    var id: String
    var foreground: Color
    /// Backgrounds, bottom first; the first is opaque, the rest may be translucent.
    var layers: [Color]
    /// 4.5 for body text, 3.0 for large text and UI glyphs (WCAG 2.1 AA).
    var minimum: Double
    var owner: Owner = .alloy
}

private struct RGB { var r: Double, g: Double, b: Double }

private func rgb(_ c: Color.Resolved) -> (RGB, Double) { (RGB(r: Double(c.red), g: Double(c.green), b: Double(c.blue)), Double(c.opacity)) }

private func over(_ top: Color.Resolved, _ base: RGB) -> RGB {
    let (t, a) = rgb(top)
    return RGB(r: t.r * a + base.r * (1 - a), g: t.g * a + base.g * (1 - a), b: t.b * a + base.b * (1 - a))
}

private func luminance(_ c: RGB) -> Double {
    func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

private func ratio(_ a: RGB, _ b: RGB) -> Double {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

@MainActor
@Suite struct ContrastAuditTests {
    /// What the views really draw, pair by pair. Built from the views' sources: every `foregroundColor`, `fill` and
    /// `background` a view applies, plus the MetalUI defaults those views inherit (text, `.secondary`, the code view's
    /// theme, the tab strip, the placeholder).
    private static func pairs() -> [Pair] {
        var out: [Pair] = []
        func add(_ id: String, _ fg: Color, _ layers: [Color], _ min: Double, _ owner: Owner = .alloy) {
            out.append(Pair(id: id, foreground: fg, layers: layers, minimum: min, owner: owner))
        }
        let text = Color.textPrimary, secondary = Color.mutedInk
        let sessions = (0..<8).map { Color.sessionColor($0) }
        let authors: [(String, Color)] = [("user", .userAuthor), ("outside", .outsideAuthor)]
            + sessions.enumerated().map { ("session\($0.offset)", $0.element) }

        // Sidebar: normal, selected, changed files, errors.
        add("sidebar.name", text, [.sidebarFill], 4.5)
        add("sidebar.secondary", secondary, [.sidebarFill], 4.5)
        add("sidebar.plus", text, [.sidebarFill], 3)
        let selection = Color.sessionSelection
        add("sidebar.selected.name", text, [.sidebarFill, selection], 4.5)
        add("sidebar.selected.secondary", secondary, [.sidebarFill, selection], 4.5)
        for (i, s) in sessions.enumerated() {
            add("sidebar.dot\(i)", s, [.sidebarFill], 3)
            add("sidebar.selected.dot\(i)", s, [.sidebarFill, selection], 3)
            add("sidebar.badge\(i)", secondary, [.sidebarFill, s.opacity(0.15)], 4.5)
            add("sidebar.selected.badge\(i)", secondary, [.sidebarFill, selection, s.opacity(0.15)], 4.5)
        }
        add("sidebar.files.active", text, [.sidebarFill, Color.sessionColor(0).opacity(0.12)], 4.5)
        add("sidebar.files.empty", secondary, [.sidebarFill], 4.5)
        for (name, c) in authors { add("sidebar.files.dot.\(name)", c, [.sidebarFill], 3) }
        add("sidebar.errors", text, [.warningTint], 4.5)

        // Chat blocks: every kind's tint with title, summary, header icon and link.
        for kind in BlockKind.allCases {
            let s = BlockStyle.style(kind)
            add("chat.\(kind).title", text, [s.tint], 4.5)
            add("chat.\(kind).summary", secondary, [s.tint], 4.5)
            add("chat.\(kind).icon", s.ink, [s.tint], 3)
            add("chat.\(kind).link", .linkInk, [s.tint], 4.5)
        }
        add("chat.empty", secondary, [.chatFill], 4.5)
        add("chat.user.text", text, [.sidebarFill], 4.5)
        add("chat.user.caption", secondary, [.sidebarFill], 4.5)
        add("chat.sessionMessage.text", text, [.sidebarFill], 4.5)
        add("chat.sessionMessage.title", secondary, [.sidebarFill], 4.5)
        for (i, s) in sessions.enumerated() { add("chat.sessionMessage.stripe\(i)", s, [.sidebarFill], 3) }
        add("chat.link", .linkInk, [.chatFill], 4.5)
        add("chat.error.body", .errorInk, [.errorTint], 4.5)
        add("chat.warning.body", .warningInk, [.warningTint], 4.5)
        add("chat.errorInk.code", .errorInk, [.markdownCodeFill], 4.5)
        add("chat.errorInk.page", .errorInk, [.chatFill], 4.5)
        add("chat.question.chip", .questionInk, [.questionTint, Color.questionInk.opacity(0.14)], 4.5)
        add("chat.question.pickedGlyph", .questionInk, [.questionTint, Color.questionInk.opacity(0.10)], 3)
        add("chat.question.pickedDetail", secondary, [.questionTint, Color.questionInk.opacity(0.10)], 4.5)
        add("chat.question.unpickedGlyph", secondary, [.questionTint], 3)

        // Code blocks in chat and markdown: text, gutter, marks and every syntax colour on the fill and the diff tints.
        add("code.text", text, [.markdownCodeFill], 4.5)
        add("code.gutter", secondary, [.markdownCodeFill], 4.5)
        add("code.link", .linkInk, [.markdownCodeFill], 4.5)
        add("code.gutter.added", secondary, [.editAddTint], 4.5)
        add("code.gutter.removed", secondary, [.editRemoveTint], 4.5)
        add("code.text.added", text, [.editAddTint], 4.5)
        add("code.text.removed", text, [.editRemoveTint], 4.5)
        for token in SyntaxToken.allCases {
            guard let fg = SyntaxPalette().dynamicStyle(token).foreground else { continue }
            add("syntax.\(token).chatFill", fg, [.markdownCodeFill], 4.5)
            add("syntax.\(token).added", fg, [.editAddTint], 4.5)
            add("syntax.\(token).removed", fg, [.editRemoveTint], 4.5)
            add("syntax.\(token).panel", fg, [.surface], 4.5)
            add("syntax.\(token).panelAdded", fg, [.surface, .addedRowTint], 4.5)
            add("syntax.\(token).panelRemoved", fg, [.surface, .removedRowTint], 4.5)
            add("syntax.\(token).selection", fg, [.surface, CodeTheme.alloy.selection], 4.5)
            add("syntax.\(token).find", fg, [.surface, CodeTheme.alloy.findMatch], 4.5)
            add("syntax.\(token).findCurrent", fg, [.surface, CodeTheme.alloy.currentFindMatch], 4.5)
        }

        // Suggestions and quick open.
        add("suggest.text", text, [.panelFill], 4.5)
        add("suggest.detail", secondary, [.panelFill], 4.5)
        add("suggest.selected.text", text, [.panelFill, .commandTint], 4.5)
        add("suggest.selected.detail", secondary, [.panelFill, .commandTint], 4.5)

        // Composer.
        add("composer.text", text, [.surface], 4.5)
        add("composer.placeholder", text.opacity(0.45), [.surface], 4.5, .metalUI)
        add("composer.border", .controlBorder, [.surface], 3)
        add("composer.queued", secondary, [.chatFill], 4.5)

        // Code panel: header, notices, edit bar, find bar.
        add("panel.path", text, [.panelFill], 4.5)
        add("panel.secondary", secondary, [.panelFill], 4.5)
        add("panel.dirtyDot", secondary, [.panelFill], 3)
        add("panel.findIcon", text, [.panelFill], 3)
        add("panel.notice.error", .errorInk, [.errorTint], 4.5)
        add("panel.notice.warning", .warningInk, [.warningTint], 4.5)
        add("panel.conflict", text, [.warningTint], 4.5)
        // The code view with MetalUI's default `CodeTheme`: text, gutter numbers, selection and find highlights.
        add("panel.code.text", text, [.surface], 4.5)
        add("panel.code.gutter", CodeTheme.alloy.gutterForeground, [.surface], 4.5)
        add("panel.code.added", text, [.surface, .addedRowTint], 4.5)
        add("panel.code.removed", text, [.surface, .removedRowTint], 4.5)
        add("panel.code.selection", text, [.surface, CodeTheme.alloy.selection], 4.5)
        add("panel.code.find", text, [.surface, CodeTheme.alloy.findMatch], 4.5)
        add("panel.code.findCurrent", text, [.surface, CodeTheme.alloy.currentFindMatch], 4.5)
        for (name, c) in authors {
            add("panel.code.bar.\(name)", c, [.surface], 3)
            add("panel.code.authorRun.\(name)", text, [.surface, c.opacity(authorRunAlpha)], 4.5)
        }

        // Tabs (MetalUI `TabStrip`): selected, unselected, hovered.
        add("tabs.selected", text, [.background], 4.5, .metalUI)
        add("tabs.unselected", text.opacity(0.62), [.surfaceSecondary], 4.5, .metalUI)
        add("tabs.hover", text.opacity(0.62), [.surfaceSecondary, text.opacity(0.06)], 4.5, .metalUI)

        // The Inline | Side by side picker (MetalUI segmented `Picker`): labels on the track and on the selected pill, and
        // the pill against the track.
        let pill = Color(light: .surface, dark: Color.textPrimary.opacity(0.18))
        add("picker.unselected", text, [.surfaceSecondary], 4.5, .metalUI)
        add("picker.selected", text, [.surfaceSecondary, pill], 4.5, .metalUI)
        add("picker.selectedVsTrack", pill, [.surfaceSecondary], 3, .metalUI)

        // Settings view on the panel fill: title, labels, hints, the error line and the close glyph.
        add("settings.text", text, [.panelFill], 4.5)
        add("settings.secondary", secondary, [.panelFill], 4.5)
        add("settings.error", .errorInk, [.panelFill], 4.5)
        add("settings.close", text, [.panelFill], 3)
        // Sidebar stat lines: the footer's knowledge line and a row's re-reads, plain and selected.
        add("sidebar.knowledgeStats", secondary, [.sidebarFill], 4.5)
        add("sidebar.rereads", secondary, [.sidebarFill], 4.5)
        add("sidebar.selected.rereads", secondary, [.sidebarFill, selection], 4.5)

        // Coordination warnings: the marker glyph and the notice strip, in the warning tokens and, for an escalated tug, the
        // error tokens. The marker sits on its own tint, so the row behind it does not matter.
        for (name, ink, tint) in [("warning", Color.warningInk, Color.warningTint), ("error", Color.errorInk, Color.errorTint)] {
            add("coordination.mark.\(name)", ink, [tint], 3)
            add("coordination.notice.\(name).icon", ink, [tint], 3)
            add("coordination.notice.\(name).text", text, [tint], 4.5)
            add("coordination.notice.\(name).dismiss", text, [tint], 3)
        }

        // Disabled controls: MetalUI draws them at half opacity.
        add("disabled.onSurface", text.opacity(0.5), [.surface], 3, .metalUI)
        add("disabled.onChat", text.opacity(0.5), [.chatFill], 3, .metalUI)
        add("disabled.onQuestion", text.opacity(0.5), [.questionTint], 3, .metalUI)
        return out
    }

    private static func resolve(_ pairs: [Pair], dark: Bool) throws -> [(Pair, Double)] {
        var all: [Color] = []
        for p in pairs { all.append(p.foreground); all.append(contentsOf: p.layers) }
        let box = ResolvedBox()
        let window = try TestWindow(size: Size(width: Pixels(100), height: Pixels(100)), colorScheme: dark ? .dark : .light) {
            ColorProbe(colors: all, box: box)
        }
        window.tick()
        #expect(box.colors.count == all.count)
        var index = 0
        var out: [(Pair, Double)] = []
        for p in pairs {
            let fg = box.colors[index]; index += 1
            var base = RGB(r: 1, g: 1, b: 1)
            for _ in p.layers { base = over(box.colors[index], base); index += 1 }
            let blended = over(fg, base)
            out.append((p, ratio(blended, base)))
        }
        return out
    }

    @Test(arguments: [false, true]) func everyPairMeetsWCAGAA(dark: Bool) throws {
        let results = try Self.resolve(Self.pairs(), dark: dark)
        var failures: [String] = []
        for (pair, value) in results {
            let pass = value >= pair.minimum
            print(String(format: "AUDIT|%@|%@|%.2f|%.1f|%@|%@", dark ? "dark" : "light", pair.id, value, pair.minimum,
                         pair.owner == .alloy ? "alloy" : "metalui", pass ? "ok" : "FAIL"))
            if !pass && pair.owner == .alloy { failures.append("\(pair.id) \(String(format: "%.2f", value)) < \(pair.minimum)") }
        }
        #expect(failures.isEmpty, "\(dark ? "dark" : "light"): \(failures.joined(separator: "; "))")
    }

    @Test func theMathIsWCAG() {
        let black = RGB(r: 0, g: 0, b: 0), white = RGB(r: 1, g: 1, b: 1)
        #expect(abs(ratio(black, white) - 21) < 0.001)
        #expect(abs(ratio(white, white) - 1) < 0.001)
        // #767676 on white is the classic 4.54:1 boundary.
        let grey = RGB(r: 118.0 / 255, g: 118.0 / 255, b: 118.0 / 255)
        #expect(abs(ratio(grey, white) - 4.54) < 0.01)
    }

    @Test func theAuditCoversTheViews() {
        let ids = Set(Self.pairs().map(\.id))
        #expect(ids.count > 250)
        for must in ["sidebar.selected.secondary", "chat.shell.title", "syntax.keyword.panelRemoved", "composer.placeholder",
                     "panel.code.gutter", "coordination.mark.error", "coordination.notice.warning.text", "tabs.hover", "disabled.onSurface", "settings.secondary"] {
            #expect(ids.contains(must), "\(must) is audited")
        }
    }
}
