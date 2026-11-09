import MetalUI

/// The rows under the composer for `/` and `@`: title and detail per row, the selected one highlighted. Identified
/// `suggestions`; rows `suggestion-<i>`. It draws its own background, because `suggestionOverlay` has no chrome.
struct SuggestionList: Component {
    let items: [SuggestionState.Item]
    let selected: Int
    let onPick: (Int) -> Void

    var content: some ElementGroup {
        let items = items, selected = selected, onPick = onPick
        ScrollView {
            VStack(alignment: .leading, spacing: Pixels(0)) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    HStack(spacing: Pixels(10)) {
                        Text(verbatim: item.title).font(size: 12)
                        if let detail = item.detail {
                            Text(verbatim: detail).font(size: 12).foregroundColor(.mutedInk)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(inset(10, 5))
                    .background(i == selected ? Color.commandTint : Color.clear)
                    .onTapGesture { onPick(i) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("suggestion-\(i)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("suggestions")
        }
        .frame(width: Pixels(460))
        .frame(maxHeight: Pixels(240))
        .background(Color.panelFill)
        .cornerRadius(Pixels(8))
    }
}
