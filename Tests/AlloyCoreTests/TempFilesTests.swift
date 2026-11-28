import Testing
import Foundation
import AlloyTestSupport

@Suite struct TempFilesTests {
    @Test func scratchDirIsGoneWhenItsOwnerGoesAway() throws {
        var owner: TempDir? = TempDir("alloy-scratch-test")
        let url = try #require(owner?.url)
        try "x".write(to: url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: url.path))
        owner = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func removeDeletesATrackedPathAndMissingPathsAreHarmless() {
        let dir = TempFiles.directory("alloy-scratch-test")
        #expect(FileManager.default.fileExists(atPath: dir.path))
        TempFiles.remove(dir)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        TempFiles.remove(dir)
        #expect(!FileManager.default.fileExists(atPath: TempFiles.url("alloy-scratch-test", ext: ".txt").path))
    }
}
