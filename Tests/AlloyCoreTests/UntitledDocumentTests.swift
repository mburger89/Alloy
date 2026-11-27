@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

/// Untitled documents (File > New File): an empty editable tab under a reserved key that no file-backed service sees.
@MainActor @Suite struct UntitledDocumentTests {
    private func type(_ e: Env, _ key: String, _ text: String) throws {
        _ = try #require(e.ws.document(key)).buffer.replace(0..<0, with: text)
    }

    private func projectFiles(_ e: Env) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: e.root.path)) ?? []).sorted()
    }

    @Test func newUntitledOpensAnEmptyActiveTab() async throws {
        let e = Env(); defer { e.cleanup() }
        e.ws.setMode(.code)
        let key = e.ws.newUntitled()
        #expect(e.ws.tabs(in: e.ws.defaultPane) == [key])
        #expect(e.ws.untitled == [key] && e.ws.isUntitled(key))
        #expect(e.ws.activeTab(in: e.ws.defaultPane) == key)
        let doc = try #require(e.ws.document(key))
        #expect(doc.buffer.snapshot().utf8Count == 0 && doc.state == .editable && doc.language == nil)
        #expect(e.ws.title(of: key) == "Untitled")
        #expect(e.ws.title(of: "src/a.swift") == "a.swift")
    }

    @Test func numberingReusesTheLowestFree() async throws {
        let e = Env(); defer { e.cleanup() }
        e.ws.setMode(.code)
        let keys = (0..<3).map { _ in e.ws.newUntitled() }
        #expect(keys.map { e.ws.title(of: $0) } == ["Untitled", "Untitled 2", "Untitled 3"])
        await e.ws.close(keys[0])
        let again = e.ws.newUntitled()
        #expect(e.ws.title(of: again) == "Untitled")
        #expect(e.ws.untitled.count == 3)
        #expect(Set(e.ws.tabs(in: e.ws.defaultPane)) == Set(keys[1...] + [again]))
    }

    @Test func untitledIsNeverWritten() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "a\n")
        e.ws.setMode(.code)
        await e.ws.open("a.txt")
        let key = e.ws.newUntitled()
        try type(e, key, "typed text")
        #expect(e.ws.document(key)?.isDirty == true)
        // Autosave: the debounce passes with nothing written.
        e.clock.advance(by: 5)
        await e.ws.settle()
        try await e.ws.save(key)
        try await e.ws.save(key, format: true)
        await e.ws.saveAll()
        await e.ws.focusLeft(key)
        e.ws.activate("a.txt", in: e.ws.defaultPane)       // leaving the dirty Untitled tab
        e.ws.activate(key, in: e.ws.defaultPane)
        await e.ws.settle()
        #expect(e.ws.writeCount == 0)
        #expect(projectFiles(e) == ["a.txt"])
        #expect(e.ws.ledger.files[key] == nil && e.ws.ledger.files.isEmpty)
        await e.ws.close(key)
        #expect(e.ws.document(key) == nil && e.ws.untitled.isEmpty)
        #expect(projectFiles(e) == ["a.txt"])
    }

    @Test func untitledStaysOutOfTheSavedLayout() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "a\n")
        e.ws.setMode(.code)
        await e.ws.open("a.txt")
        let key = e.ws.newUntitled()
        try type(e, key, "line one\nline two\n")
        _ = e.ws.selectionState(for: key, in: e.ws.defaultPane)
        let state = e.ws.currentUIState()
        let group = try #require(state.layout?.groups.first)
        #expect(group.tabs == ["a.txt"] && group.active == nil)
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(!json.contains("untitled"), "\(json)")
        #expect(state.folds.values.allSatisfy { $0[key] == nil })
    }

    @Test func untitledHasNoWatcherSearchOrPluginWork() async throws {
        let e = Env(); defer { e.cleanup() }
        e.ws.setMode(.code)
        let key = e.ws.newUntitled()
        try type(e, key, "x")
        #expect(e.ws.document(key)?.isUntitled == true)
        #expect(e.ws.openDocumentPaths.isEmpty)
        #expect(!e.ws.openDocumentPaths.contains(key))
        // An outside change event for the same name finds nothing to reconcile and records nothing.
        await e.fire([key])
        #expect(e.ws.ledger.files.isEmpty)
        #expect(e.ws.document(key)?.buffer.snapshot().utf8Count == 1)
    }

    @Test func discardDropsTheTabAndText() async throws {
        let e = Env(); defer { e.cleanup() }
        e.ws.setMode(.code)
        let key = e.ws.newUntitled()
        try type(e, key, "x")
        #expect(e.ws.untitledHasText(key))
        e.ws.discardUntitled(key, in: e.ws.defaultPane)
        #expect(e.ws.tabs(in: e.ws.defaultPane).isEmpty && e.ws.document(key) == nil && e.ws.untitled.isEmpty)
    }
}
