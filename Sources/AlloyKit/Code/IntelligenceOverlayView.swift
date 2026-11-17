import AlloyLSP
import Foundation
import MetalUI

/// The content of the code view's suggestion overlay: the completion rows (kind glyph, label, dimmed detail) and, beside
/// them, the selected item's documentation. It is the one reader of ``IntelligenceOverlayModel``, so typing inside the word
/// re-runs this and nothing around it.
struct IntelligenceOverlayView: Component {
    let model: IntelligenceOverlayModel
    let onPick: (Int) -> Void

    var content: some ElementGroup {
        let signature = model.signature
        let actions = model.actions
        let rows = model.rows, selected = model.selected, doc = model.doc, onPick = onPick, cache = model.markdownCache
        VStack(alignment: .leading, spacing: Pixels(0)) {
        if let signature {
            let (before, active, after) = signature.parts
            HStack(spacing: Pixels(0)) {
                Text(verbatim: before).font(family: "Menlo", size: 12)
                if !active.isEmpty { Text(verbatim: active).font(family: "Menlo", size: 12).foregroundColor(.linkInk) }
                Text(verbatim: after).font(family: "Menlo", size: 12)
                if signature.count > 1 {
                    Text(verbatim: "  \(signature.index + 1)/\(signature.count)").font(size: 11).foregroundColor(.mutedInk)
                }
            }
            .padding(inset(8, 4))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("signature-help")
        }
        if !actions.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: Pixels(0)) {
                    ForEach(Array(actions.enumerated()), id: \.element.index) { i, row in
                        HStack(spacing: Pixels(8)) {
                            Text(verbatim: row.title).font(size: 12)
                                .foregroundColor(row.disabledReason == nil ? Color.primary : Color.mutedInk)
                            if let reason = row.disabledReason {
                                Text(verbatim: reason).font(size: 11).foregroundColor(.mutedInk)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(inset(8, 4))
                        .background(i == selected ? Color.commandTint : Color.clear)
                        .onTapGesture { onPick(i) }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("code-action-\(i)")
                    }
                }
            }
            .frame(width: Pixels(380))
            .frame(maxHeight: Pixels(240))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("code-action-menu")
        }
        if !rows.isEmpty {
        HStack(alignment: .top, spacing: Pixels(0)) {
            ScrollView {
                VStack(alignment: .leading, spacing: Pixels(0)) {
                    ForEach(Array(rows.enumerated()), id: \.element.index) { i, row in
                        HStack(spacing: Pixels(8)) {
                            Text(verbatim: row.kindGlyph).font(family: "Menlo", size: 11).foregroundColor(.mutedInk)
                                .frame(width: Pixels(14))
                            Text(verbatim: row.label).font(family: "Menlo", size: 12)
                            if let detail = row.detail {
                                Text(verbatim: detail).font(size: 11).foregroundColor(.mutedInk)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(inset(8, 4))
                        .background(i == selected ? Color.commandTint : Color.clear)
                        .onTapGesture { onPick(i) }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("completion-row-\(i)")
                    }
                }
            }
            .frame(width: Pixels(380))
            .frame(maxHeight: Pixels(240))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("completion-popup")
            if let doc {
                ScrollView {
                    VStack(alignment: .leading, spacing: Pixels(0)) {
                        MarkdownText(blockID: "completion-doc", text: doc, cache: cache)
                    }
                    .padding(inset(10, 8))
                }
                .frame(width: Pixels(320))
                .frame(maxHeight: Pixels(240))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("completion-doc")
            }
        }
        }
        }
        .background(Color.panelFill)
        .cornerRadius(Pixels(8))
    }
}
