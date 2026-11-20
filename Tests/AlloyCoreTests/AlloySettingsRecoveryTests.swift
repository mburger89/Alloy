@testable import AlloyCore
import Foundation
import Testing

@Suite struct AlloySettingsRecoveryTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-set-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func plant(_ bytes: Data, in appSupport: URL) throws -> URL {
        let file = AlloySettings.url(appSupport: appSupport)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        return file
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? 0) & 0o777
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func corruptSettingsAreMovedAsideBeforeDefaultsAreSaved() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let garbage = Data("{ not json".utf8)
        let file = try plant(garbage, in: dir)
        let r = AlloySettings.loadReportingCorruption(appSupport: dir, now: { fixedNow })
        #expect(r.settings == AlloySettings())
        let moved = try #require(r.movedAside)
        #expect(moved.lastPathComponent == "settings.json.corrupt-1800000000")
        #expect(try Data(contentsOf: moved) == garbage)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(AlloySettings.corruptNotice(movedTo: moved).contains("settings.json.corrupt-1800000000"))
    }

    @Test func wrongShapeJSONCountsAsCorrupt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try plant(Data("[]".utf8), in: dir)
        let r = AlloySettings.loadReportingCorruption(appSupport: dir, now: { fixedNow })
        #expect(r.movedAside != nil)
        #expect(r.settings == AlloySettings())
    }

    @Test func existingCorruptNameIsNotOverwritten() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try plant(Data("second".utf8), in: dir)
        let first = file.deletingLastPathComponent().appendingPathComponent("settings.json.corrupt-1800000000")
        try Data("first".utf8).write(to: first)
        let r = AlloySettings.loadReportingCorruption(appSupport: dir, now: { fixedNow })
        let moved = try #require(r.movedAside)
        #expect(moved != first)
        #expect(try Data(contentsOf: first) == Data("first".utf8))
        #expect(try Data(contentsOf: moved) == Data("second".utf8))
    }

    @Test func missingFileIsNotCorrupt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = AlloySettings.loadReportingCorruption(appSupport: dir)
        #expect(r.movedAside == nil)
        #expect(r.settings == AlloySettings())
    }

    @Test func validFileLoadsWithoutMoving() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = AlloySettings(); s.theme = "nord"
        try s.save(appSupport: dir)
        let r = AlloySettings.loadReportingCorruption(appSupport: dir)
        #expect(r.movedAside == nil)
        #expect(r.settings.theme == "nord")
    }

    @Test func supportDirectoryIs0700() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AlloySettings().save(appSupport: dir)
        #expect(try mode(dir.appendingPathComponent("Alloy")) == 0o700)
    }

    @Test func existingLooseDirectoryIsTightened() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let alloy = dir.appendingPathComponent("Alloy")
        try FileManager.default.createDirectory(at: alloy, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try AlloySettings.ensureSupportDirectory(appSupport: dir)
        #expect(try mode(alloy) == 0o700)
    }

    @Test func symlinkedSupportDirectoryIsNotFollowed() throws {
        let dir = try tempDir()
        let elsewhere = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("Alloy"), withDestinationURL: elsewhere)
        #expect(throws: (any Error).self) { try AlloySettings.ensureSupportDirectory(appSupport: dir) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }
}
