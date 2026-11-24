import Foundation

public struct PluginCatalogEntry: Equatable, Sendable {
    public var folder: URL
    public var folderName: String
    public var manifest: Result<PluginManifest, PluginManifestError>

    public init(folder: URL, folderName: String, manifest: Result<PluginManifest, PluginManifestError>) {
        self.folder = folder
        self.folderName = folderName
        self.manifest = manifest
    }
}

public enum PluginCatalog {
    /// Every plugin folder in `directory`, sorted by folder name. Hidden folders (`.running`, `.staging`) and
    /// `*.previous` update backups are skipped; a missing directory gives `[]` and is not created.
    public static func scan(_ directory: URL, pathDirs: [String]) -> [PluginCatalogEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var entries: [PluginCatalogEntry] = []
        for name in names.sorted() where !name.hasPrefix(".") && !name.hasSuffix(".previous") {
            let folder = directory.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
            entries.append(PluginCatalogEntry(folder: folder, folderName: name,
                                              manifest: PluginManifestLoader.load(folder: folder, pathDirs: pathDirs)))
        }
        return entries
    }
}
