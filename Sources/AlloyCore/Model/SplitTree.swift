import Foundation

/// Direction of a split. `horizontal` places the two children side by side.
public enum SplitAxis: String, Codable, Sendable {
    case horizontal, vertical
}

public enum FocusDirection: Sendable {
    case left, right, up, down
}

/// Nested editor splits. Leaves are editor group ids; every split halves its space.
public indirect enum SplitTree: Codable, Equatable, Sendable {
    case group(UUID)
    case split(id: UUID, axis: SplitAxis, first: SplitTree, second: SplitTree)

    /// Group ids in tree order (first child before second).
    public var groupIDs: [UUID] {
        switch self {
        case .group(let id): [id]
        case .split(_, _, let first, let second): first.groupIDs + second.groupIDs
        }
    }

    public var splitIDs: [UUID] {
        switch self {
        case .group: []
        case .split(let id, _, let first, let second): [id] + first.splitIDs + second.splitIDs
        }
    }

    /// The leaf `group` becomes a split holding it first and `newGroup` second.
    public func splitting(_ group: UUID, axis: SplitAxis, newGroup: UUID, newSplit: UUID) -> SplitTree {
        switch self {
        case .group(let id):
            guard id == group else { return self }
            return .split(id: newSplit, axis: axis, first: .group(id), second: .group(newGroup))
        case .split(let id, let ax, let first, let second):
            return .split(
                id: id, axis: ax,
                first: first.splitting(group, axis: axis, newGroup: newGroup, newSplit: newSplit),
                second: second.splitting(group, axis: axis, newGroup: newGroup, newSplit: newSplit))
        }
    }

    /// Removes `group`; its parent split is replaced by the sibling. `focus` is the sibling's first
    /// leaf when the removed group was the first child, else its last leaf. Nil when `group` is the
    /// only group (or absent).
    public func removing(_ group: UUID) -> (tree: SplitTree, focus: UUID)? {
        guard case .split(let id, let axis, let first, let second) = self else { return nil }
        if case .group(let g) = first, g == group {
            return (second, second.groupIDs.first!)
        }
        if case .group(let g) = second, g == group {
            return (first, first.groupIDs.last!)
        }
        if let r = first.removing(group) {
            return (.split(id: id, axis: axis, first: r.tree, second: second), r.focus)
        }
        if let r = second.removing(group) {
            return (.split(id: id, axis: axis, first: first, second: r.tree), r.focus)
        }
        return nil
    }

    /// The group next to `group` in `direction`: laid out in the unit square with every split at 0.5,
    /// candidates touch the source's edge on that side; the largest perpendicular overlap wins, then
    /// tree order.
    public func neighbour(of group: UUID, _ direction: FocusDirection) -> UUID? {
        var rects: [(id: UUID, rect: Rect)] = []
        layout(Rect(x0: 0, y0: 0, x1: 1, y1: 1), into: &rects)
        guard let src = rects.first(where: { $0.id == group })?.rect else { return nil }
        var best: (id: UUID, overlap: Double)?
        for (id, r) in rects where id != group {
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

    /// Keeps only groups in `keeping`; splits left with one child collapse into it. Nil when nothing remains.
    public func pruned(keeping: Set<UUID>) -> SplitTree? {
        switch self {
        case .group(let id):
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

    private struct Rect { var x0, y0, x1, y1: Double }

    private func layout(_ r: Rect, into out: inout [(id: UUID, rect: Rect)]) {
        switch self {
        case .group(let id):
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
