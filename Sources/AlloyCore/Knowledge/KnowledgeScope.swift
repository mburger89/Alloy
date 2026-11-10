import Foundation

/// The projects whose files one session's notes tools may name, and how a file is keyed. A file under the session's
/// own root is keyed relative to it, as before; a file under another known project is keyed by its absolute real
/// path. Every root is a real path, so one folder spelled two ways is one project.
public struct KnowledgeScope: Sendable, Equatable {
    /// The session's own project root (real path).
    public let ownRoot: String
    /// Every known root (real paths), the own root included, without repeats.
    public let roots: [String]
    /// The standardized spelling each root was registered under (real or not), for lexical checks only.
    public let spellings: [String]

    /// `known` roots are used exactly as the pool stores them (real paths, written by the windows that own them);
    /// only `ownRoot` is resolved, once.
    public init(ownRoot: String, known: [KnownProject]) {
        func standard(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }
        let own = NotePath.realPath(ownRoot) ?? ownRoot
        var all = [own], forms = [standard(ownRoot), own]
        for k in known {
            if !all.contains(k.root) { all.append(k.root) }
            let f = standard(k.root)
            if !forms.contains(f) { forms.append(f) }
            if !forms.contains(k.root) { forms.append(k.root) }
        }
        self.ownRoot = own
        self.roots = all
        self.spellings = forms
    }

    /// A scope of only the session's own project.
    public init(ownRoot: String) { self.init(ownRoot: ownRoot, known: []) }

    /// The deepest known root that `path` is strictly under.
    private func container(of path: String) -> String? {
        roots.filter { NotePath.isUnder(path, root: $0) }.max { $0.count < $1.count }
    }

    /// The key for a real path: relative when strictly under the own root, absolute when strictly under another
    /// known root, nil otherwise (including a known root itself).
    public func key(forReal path: String) -> String? {
        if roots.contains(path) { return nil }
        if NotePath.isUnder(path, root: ownRoot) { return String(path.dropFirst(ownRoot.count + 1)) }
        return container(of: path) == nil ? nil : path
    }

    public func absolute(_ key: String) -> String { key.hasPrefix("/") ? key : ownRoot + "/" + key }

    /// The project root a key belongs to.
    public func root(ofKey key: String) -> String? {
        key.hasPrefix("/") ? container(of: key) : ownRoot
    }

    /// The folder name, or enough parent components to tell it from every other known project with the same name.
    public func label(ofRoot root: String) -> String {
        let parts = root.split(separator: "/").map(String.init)
        func tail(_ r: String, _ n: Int) -> String { r.split(separator: "/").suffix(n).joined(separator: "/") }
        let rivals = roots.filter { $0 != root && ($0 as NSString).lastPathComponent == (root as NSString).lastPathComponent }
        guard !rivals.isEmpty else { return parts.last ?? root }
        for n in 2..<max(parts.count, 2) + 1 {
            let mine = tail(root, n)
            if !rivals.contains(where: { tail($0, n) == mine }) { return mine }
        }
        return tail(root, parts.count)
    }

    /// A key as shown to a model: own keys unchanged, other projects' as `<project label>/<relative>`.
    public func display(_ key: String) -> String {
        guard key.hasPrefix("/"), let r = root(ofKey: key) else { return key }
        return label(ofRoot: r) + "/" + String(key.dropFirst(r.count + 1))
    }
}
