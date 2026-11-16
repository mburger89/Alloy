import AlloyCore
import Foundation
import MetalUI

/// The palette's overlay, the last child of `AlloyScreen`'s `ZStack`. It reads only `isShowing`: while the palette is
/// closed it produces nothing, so a closed palette costs no elements per frame, and typing into an open one re-runs
/// `CommandPaletteView` alone, never the screen.
struct PaletteLayer: Component, Equatable {
    let model: CommandPaletteModel
    let titleBandHeight: Double

    nonisolated static func == (a: Self, b: Self) -> Bool { a.model === b.model && a.titleBandHeight == b.titleBandHeight }

    var content: some ElementGroup {
        let model = model
        if model.isShowing {
            // Top-centre, just below the title band. Only the panel takes clicks; the frame around it has no handlers.
            VStack(spacing: 0) { CommandPaletteView(model: model).equatable() }
                .padding(Edges(top: Pixels(Float(titleBandHeight + 8)), right: Pixels(0), bottom: Pixels(0), left: Pixels(0)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// The palette panel: a field and up to 50 rows, the selected one highlighted. ↑ ↓ move over every row (disabled ones
/// too), Return or a click runs, Esc or losing focus closes. Ids: `command-palette`, `command-palette-field`,
/// `command-palette-row-<i>`, `command-palette-recent-header`, `command-palette-empty`.
struct CommandPaletteView: Component, Equatable {
    let model: CommandPaletteModel
    @FocusState var focused: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool { a.model === b.model }

    var content: some ElementGroup {
        let model = model
        let query = Binding<String>(get: { model.query }, set: { model.setQuery($0) })
        let rows = model.rows, selected = model.selected
        VStack(alignment: .leading, spacing: Pixels(0)) {
            TextField("Type a command", text: query)
                .onSubmit { model.submit() }
                .focused($focused)
                .onAppear { focused = true }
                .onChange(of: focused) { old, new in if old && !new { model.hide() } }
                .onKeyPress(phases: [.down, .repeat]) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    switch press.key {
                    case .downArrow: model.move(1); return .handled
                    case .upArrow: model.move(-1); return .handled
                    case .escape: model.hide(); return .handled
                    default: return .ignored
                    }
                }
                .padding(inset(12, 8))
                .accessibilityIdentifier("command-palette-field")
            if rows.isEmpty {
                Text("No matching commands").font(size: 12).foregroundColor(.mutedInk)
                    .padding(inset(12, 8))
                    .accessibilityIdentifier("command-palette-empty")
            } else {
                if model.recentCount > 0 && model.query.isEmpty {
                    Text("Recently used").font(size: 11).foregroundColor(.mutedInk)
                        .padding(inset(12, 4))
                        .accessibilityIdentifier("command-palette-recent-header")
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Pixels(0)) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            PaletteRowView(row: row, index: i, isSelected: i == selected) { model.run(row: i) }
                        }
                    }
                }
            }
        }
        .frame(width: Pixels(520))
        .frame(maxHeight: Pixels(360))
        .background(Color.panelFill)
        .cornerRadius(Pixels(10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("command-palette")
    }
}

private struct PaletteRowView: Component {
    let row: PaletteRow
    let index: Int
    let isSelected: Bool
    let onPick: () -> Void

    var content: some ElementGroup {
        let row = row, onPick = onPick, index = index
        HStack(spacing: Pixels(10)) {
            Text(Self.styled(row)).font(size: 13)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(inset(12, 5))
        .background(isSelected ? Color.commandTint : Color.clear)
        .onTapGesture { onPick() }
        .accessibilityElement(children: .contain)
        .accessibilityValue(row.isEnabled ? "" : "unavailable")
        .accessibilityIdentifier("command-palette-row-\(index)")
    }

    /// The title with the matched ranges in the accent ink; a disabled command is muted throughout.
    static func styled(_ row: PaletteRow) -> AttributedString {
        let bytes = Array(row.displayTitle.utf8)
        var out = AttributedString()
        func piece(_ a: Int, _ b: Int, matched: Bool) {
            guard b > a else { return }
            var part = AttributedString(String(decoding: bytes[a..<b], as: UTF8.self))
            if !row.isEnabled { part.foregroundColor = .mutedInk } else if matched { part.foregroundColor = Color(ColorToken.accent) }
            out.append(part)
        }
        var cursor = 0
        for range in row.matched {
            let a = max(range.lowerBound, cursor), b = min(range.upperBound, bytes.count)
            guard b > a else { continue }
            piece(cursor, a, matched: false)
            piece(a, b, matched: true)
            cursor = b
        }
        piece(cursor, bytes.count, matched: false)
        if !row.isEnabled { out.foregroundColor = .mutedInk }
        return out
    }
}
