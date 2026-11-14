import Foundation

public struct ThemeEntry: Equatable, Sendable {
    public var id: String
    public var file: ThemeFile
    public var isBuiltIn: Bool
    public var url: URL?

    public init(id: String, file: ThemeFile, isBuiltIn: Bool, url: URL? = nil) {
        self.id = id
        self.file = file
        self.isBuiltIn = isBuiltIn
        self.url = url
    }
}

public struct ThemeLoadError: Equatable, Sendable {
    public var fileName: String
    public var message: String

    public init(fileName: String, message: String) {
        self.fileName = fileName
        self.message = message
    }
}

public struct ResolvedTheme: Equatable, Sendable {
    public var id: String
    public var name: String
    public var appearance: ThemeAppearance
    public var colors: [String: ThemeRGBA]
    public var sessionColors: [ThemeRGBA]
    public var style: AppearanceStyle = .defaults
}

public struct ThemeLibrary: Equatable, Sendable {
    public static let maxBaseDepth = 8

    public var builtIns: [ThemeEntry]
    public var user: [ThemeEntry]
    public var errors: [ThemeLoadError]

    public init(builtIns: [ThemeEntry] = [], user: [ThemeEntry] = [], errors: [ThemeLoadError] = []) {
        self.builtIns = builtIns
        self.user = user
        self.errors = errors
    }

    public static func userDirectory(appSupport: URL) -> URL {
        appSupport.appendingPathComponent("Alloy", isDirectory: true).appendingPathComponent("Themes", isDirectory: true)
    }

    /// Built-ins in registry order, then user themes sorted by name.
    public var all: [ThemeEntry] { builtIns + user }

    public func entry(_ id: String) -> ThemeEntry? {
        builtIns.first { $0.id == id } ?? user.first { $0.id == id }
    }

    /// The entry a `base` string names: a built-in id first, then a user file stem.
    private func baseEntry(_ base: String) -> ThemeEntry? {
        builtIns.first { $0.id == base } ?? user.first { $0.id == "user/" + base }
    }

    private func fallbackEntry(for appearance: ThemeAppearance) -> ThemeEntry? {
        builtIns.first { $0.id == (appearance == .dark ? "alloy-dark" : "alloy-light") }
    }

    /// The chain from `entry` to its root, `entry` first. Returns nil on a cycle or when it is deeper than the cap.
    private func chain(from start: ThemeEntry) -> [ThemeEntry]? {
        var result = [start]
        var visited: Set<String> = [start.id]
        var current = start
        var explicitLinks = 0
        while true {
            let next: ThemeEntry?
            if let base = current.file.base {
                explicitLinks += 1
                if explicitLinks > Self.maxBaseDepth { return nil }
                next = baseEntry(base) ?? fallbackEntry(for: current.file.appearance)
            } else {
                next = fallbackEntry(for: current.file.appearance)
            }
            guard let next else { return result }
            if next.id == current.id, current.file.base == nil { return result }   // a root default theme
            if visited.contains(next.id) { return nil }
            result.append(next)
            visited.insert(next.id)
            current = next
        }
    }

    public func resolve(_ id: String) -> ResolvedTheme? {
        guard let start = entry(id), let links = chain(from: start) else { return nil }
        var colors: [String: ThemeRGBA] = [:]
        for link in links.reversed() { colors.merge(link.file.colors) { _, new in new } }
        let sessionColors = links.lazy.compactMap { $0.file.sessionColors }.first ?? []
        return ResolvedTheme(id: start.id, name: start.file.name, appearance: start.file.appearance,
                             colors: colors, sessionColors: sessionColors, style: Self.style(along: links))
    }

    /// The nearest value per key along the chain (`links` is entry first), then the defaults, clamped.
    private static func style(along links: [ThemeEntry]) -> AppearanceStyle {
        let files = links.compactMap(\.file.style)
        var s = AppearanceStyle.defaults
        s.gutter = files.lazy.compactMap(\.gutter).first ?? s.gutter
        s.cornerRadius = files.lazy.compactMap(\.cornerRadius).first ?? s.cornerRadius
        s.islandOpacity = files.lazy.compactMap(\.islandOpacity).first ?? s.islandOpacity
        s.controlOpacity = files.lazy.compactMap(\.controlOpacity).first ?? s.controlOpacity
        s.controlBlur = files.lazy.compactMap(\.controlBlur).first ?? s.controlBlur
        s.pillButtons = files.lazy.compactMap(\.pillButtons).first ?? s.pillButtons
        return s.clamped()
    }

    /// A draft merged over its `base` chain like `resolve(_:)`. An unknown or missing base falls back by appearance and
    /// adds a note.
    public func resolve(draft: ThemeFile, id: String = "draft") -> (theme: ResolvedTheme, notes: [String]) {
        var notes: [String] = []
        if let base = draft.base, baseEntry(base) == nil {
            let fallback = draft.appearance == .dark ? "alloy-dark" : "alloy-light"
            notes.append("Unknown base \"\(base)\"; using \(fallback).")
        }
        let entry = ThemeEntry(id: id, file: draft, isBuiltIn: false)
        var library = self
        library.user.removeAll { $0.id == id }
        library.user.append(entry)
        let theme = library.resolve(id)
            ?? ResolvedTheme(id: id, name: draft.name, appearance: draft.appearance, colors: draft.colors,
                             sessionColors: draft.sessionColors ?? [], style: Self.style(along: [entry]))
        return (theme, notes)
    }

    // MARK: Loading

    /// Reads `userDirectory/*.json`. Synchronous and cheap; safe to call from a background context.
    /// A file that stops parsing keeps its `previous` good version and is reported in `errors`.
    /// `listing` returns the candidate files (default: the folder's contents); tests pass their own, since a
    /// case-insensitive volume cannot hold two names that differ only in case.
    public static func load(builtIns: [ThemeEntry], userDirectory: URL, previous: ThemeLibrary?,
                            listing: ((URL) -> [URL])? = nil) -> ThemeLibrary {
        var errors: [ThemeLoadError] = []
        var entries: [ThemeEntry] = []
        var seen: Set<String> = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let urls = listing?(userDirectory) ?? (try? fm.contentsOfDirectory(
            at: userDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []

        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let fileName = url.lastPathComponent
            guard !fileName.hasPrefix("."), url.pathExtension.lowercased() == "json" else { continue }
            let id = "user/" + url.deletingPathExtension().lastPathComponent

            func keepPrevious(_ message: String) {
                errors.append(ThemeLoadError(fileName: fileName, message: message))
                if var old = previous?.user.first(where: { $0.id == id }) {
                    old.url = url
                    entries.append(old)
                }
            }

            // Symlinks are followed (users link themes from a dotfiles repo). The target must be a regular file
            // and is size-checked before reading. Live reload only sees changes inside the themes folder, not
            // changes to a link's target.
            var target = url
            let linkValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if linkValues?.isSymbolicLink == true {
                target = url.resolvingSymlinksInPath()
                guard let targetValues = try? target.resourceValues(forKeys: Set(keys)) else {
                    keepPrevious("Link target is missing")
                    continue
                }
                guard targetValues.isRegularFile == true else {
                    keepPrevious("Link target is not a file")
                    continue
                }
            }
            let values = try? target.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile ?? true else { continue }   // a real folder named x.json is skipped silently

            if !seen.insert(id).inserted {
                errors.append(ThemeLoadError(fileName: fileName, message: "Duplicate of an earlier theme file; ignored"))
                continue
            }

            if let size = values?.fileSize, size > ThemeFile.maxBytes {
                keepPrevious(ThemeFileError.tooLarge(size).message)
                continue
            }
            guard let data = try? Data(contentsOf: target) else {
                keepPrevious("Could not read file")
                continue
            }
            do {
                let file = try ThemeFile.parse(data)
                entries.append(ThemeEntry(id: id, file: file, isBuiltIn: false, url: url))
            } catch {
                keepPrevious(error.message)
            }
        }

        entries.sort {
            let order = $0.file.name.localizedCaseInsensitiveCompare($1.file.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }

        var library = ThemeLibrary(builtIns: builtIns, user: entries, errors: errors)

        // Warn about unknown bases (they resolve via the appearance fallback).
        for entry in library.user {
            if let base = entry.file.base, library.baseEntry(base) == nil {
                let broken = library.errors.contains { $0.fileName == base + ".json" }
                library.errors.append(ThemeLoadError(
                    fileName: entry.url?.lastPathComponent ?? entry.id,
                    message: broken ? "Base \"\(base)\" has an error; using the default \(entry.file.appearance.rawValue) theme" : "Unknown base \"\(base)\"; using the default \(entry.file.appearance.rawValue) theme"))
            }
        }
        // Skip themes whose base chain loops or runs too deep.
        let broken = library.user.filter { library.chain(from: $0) == nil }
        if !broken.isEmpty {
            let ids = Set(broken.map(\.id))
            for entry in broken {
                library.errors.append(ThemeLoadError(
                    fileName: entry.url?.lastPathComponent ?? entry.id,
                    message: "Base chain loops or is deeper than \(maxBaseDepth); theme skipped"))
            }
            library.user.removeAll { ids.contains($0.id) }
        }
        return library
    }
}
