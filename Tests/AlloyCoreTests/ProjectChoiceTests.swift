import AlloyCore
import Foundation
import Testing

@Suite struct ProjectChoiceTests {
    private let home = "/home/me"
    private let dirs: Set<String> = ["/work/proj", "/work", "/home/me/code/app", "/home/me", "/", "/other"]

    private var links: [String: String] = [:]
    private var existing: Set<String> = []

    private func resolve(_ args: [String], last: String? = nil, cwd: String = "/work") -> ProjectChoice {
        detailed(args, last: last, cwd: cwd).choice
    }

    private func detailed(_ args: [String], last: String? = nil, cwd: String = "/work") -> (choice: ProjectChoice, reason: String?) {
        let settings = AlloySettings(lastProjectPath: last)
        let links = links, existing = existing
        return ProjectChoice.resolveDetailed(arguments: args, settings: settings, isDirectory: { dirs.contains($0) }, home: home, cwd: cwd,
                                             resolveSymlinks: { links[$0] ?? $0 }, fileExists: { existing.contains($0) })
    }

    @Test func symlinkToHomeOrRootIsRejected() {
        var t = self
        t.links = ["/work/homelink": "/home/me", "/work/rootlink": "/"]
        #expect(t.resolve(["/work/homelink"]) == .askUser)
        #expect(t.resolve(["/work/rootlink"]) == .askUser)
        #expect(t.resolve([], last: "/work/homelink") == .askUser)
        #expect(t.resolve(["/work/homelink"], last: "/work/proj") == .askUser)
    }

    @Test func caseVariantOfHomeIsRejected() {
        #expect(resolve(["/home/ME"]) == .askUser)
        #expect(resolve([], last: "/HOME/me") == .askUser)
    }

    @Test func homeThatIsItselfASymlinkIsRejected() {
        var t = self
        t.links = ["/home/me": "/Volumes/data/me", "/work/h": "/Volumes/data/me"]
        #expect(t.resolve(["/work/h"]) == .askUser)
    }

    @Test func rejectionsCarryAReason() {
        #expect(detailed(["/"]).reason?.contains("home folder") == true)
        #expect(detailed(["/work/missing"]).reason?.contains("not a folder") == true)
        #expect(detailed(["/work/proj", "/work/x"]).reason?.contains("not inside") == true)
        #expect(detailed([]).reason == nil)
        #expect(detailed(["/work/proj"]).reason == nil)
    }

    @Test func prefersAnExistingCandidate() {
        var t = self
        t.existing = ["/work/proj/a.swift"]
        #expect(t.resolve(["/work/proj", "a.swift"], cwd: "/work/proj/src") == .open(root: URL(fileURLWithPath: "/work/proj"), file: "a.swift"))
        t.existing = ["/work/proj/src/a.swift"]
        #expect(t.resolve(["/work/proj", "a.swift"], cwd: "/work/proj/src") == .open(root: URL(fileURLWithPath: "/work/proj"), file: "src/a.swift"))
    }

    @Test func argvDirectory() {
        #expect(resolve(["/work/proj"]) == .open(root: URL(fileURLWithPath: "/work/proj"), file: nil))
    }

    @Test func argvDirectoryAndFile() {
        #expect(resolve(["/work/proj", "/work/proj/src/a.swift"]) == .open(root: URL(fileURLWithPath: "/work/proj"), file: "src/a.swift"))
        #expect(resolve(["/work/proj", "src/a.swift"], cwd: "/work/proj") == .open(root: URL(fileURLWithPath: "/work/proj"), file: "src/a.swift"))
    }

    @Test func relativePathsResolveAgainstCwd() {
        #expect(resolve(["proj"]) == .open(root: URL(fileURLWithPath: "/work/proj"), file: nil))
        #expect(resolve(["."], cwd: "/work/proj") == .open(root: URL(fileURLWithPath: "/work/proj"), file: nil))
        #expect(resolve(["../proj"], cwd: "/work/proj") == .open(root: URL(fileURLWithPath: "/work/proj"), file: nil))
    }

    @Test func fileOutsideRootIsRejected() {
        #expect(resolve(["/work/proj", "/work/other.swift"]) == .askUser)
        #expect(resolve(["/work/proj", "../x.swift"], cwd: "/work/proj") == .askUser)
        #expect(resolve(["/work/proj", "/work/proj"]) == .askUser)
    }

    @Test func rootAndHomeAreRejected() {
        #expect(resolve(["/"], last: "/work/proj") == .askUser)
        #expect(resolve(["/home/me"], last: "/work/proj") == .askUser)
        #expect(resolve(["/home/me/"]) == .askUser)
        #expect(resolve([], last: "/") == .askUser)
        #expect(resolve([], last: "/home/me") == .askUser)
    }

    @Test func notADirectoryIsRejected() {
        #expect(resolve(["/work/missing"], last: "/work/proj") == .askUser)
    }

    @Test func homeSubdirectoryIsAllowed() {
        #expect(resolve(["/home/me/code/app"]) == .open(root: URL(fileURLWithPath: "/home/me/code/app"), file: nil))
    }

    @Test func fallsBackToLastProject() {
        #expect(resolve([], last: "/work/proj") == .open(root: URL(fileURLWithPath: "/work/proj"), file: nil))
    }

    @Test func missingLastProjectAsksUser() {
        #expect(resolve([]) == .askUser)
        #expect(resolve([], last: "/gone") == .askUser)
    }

    @Test func lastProjectPathRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-set-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try AlloySettings(lastProjectPath: "/work/proj").save(appSupport: dir)
        #expect(AlloySettings.load(appSupport: dir).lastProjectPath == "/work/proj")
    }
}
