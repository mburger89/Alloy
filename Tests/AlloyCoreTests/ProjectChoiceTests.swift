import AlloyCore
import Foundation
import Testing

@Suite struct ProjectChoiceTests {
    private let home = "/home/me"
    private var dirs: Set<String> = ["/work/proj", "/work", "/home/me/code/app", "/home/me", "/", "/other"]

    private var links: [String: String] = [:]
    private var existing: Set<String> = []
    private var gitDirs: Set<String> = []

    private func resolve(_ args: [String], last: String? = nil, cwd: String = "/work") -> ProjectChoice {
        detailed(args, last: last, cwd: cwd).choice
    }

    private func detailed(_ args: [String], last: String? = nil, cwd: String = "/work") -> (choice: ProjectChoice, reason: String?) {
        let settings = AlloySettings(lastProjectPath: last)
        let links = links, existing = existing
        let git = gitDirs
        return ProjectChoice.resolveDetailed(arguments: args, settings: settings, isDirectory: { dirs.contains($0) }, home: home, cwd: cwd,
                                             resolveSymlinks: { links[$0] ?? $0 }, fileExists: { existing.contains($0) },
                                             gitEntryExists: { git.contains($0) })
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

    @Test func singleFileOpensInEnclosingGitRepo() {
        var t = self
        t.existing = ["/work/repo/src/a/b.csv"]
        t.dirs.insert("/work/repo")
        t.gitDirs = ["/work/repo/.git"]
        #expect(t.resolve(["/work/repo/src/a/b.csv"]) == .open(root: URL(fileURLWithPath: "/work/repo"), file: "src/a/b.csv"))
    }

    @Test func singleFileWithoutGitOpensInParent() {
        var t = self
        t.existing = ["/work/loose/data.csv"]
        t.dirs.insert("/work/loose")
        #expect(t.resolve(["/work/loose/data.csv"]) == .open(root: URL(fileURLWithPath: "/work/loose"), file: "data.csv"))
    }

    @Test func singleFileInHomeAsks() {
        var t = self
        t.existing = ["/home/me/notes.txt"]
        t.gitDirs = ["/home/me/.git"]
        let r = t.detailed(["/home/me/notes.txt"])
        #expect(r.choice == .askUser)
        #expect(r.reason?.contains("inside a project folder") == true)
    }

    @Test func relativeSingleFileResolvesAgainstCwd() {
        var t = self
        t.existing = ["/work/repo/src/x.csv"]
        t.dirs.insert("/work/repo")
        t.gitDirs = ["/work/repo/.git"]
        #expect(t.resolve(["x.csv"], cwd: "/work/repo/src") == .open(root: URL(fileURLWithPath: "/work/repo"), file: "src/x.csv"))
    }

    @Test func singleFileInNestedReposPicksNearest() {
        var t = self
        t.existing = ["/work/outer/inner/f.txt"]
        t.dirs.formUnion(["/work/outer", "/work/outer/inner"])
        t.gitDirs = ["/work/outer/.git", "/work/outer/inner/.git"]
        #expect(t.resolve(["/work/outer/inner/f.txt"]) == .open(root: URL(fileURLWithPath: "/work/outer/inner"), file: "f.txt"))
    }
}
