import Testing
import Foundation
@testable import AlloyCore

@Suite(.timeLimit(.minutes(1))) final class KnowledgeScopeTests {
    private let base: String
    init() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        base = try #require(NotePath.realPath(u.path))
    }
    deinit { try? FileManager.default.removeItem(atPath: base) }

    private func dir(_ rel: String) throws -> String {
        let p = base + "/" + rel
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    private func project(_ p: String) -> KnownProject { KnownProject(root: p, name: (p as NSString).lastPathComponent) }

    @Test func ownFileKeepsRelativeKey() throws {
        let own = try dir("own"), api = try dir("api")
        let s = KnowledgeScope(ownRoot: own, known: [project(own), project(api)])
        #expect(s.key(forReal: own + "/Sources/a.swift") == "Sources/a.swift")
        #expect(s.absolute("Sources/a.swift") == own + "/Sources/a.swift")
    }

    @Test func otherProjectFileUsesAbsoluteKey() throws {
        let own = try dir("own"), api = try dir("api")
        let s = KnowledgeScope(ownRoot: own, known: [project(api)])
        let key = try #require(s.key(forReal: api + "/Routes.swift"))
        #expect(key == api + "/Routes.swift")
        #expect(s.display(key) == "api/Routes.swift")
        #expect(s.absolute(key) == key && s.root(ofKey: key) == api)
        #expect(s.display("Sources/a.swift") == "Sources/a.swift")
    }

    @Test func outsideEveryProjectIsNil() throws {
        let own = try dir("own"), api = try dir("api"), other = try dir("other")
        let s = KnowledgeScope(ownRoot: own, known: [project(api)])
        #expect(s.key(forReal: other + "/x.swift") == nil)
        #expect(s.key(forReal: api) == nil && s.key(forReal: own) == nil)
    }

    @Test func knownRootsAreUsedAsStoredNotResolvedAgain() throws {
        let api = try dir("api"), own = try dir("own")
        let link = base + "/apilink"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: api)
        let s = KnowledgeScope(ownRoot: own, known: [KnownProject(root: link, name: "apilink")])
        // A stored root that is now a symlink does not widen the scope to its target.
        #expect(s.roots.contains(link) && !s.roots.contains(api))
        #expect(s.key(forReal: api + "/R.swift") == nil)
        // The own root is still resolved once.
        let ownLink = base + "/ownlink"
        try FileManager.default.createSymbolicLink(atPath: ownLink, withDestinationPath: own)
        #expect(KnowledgeScope(ownRoot: ownLink, known: []).ownRoot == own)
    }

    @Test func danglingLinkInsideAnotherProjectIsRefused() throws {
        let own = try dir("own"), api = try dir("api"), other = try dir("other")
        try FileManager.default.createSymbolicLink(atPath: api + "/dangling", withDestinationPath: other + "/new.txt")
        let s = KnowledgeScope(ownRoot: own, known: [project(api)])
        #expect(NotePath.resolve(api + "/dangling", root: URL(fileURLWithPath: own), scope: s) == nil)
    }

    @Test func anotherProjectsRootItselfIsRefused() throws {
        let own = try dir("own"), api = try dir("api")
        let s = KnowledgeScope(ownRoot: own, known: [project(api)])
        let ownURL = URL(fileURLWithPath: own)
        #expect(NotePath.resolve(api, root: ownURL, scope: s) == nil)
        #expect(NotePath.resolve(api + "/", root: ownURL, scope: s) == nil)
    }

    @Test func deepestRootWinsButOwnRootFirst() throws {
        let own = try dir("own"), lib = try dir("own/vendor/lib"), api = try dir("api")
        let file = lib + "/x.swift"
        let asOwn = KnowledgeScope(ownRoot: own, known: [project(lib), project(api)])
        #expect(asOwn.key(forReal: file) == "vendor/lib/x.swift")
        let asApi = KnowledgeScope(ownRoot: api, known: [project(own), project(lib)])
        #expect(asApi.key(forReal: file) == file)
        #expect(asApi.root(ofKey: file) == lib)
    }

    @Test func sameFolderNamesAreDisambiguated() throws {
        let a = try dir("work/app"), b = try dir("personal/app"), c = try dir("solo")
        let s = KnowledgeScope(ownRoot: a, known: [project(b), project(c)])
        #expect(s.label(ofRoot: a) == "work/app" && s.label(ofRoot: b) == "personal/app")
        #expect(s.label(ofRoot: c) == "solo")
        #expect(s.display(b + "/f.swift") == "personal/app/f.swift")
    }

    @Test func labelsGrowUntilUnique() throws {
        let a = try dir("a/x/app"), b = try dir("b/x/app")
        let s = KnowledgeScope(ownRoot: a, known: [project(b)])
        #expect(s.label(ofRoot: a) == "a/x/app" && s.label(ofRoot: b) == "b/x/app")
    }

    @Test func lexicalCheckAcceptsRegisteredRoot() throws {
        let own = try dir("own"), api = try dir("api")
        try "x\n".write(toFile: api + "/x.swift", atomically: true, encoding: .utf8)
        let s = KnowledgeScope(ownRoot: own, known: [project(api)])
        let r = SharedContextBox.prepare("look at @\(api)/x.swift", own, s)
        #expect(r.candidates == [api + "/x.swift"])
    }

    @Test func unregisteredFolderIsSkipped() throws {
        let own = try dir("own"), api = try dir("api"), other = try dir("other")
        try "x\n".write(toFile: other + "/y.swift", atomically: true, encoding: .utf8)
        let s = KnowledgeScope(ownRoot: own, known: [project(api)])
        #expect(SharedContextBox.prepare("see @\(other)/y.swift", own, s).candidates.isEmpty)
    }

    @Test func otherProjectFileIsServedButLinkOutIsRefused() throws {
        let own = try dir("own"), api = try dir("api"), other = try dir("other")
        try "hello\n".write(toFile: api + "/ok.swift", atomically: true, encoding: .utf8)
        try "secret\n".write(toFile: other + "/s.swift", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: api + "/out", withDestinationPath: other)
        let s = KnowledgeScope(ownRoot: own, known: [project(api)])
        let ownURL = URL(fileURLWithPath: own)
        let ok = try #require(NotePath.resolve(api + "/ok.swift", root: ownURL, scope: s))
        guard case .text(let bytes, _) = NotesTools.readServable(ok) else { Issue.record("refused a known project's file"); return }
        #expect(String(decoding: bytes, as: UTF8.self) == "hello\n")
        #expect(NotePath.resolve(api + "/out/s.swift", root: ownURL, scope: s) == nil)
        // Swapped after resolve: the descriptor check against the containing project refuses it.
        let swapped = NotePath(relative: api + "/out/s.swift", url: URL(fileURLWithPath: api + "/out/s.swift"), root: api)
        guard case .outside = NotesTools.readServable(swapped) else { Issue.record("served through a link out"); return }
    }
}

enum SharedContextBox {
    static func prepare(_ message: String, _ own: String, _ scope: KnowledgeScope) -> (candidates: [String], stamps: [String: FileStamp?]) {
        Workspace.prepareCandidates(message: message, recent: [], root: URL(fileURLWithPath: own), scope: scope)
    }
}
