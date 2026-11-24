import Foundation
import Testing
@testable import AlloyPlugins

@Suite("PluginCatalog")
struct PluginCatalogTests {
    private let t = PluginTestFolder()

    @Test func missingDirectoryScansEmptyAndIsNotCreated() {
        let dir = t.root.appendingPathComponent("Plugins")
        #expect(PluginCatalog.scan(dir, pathDirs: []).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func hiddenAndPreviousFoldersAreSkipped() {
        let dir = t.root.appendingPathComponent("Plugins")
        for name in [".running", ".staging", "dev.a.b.previous", "dev.a.b"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        #expect(PluginCatalog.scan(dir, pathDirs: []).map(\.folderName) == ["dev.a.b"])
    }

    @Test func badManifestIsListedWithItsError() {
        let dir = t.root.appendingPathComponent("Plugins")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = dir.appendingPathComponent("dev.good.one")
        try? FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try? #"{"id":"dev.good.one","name":"G","version":"1.0.0"}"#.write(to: good.appendingPathComponent("alloy-plugin.json"), atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("dev.bad.one"), withIntermediateDirectories: true)
        let entries = PluginCatalog.scan(dir, pathDirs: [])
        #expect(entries.map(\.folderName) == ["dev.bad.one", "dev.good.one"])
        guard case .failure(.missingManifest) = entries[0].manifest else { Issue.record("expected missingManifest"); return }
        guard case .success = entries[1].manifest else { Issue.record("expected success"); return }
    }

    @Test func pathsLayout() {
        let p = PluginPaths(appSupport: URL(fileURLWithPath: "/a"))
        #expect(p.plugins.path == "/a/Alloy/Plugins" && p.running.path == "/a/Alloy/Plugins/.running")
        #expect(p.staging.path == "/a/Alloy/Plugins/.staging" && p.data.path == "/a/Alloy/PluginData")
        #expect(p.scratch("dev.a.b").path == "/a/Alloy/PluginData/dev.a.b/tmp")
    }
}
