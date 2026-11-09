import MetalUI

/// The shared frame of a transcript block: a header row (kind icon, title, summary, trailing chip) over an
/// optional body, on the kind's tint. Clicking the header toggles `collapsed` when one is given; the body
/// shows while expanded. The header is identified `block-header-<id>`.
struct BlockChrome<Body: ElementGroup>: Component {
    let kind: BlockKind
    let title: String
    let summary: String
    let trailing: String?
    let collapsed: Binding<Bool>?
    let id: String
    /// Makes the title a link that opens the block's file (`open-path-<id>`).
    let openPath: (() -> Void)?
    let body: Body

    init(kind: BlockKind, title: String, summary: String = "", trailing: String? = nil,
         collapsed: Binding<Bool>? = nil, id: String, openPath: (() -> Void)? = nil,
         @ElementBuilder body: () -> Body) {
        self.kind = kind; self.title = title; self.summary = summary; self.trailing = trailing
        self.collapsed = collapsed; self.id = id; self.openPath = openPath; self.body = body()
    }

    var content: some ElementGroup {
        let style = BlockStyle.style(kind)
        let collapsed = collapsed
        let isCollapsed = collapsed?.wrappedValue ?? false
        VStack(alignment: .leading, spacing: Pixels(6)) {
            HStack(spacing: Pixels(8)) {
                if collapsed != nil {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10)).foregroundColor(.mutedInk).accessibilityHidden(true)
                }
                Image(systemName: style.icon).font(.system(size: 12)).foregroundColor(style.ink).accessibilityHidden(true)
                if let openPath {
                    // A real button: keyboard and VoiceOver reach it, and its press never reaches the header's collapse tap.
                    Button { openPath() } label: {
                        Text(verbatim: title).font(size: 12).foregroundColor(.linkInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("open-path-\(id)")
                } else {
                    Text(verbatim: title).font(size: 12)
                }
                if !summary.isEmpty {
                    Text(verbatim: summary).font(size: 12).foregroundColor(.mutedInk)
                }
                Spacer()
                if let trailing {
                    Text(verbatim: trailing).font(size: 11).foregroundColor(.mutedInk)
                        .padding(inset(6, 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onTapGesture { if let collapsed { collapsed.wrappedValue.toggle() } }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("block-header-\(id)")
            if !isCollapsed {
                body
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(inset(10, 8))
        .background(style.tint)
        .cornerRadius(Pixels(8))
    }
}
