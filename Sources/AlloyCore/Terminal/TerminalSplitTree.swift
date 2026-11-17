import Foundation

/// Nested terminal pane splits inside one tab. Mirrors `SplitTree` (leaves are pane ids, every split
/// halves its space) but stays a separate type so the editor tree is not generalised.
public indirect enum TerminalSplitTree: Codable, Equatable, Sendable {
    case pane(UUID)
    case split(id: UUID, axis: SplitAxis, first: TerminalSplitTree, second: TerminalSplitTree)

    /// Pane ids in tree order (first child before second).
    public var paneIDs: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let first, let second): first.paneIDs + second.paneIDs
        }
    }

    public var splitIDs: [UUID] {
        switch self {
        case .pane: []
        case .split(let id, _, let first, let second): [id] + first.splitIDs + second.splitIDs
        }
    }

    /// The leaf `pane` becomes a split holding it first and `newPane` second.
    public func splitting(_ pane: UUID, axis: SplitAxis, newPane: UUID, newSplit: UUID) -> TerminalSplitTree {
        switch self {
        case .pane(let id):
            guard id == pane else { return self }
            return .split(id: newSplit, axis: axis, first: .pane(id), second: .pane(newPane))
        case .split(let id, let ax, let first, let second):
            return .split(
                id: id, axis: ax,
                first: first.splitting(pane, axis: axis, newPane: newPane, newSplit: newSplit),
                second: second.splitting(pane, axis: axis, newPane: newPane, newSplit: newSplit))
        }
    }

    /// Removes `pane`; its parent split is replaced by the sibling. `focus` is the sibling's first
    /// leaf when the removed pane was the first child, else its last leaf. Nil when `pane` is the
    /// only pane (or absent).
    public func removing(_ pane: UUID) -> (tree: TerminalSplitTree, focus: UUID)? {
        guard case .split(let id, let axis, let first, let second) = self else { return nil }
        if case .pane(let p) = first, p == pane {
            return (second, second.paneIDs.first!)
        }
        if case .pane(let p) = second, p == pane {
            return (first, first.paneIDs.last!)
        }
        if let r = first.removing(pane) {
            return (.split(id: id, axis: axis, first: r.tree, second: second), r.focus)
        }
        if let r = second.removing(pane) {
            return (.split(id: id, axis: axis, first: first, second: r.tree), r.focus)
        }
        return nil
    }

    /// The pane next to `pane` in `direction`: laid out in the unit square with every split at 0.5,
    /// candidates touch the source's edge on that side; the largest perpendicular overlap wins, then
    /// tree order.
    public func neighbour(of pane: UUID, _ direction: FocusDirection) -> UUID? {
        var rects: [(id: UUID, rect: Rect)] = []
        layout(Rect(x0: 0, y0: 0, x1: 1, y1: 1), into: &rects)
        guard let src = rects.first(where: { $0.id == pane })?.rect else { return nil }
        var best: (id: UUID, overlap: Double)?
        for (id, r) in rects where id != pane {
            let touches: Bool
            let overlap: Double
            switch direction {
            case .left: touches = r.x1 == src.x0; overlap = min(r.y1, src.y1) - max(r.y0, src.y0)
            case .right: touches = r.x0 == src.x1; overlap = min(r.y1, src.y1) - max(r.y0, src.y0)
            case .up: touches = r.y1 == src.y0; overlap = min(r.x1, src.x1) - max(r.x0, src.x0)
            case .down: touches = r.y0 == src.y1; overlap = min(r.x1, src.x1) - max(r.x0, src.x0)
            }
            guard touches, overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap { best = (id, overlap) }
        }
        return best?.id
    }

    /// Keeps only panes in `keeping`; splits left with one child collapse into it. Nil when nothing remains.
    public func pruned(keeping: Set<UUID>) -> TerminalSplitTree? {
        switch self {
        case .pane(let id):
            return keeping.contains(id) ? self : nil
        case .split(let id, let axis, let first, let second):
            switch (first.pruned(keeping: keeping), second.pruned(keeping: keeping)) {
            case (let f?, let s?): return .split(id: id, axis: axis, first: f, second: s)
            case (let f?, nil): return f
            case (nil, let s?): return s
            case (nil, nil): return nil
            }
        }
    }

    /// Keeps the first occurrence of every pane id (tree order) and drops later duplicates,
    /// collapsing splits. `seen` carries ids already claimed elsewhere.
    func deduplicated(seen: inout Set<UUID>) -> TerminalSplitTree? {
        switch self {
        case .pane(let id):
            return seen.insert(id).inserted ? self : nil
        case .split(let id, let axis, let first, let second):
            let f = first.deduplicated(seen: &seen)
            let s = second.deduplicated(seen: &seen)
            switch (f, s) {
            case (let f?, let s?): return .split(id: id, axis: axis, first: f, second: s)
            case (let f?, nil): return f
            case (nil, let s?): return s
            case (nil, nil): return nil
            }
        }
    }

    private struct Rect { var x0, y0, x1, y1: Double }

    private func layout(_ r: Rect, into out: inout [(id: UUID, rect: Rect)]) {
        switch self {
        case .pane(let id):
            out.append((id, r))
        case .split(_, let axis, let first, let second):
            switch axis {
            case .horizontal:
                let mid = (r.x0 + r.x1) / 2
                first.layout(Rect(x0: r.x0, y0: r.y0, x1: mid, y1: r.y1), into: &out)
                second.layout(Rect(x0: mid, y0: r.y0, x1: r.x1, y1: r.y1), into: &out)
            case .vertical:
                let mid = (r.y0 + r.y1) / 2
                first.layout(Rect(x0: r.x0, y0: r.y0, x1: r.x1, y1: mid), into: &out)
                second.layout(Rect(x0: r.x0, y0: mid, x1: r.x1, y1: r.y1), into: &out)
            }
        }
    }
}
