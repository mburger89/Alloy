import AlloyCore
import Foundation

public enum PluginInstallError: Error, Equatable {
    case badManifest(PluginManifestError)
    case symlinkEscape(String)
    case alreadyInstalled(from: PluginSource)
    case io(String)
}

/// Copies a plugin folder into Alloy's plugin directory, validating it first, and removes installed plugins.
public struct PluginInstaller: Sendable {
    public let paths: PluginPaths
    public let pathDirs: [String]

    public init(paths: PluginPaths, pathDirs: [String]) {
        self.paths = paths
        self.pathDirs = pathDirs
    }

    /// Copies `source` into staging (links stay links), refuses any link that resolves outside the copy, validates the
    /// manifest there, then moves the folder to `plugins/<id>`. The same id from another source is refused; the same
    /// folder path reinstalls over the old copy.
    @discardableResult
    public func installFolder(_ chosen: URL, installed: [String: PluginSetting]) throws(PluginInstallError) -> PluginManifest {
        let fm = FileManager.default
        // A source that is itself a link is copied as the real folder, not as a link into a staging folder.
        let source = chosen.resolvingSymlinksInPath()
        let job = paths.staging.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: job) }
        let copy = job.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.createDirectory(at: job, withIntermediateDirectories: true)
            try Self.copyTree(from: source, to: copy)
        } catch {
            throw .io(error.localizedDescription)
        }
        if let escaped = Self.firstEscapingLink(in: copy) { throw .symlinkEscape(escaped) }
        let manifest: PluginManifest
        switch PluginManifestLoader.load(folder: copy, pathDirs: pathDirs) {
        case .success(let m): manifest = m
        case .failure(let e): throw .badManifest(e)
        }
        if let existing = installed[manifest.id], !Self.sameSource(existing.source, chosen) {
            throw .alreadyInstalled(from: existing.source)
        }
        let target = paths.plugins.appendingPathComponent(manifest.id)
        do {
            try fm.createDirectory(at: paths.plugins, withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: copy)
            } else {
                try fm.moveItem(at: copy, to: target)
            }
        } catch {
            throw .io(error.localizedDescription)
        }
        return manifest
    }

    /// The same folder, compared after standardizing and resolving links on both sides.
    private static func sameSource(_ recorded: PluginSource, _ folder: URL) -> Bool {
        guard case .folder(let path) = recorded else { return false }
        func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        return key(URL(fileURLWithPath: path)) == key(folder)
    }

    /// `installFolder` as a `Result`, for callers that run it off an actor.
    public func install(folder source: URL, installed: [String: PluginSetting]) -> Result<PluginManifest, PluginInstallError> {
        do throws(PluginInstallError) { return .success(try installFolder(source, installed: installed)) } catch { return .failure(error) }
    }

    /// Deletes the plugin's folder and its data. A missing folder is not an error.
    public func remove(id: String) throws {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix("."), !id.contains("..") else { return }
        let fm = FileManager.default
        for url in [paths.plugins.appendingPathComponent(id), paths.data.appendingPathComponent(id)] where fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            try fm.removeItem(at: url)
        }
    }

    private static func copyTree(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let type = try fm.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: try fm.destinationOfSymbolicLink(atPath: source.path))
        } else if type == .typeDirectory {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: source.path) {
                try copyTree(from: source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            }
        } else {
            try fm.copyItem(at: source, to: destination)
        }
    }

    /// The relative path of the first symbolic link in `root` whose target resolves outside `root`.
    private static func firstEscapingLink(in root: URL) -> String? {
        let fm = FileManager.default
        let base = root.resolvingSymlinksInPath().path
        func walk(_ dir: URL, _ prefix: String) -> String? {
            for name in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() {
                let url = dir.appendingPathComponent(name)
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                if let target = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                    let absolute = target.hasPrefix("/") ? URL(fileURLWithPath: target)
                        : dir.appendingPathComponent(target)
                    let resolved = absolute.standardized.resolvingSymlinksInPath().path
                    if resolved != base && !resolved.hasPrefix(base + "/") { return rel }
                } else if (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory,
                          let hit = walk(url, rel) {
                    return hit
                }
            }
            return nil
        }
        return walk(root, "")
    }
}
