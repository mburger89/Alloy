import Foundation

/// The background image in effect for the shown theme: where it is and whether it can be read.
public struct BackgroundImage: Equatable, Sendable {
    /// The file's name, as Settings shows it.
    public var name: String
    public var path: String
    /// False when the file is missing, so nothing is drawn and Settings says so.
    public var exists: Bool
    /// The file's modification time, so a replaced file is decoded again.
    public var stamp: Double

    public init(name: String, path: String, exists: Bool, stamp: Double = 0) {
        self.name = name
        self.path = path
        self.exists = exists
        self.stamp = stamp
    }
}

/// The user's per-theme background images, kept as copies in `<appSupport>/Alloy/Backgrounds/` and recorded in
/// `AlloySettings.backgroundImages` (theme id to stored file name; the empty string hides the theme file's own image).
public struct BackgroundImageStore: Sendable {
    /// The settings value that hides the image a theme file names.
    public static let hidden = ""

    public let appSupport: URL

    public init(appSupport: URL) { self.appSupport = appSupport }

    public var directory: URL { appSupport.appendingPathComponent("Alloy/Backgrounds", isDirectory: true) }

    /// The image for `theme`: the settings' choice when there is one, else the theme file's key.
    public func resolve(theme: ResolvedTheme, choices: [String: String]) -> BackgroundImage? {
        if let stored = choices[theme.id] {
            if stored == Self.hidden { return nil }
            return describe(name: stored, url: directory.appendingPathComponent(stored))
        }
        guard let name = theme.backgroundImageName else { return nil }
        guard let url = theme.backgroundImageURL else { return BackgroundImage(name: name, path: "", exists: false) }
        return describe(name: name, url: url)
    }

    private func describe(name: String, url: URL) -> BackgroundImage {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        let stamp = exists ? ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0) : 0
        return BackgroundImage(name: name, path: url.path, exists: exists, stamp: stamp)
    }

    /// Copies `source` in as the image of `themeID`, replacing any earlier copy for that theme, and returns the stored name.
    public func adopt(_ source: URL, themeID: String, replacing previous: String?) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()
        let stem = String(themeID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        let name = ext.isEmpty ? stem : stem + "." + ext
        let target = directory.appendingPathComponent(name)
        let temp = directory.appendingPathComponent(".incoming-" + UUID().uuidString)
        try fm.copyItem(at: source, to: temp)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: temp, to: target)
        if let previous, !previous.isEmpty, previous != name { try? fm.removeItem(at: directory.appendingPathComponent(previous)) }
        return name
    }

    /// Deletes the copy named `stored`.
    public func delete(_ stored: String) {
        guard !stored.isEmpty, !stored.contains("/") else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(stored))
    }
}
