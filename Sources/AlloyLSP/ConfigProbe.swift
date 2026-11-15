import AlloyCore
import Foundation

/// Finds out whether a project has the config files a linter needs (`ServerConfig.requiresConfigFiles`), walking from
/// the file's folder up to the workspace root. The manager calls it off the main actor and caches the answers.
public struct ConfigProbe: Sendable {
    public var exists: @Sendable (URL) -> Bool
    /// Reads a file; only used for `file#key` entries, and only when no plain name matched in that folder.
    public var read: @Sendable (URL) -> Data?

    public init(exists: @escaping @Sendable (URL) -> Bool,
                read: @escaping @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }) {
        self.exists = exists
        self.read = read
    }

    public static let live = ConfigProbe(exists: { FileManager.default.fileExists(atPath: $0.path) })

    /// The extensions a trailing `*` stands for (`eslint.config.*`, `.eslintrc.*`).
    static let wildcardExtensions = ["js", "cjs", "mjs", "ts", "cts", "mts", "json", "yaml", "yml"]

    /// Whether any of `names` exists in the folder of `path` or one above it, up to `root` inclusive. The nearest
    /// folder wins: each folder is checked fully before its parent, and a folder's `package.json` is read only when
    /// that folder has none of the plain config files. `path` is
    /// project relative (or absolute). A name ending in `*` matches any of the usual config extensions;
    /// `file#key` means `file` is a JSON object with a top-level `key`.
    public func hasConfig(for path: String, names: [String], root: URL) -> Bool {
        guard !names.isEmpty else { return true }
        let rootURL = root.standardizedFileURL
        let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : rootURL.appendingPathComponent(path)
        var dir = file.standardizedFileURL.deletingLastPathComponent()
        let inside = dir.path == rootURL.path || dir.path.hasPrefix(rootURL.path + "/")
        let plain = names.filter { !$0.contains("#") }
        let keyed = names.compactMap { name -> (file: String, key: String)? in
            guard let hash = name.firstIndex(of: "#") else { return nil }
            return (String(name[..<hash]), String(name[name.index(after: hash)...]))
        }
        while true {
            for name in plain {
                for candidate in Self.expand(name) where exists(dir.appendingPathComponent(candidate)) { return true }
            }
            for (file, key) in keyed {
                let url = dir.appendingPathComponent(file)
                guard exists(url), let data = read(url),
                      case .object(let object)? = JSONValue.parse(data), object[key] != nil else { continue }
                return true
            }
            guard inside, dir.path != rootURL.path else { return false }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return false }
            dir = parent
        }
    }

    private static func expand(_ name: String) -> [String] {
        guard name.hasSuffix("*") else { return [name] }
        let stem = String(name.dropLast())
        return wildcardExtensions.map { stem + $0 }
    }
}
