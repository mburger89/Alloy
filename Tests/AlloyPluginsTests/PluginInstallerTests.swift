import AlloyCore
import Foundation
import Testing
@testable import AlloyPlugins

@Suite struct PluginInstallerTests {
    private let tmp = PluginTestFolder()

    private func paths() -> PluginPaths { PluginPaths(appSupport: tmp.root.appendingPathComponent("support")) }

    private func installer() -> PluginInstaller { PluginInstaller(paths: paths(), pathDirs: []) }

    private let theme = #"{"name":"Midnight","appearance":"dark","colors":{}}"#

    @discardableResult
    private func source(_ id: String = "dev.example.pack", in group: String = "src") -> URL {
        let dir = tmp.plugin(group + "/" + id, manifest: #"{"id":"\#(id)","name":"Pack","version":"1.0.0","contributes":{"themes":[{"path":"themes/a.json"}]}}"#)
        tmp.file("themes/a.json", in: dir, contents: theme)
        return dir
    }

    @Test func folderInstallCopiesAndValidates() throws {
        let src = source()
        let manifest = try installer().installFolder(src, installed: [:])
        #expect(manifest.id == "dev.example.pack")
        let target = paths().plugins.appendingPathComponent("dev.example.pack")
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("alloy-plugin.json").path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("themes/a.json").path))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: paths().staging.path)) ?? []).isEmpty)
    }

    @Test func badManifestLeavesNothingInstalled() throws {
        let dir = tmp.plugin("src/dev.example.bad", manifest: #"{"id":"dev.example.bad","name":"Bad","version":"1.2"}"#)
        #expect(throws: PluginInstallError.self) { try installer().installFolder(dir, installed: [:]) }
        #expect(!FileManager.default.fileExists(atPath: paths().plugins.appendingPathComponent("dev.example.bad").path))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: paths().staging.path)) ?? []).isEmpty)
    }

    @Test func symlinkOutsideFailsInstall() throws {
        let src = source()
        let outside = tmp.root.appendingPathComponent("outside.txt")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: src.appendingPathComponent("leak"), withDestinationURL: outside)
        do {
            try installer().installFolder(src, installed: [:])
            Issue.record("expected symlinkEscape")
        } catch {
            #expect(error == .symlinkEscape("leak"))
        }
        #expect(!FileManager.default.fileExists(atPath: paths().plugins.appendingPathComponent("dev.example.pack").path))
    }

    @Test func aSymlinkedSourceIsCopiedAsARealFolder() throws {
        let src = source()
        let link = tmp.root.appendingPathComponent("link-to-pack")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: src)
        try installer().installFolder(link, installed: [:])
        let target = paths().plugins.appendingPathComponent("dev.example.pack")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) == nil)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("themes/a.json").path))
    }

    @Test func sameFolderUnderAnotherSpellingIsNotAnotherSource() throws {
        let src = source()
        let spelled = src.deletingLastPathComponent().appendingPathComponent("../src/dev.example.pack")
        let installed = ["dev.example.pack": PluginSetting(source: .folder(path: spelled.path))]
        let manifest = try installer().installFolder(src, installed: installed)
        #expect(manifest.id == "dev.example.pack")
    }

    @Test func symlinkInsideIsCopiedAsALink() throws {
        let src = source()
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("alias.json").path, withDestinationPath: "themes/a.json")
        try installer().installFolder(src, installed: [:])
        let copied = paths().plugins.appendingPathComponent("dev.example.pack/alias.json")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: copied.path)) == "themes/a.json")
    }

    @Test func sameIdFromAnotherSourceIsRefused() throws {
        let first = source(in: "one")
        let second = source(in: "two")
        let existing = PluginSetting(source: .folder(path: first.path))
        do {
            try installer().installFolder(second, installed: ["dev.example.pack": existing])
            Issue.record("expected alreadyInstalled")
        } catch {
            #expect(error == .alreadyInstalled(from: .folder(path: first.path)))
        }
    }

    @Test func sameSourceReinstallsInPlace() throws {
        let src = source()
        let existing = PluginSetting(source: .folder(path: src.path))
        try installer().installFolder(src, installed: [:])
        tmp.file("extra.txt", in: src, contents: "new")
        try installer().installFolder(src, installed: ["dev.example.pack": existing])
        #expect(FileManager.default.fileExists(atPath: paths().plugins.appendingPathComponent("dev.example.pack/extra.txt").path))
    }

    @Test func removeDeletesFolder() throws {
        try installer().installFolder(source(), installed: [:])
        let data = paths().data.appendingPathComponent("dev.example.pack")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try installer().remove(id: "dev.example.pack")
        #expect(!FileManager.default.fileExists(atPath: paths().plugins.appendingPathComponent("dev.example.pack").path))
        #expect(!FileManager.default.fileExists(atPath: data.path))
    }
}
