@testable import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

private let source = "let x = 1\nlet y = x\n"
private let caps = #""renameProvider":{"prepareProvider":true}"#

@MainActor
struct RenameWordTests {
    private func word(_ text: String, _ at: Int) -> String? {
        let snapshot = CodeBuffer(utf8: Array(text.utf8)).snapshot()
        return RenameWord.range(in: snapshot, at: at).map { String(decoding: snapshot.utf8(in: $0), as: UTF8.self) }
    }

    @Test func caretInsideAtStartAndAtEnd() {
        #expect(word("foo bar", 1) == "foo")
        #expect(word("foo bar", 0) == "foo")
        #expect(word("foo bar", 3) == "foo")     // the word ending at the caret wins
        #expect(word("foo bar", 4) == "bar")
        #expect(word("foo bar", 7) == "bar")
    }

    @Test func betweenWordsAndOnPunctuation() {
        #expect(word("foo.bar", 3) == "foo")
        #expect(word("foo.bar", 4) == "bar")
        #expect(word("a + b", 2) == nil)
        #expect(word("", 0) == nil)
    }

    @Test func nonASCIIIdentifier() {
        #expect(word("let café = 1", 8) == "café")
    }
}

@MainActor
@Suite
struct RenameServiceTests {
    private func uri(_ r: Rig, _ name: String) -> String { r.root.appendingPathComponent(name).absoluteString }

    private func edit(_ r: Rig, _ name: String, _ from: Int, _ to: Int, _ text: String, line: Int = 0, version: String? = nil) -> String {
        let doc = #"{"uri":"\#(uri(r, name))","version":\#(version ?? "null")}"#
        return #"{"textDocument":\#(doc),"edits":[{"range":{"start":{"line":\#(line),"character":\#(from)},"end":{"line":\#(line),"character":\#(to)}},"newText":"\#(text)"}]}"#
    }

    private func changes(_ parts: [String]) -> String { #"{"documentChanges":[\#(parts.joined(separator: ","))]}"# }

    private func script(prepare: String? = #"{"result":{"defaultBehavior":true}}"#, rename: String, caps: String = caps,
                        delay: Int? = nil) -> String {
        var replies = #""textDocument/rename":[\#(rename)]"#
        if let prepare { replies = #""textDocument/prepareRename":[\#(prepare)],"# + replies }
        return IntelRig.script(caps: caps, extra: #","replies":{\#(replies)}"#)
    }

    private func text(_ doc: EditorDocument) -> String {
        let snapshot = doc.buffer.snapshot()
        return String(decoding: snapshot.utf8(in: 0..<snapshot.utf8Count), as: UTF8.self)
    }

    private func disk(_ r: IntelRig, _ name: String) -> String {
        (try? String(contentsOf: r.rig.root.appendingPathComponent(name), encoding: .utf8)) ?? "<missing>"
    }

    private struct Fixture {
        let r: IntelRig
        let window: TestWindow
        let doc: EditorDocument
        let view: OpenDocumentView
        let service: RenameService
        let state: CodeSelectionState
    }

    /// Opens `others` (written with `files`) first, then main.rs in front, and waits until its view knows rename.
    private func fixture(_ r: IntelRig, files: [String: String] = [:], open others: [String] = []) async throws -> Fixture {
        try r.write("main.rs", source)
        for (name, body) in files { try r.write(name, body) }
        var window: TestWindow?
        for name in others {
            if let w = window { r.rig.workspace.openFilePath = name; try await w.runUntil { r.rig.workspace.document(name) != nil } }
            else { window = try await r.open(name) }
        }
        if let w = window {
            r.rig.workspace.openFilePath = "main.rs"
            try await w.runUntil { r.rig.workspace.document("main.rs") != nil }
        } else {
            window = try await r.open("main.rs")
        }
        let w = try #require(window)
        let doc = try #require(r.rig.workspace.document("main.rs"))
        try await w.runUntil { CodePanelStore.existingView(for: doc)?.features.rename == true }
        let view = try #require(CodePanelStore.existingView(for: doc))
        let service = try #require(CodePanelStore.existingRenameService(for: doc))
        let state = try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat))
        return Fixture(r: r, window: w, doc: doc, view: view, service: service, state: state)
    }

    private func target(_ f: Fixture, caret: Int = 5) async throws -> RenameTarget {
        f.state.select(caret..<caret, reveal: false)
        guard case .target(let t) = await f.service.prepare(view: f.view) else { throw TestFailure() }
        return t
    }

    private struct TestFailure: Error {}

    // MARK: Prepare

    @Test func prepareRangeWinsOverTheWord() async throws {
        let prepare = #"{"result":{"range":{"start":{"line":1,"character":8},"end":{"line":1,"character":9}},"placeholder":"x"}}"#
        try await IntelRig.run(script: script(prepare: prepare, rename: #"{"result":null}"#)) { r in
            let f = try await fixture(r)
            f.state.select(4..<4, reveal: false)   // the caret is on `x` of line 0; the server says line 1
            let prepared = await f.service.prepare(view: f.view)
            guard case .target(let t) = prepared else { Issue.record("not a target"); return }
            #expect(t.range == 18..<19)
            #expect(t.oldName == "x")
        }
    }

    @Test func defaultBehaviourAndMissingPrepareUseTheWord() async throws {
        try await IntelRig.run(script: script(rename: #"{"result":null}"#)) { r in
            let f = try await fixture(r)
            let t = try await target(f, caret: 5)
            #expect(t.range == 4..<5 && t.oldName == "x" && t.offset == 5)
        }
        try await IntelRig.run(script: script(prepare: nil, rename: #"{"result":null}"#, caps: #""renameProvider":true"#)) { r in
            let f = try await fixture(r)
            let t = try await target(f, caret: 14)
            #expect(t.oldName == "y")
            #expect(r.count("textDocument/prepareRename") == 0)
        }
    }

    @Test func prepareNullRefusesWithoutRenaming() async throws {
        try await IntelRig.run(script: script(prepare: #"{"result":null}"#, rename: #"{"result":null}"#)) { r in
            let f = try await fixture(r)
            f.state.select(1..<1, reveal: false)
            let prepared = await f.service.prepare(view: f.view)
            #expect(prepared == .refused("Cannot rename this symbol"))
            #expect(r.count("textDocument/rename") == 0)
        }
    }

    @Test func prepareErrorShowsTheServersMessage() async throws {
        let prepare = #"{"error":{"code":-32600,"message":"cannot rename a keyword"}}"#
        try await IntelRig.run(script: script(prepare: prepare, rename: #"{"result":null}"#)) { r in
            let f = try await fixture(r)
            f.state.select(1..<1, reveal: false)
            #expect(await f.service.prepare(view: f.view) == .refused("cannot rename a keyword"))
            #expect(r.count("textDocument/rename") == 0)
        }
    }

    @Test func noWordAtTheCaretRefuses() async throws {
        try await IntelRig.run(script: script(prepare: nil, rename: #"{"result":null}"#, caps: #""renameProvider":true"#)) { r in
            let f = try await fixture(r)
            f.state.select(6..<6, reveal: false)   // between a space and `=`
            #expect(await f.service.prepare(view: f.view) == .refused("No symbol at the caret"))
            #expect(r.count("textDocument/rename") == 0)
        }
    }

    @Test func thePrimaryCaretIsUsed() async throws {
        try await IntelRig.run(script: script(rename: #"{"result":null}"#)) { r in
            let f = try await fixture(r)
            f.state.setSelections([CodeSelection(caret: 14), CodeSelection(caret: 5)], primary: 1)
            guard case .target(let t) = await f.service.prepare(view: f.view) else { Issue.record("not a target"); return }
            #expect(t.oldName == "x" && t.offset == 5)
        }
    }

    // MARK: Commit

    @Test func renamesAnOpenFileAnotherOpenFileAndAClosedFileInOneGroup() async throws {
        let rig = Rig()
        let rename = #"{"result":\#(changes([edit(rig, "main.rs", 4, 5, "z"), edit(rig, "main.rs", 8, 9, "z", line: 1), edit(rig, "other.rs", 0, 1, "z"), edit(rig, "closed.rs", 0, 1, "z")]))}"#
        try await IntelRig.run(rig: rig, script: script(rename: rename)) { r in
            let f = try await fixture(r, files: ["other.rs": "x\n", "closed.rs": "x\n"], open: ["other.rs"])
            let t = try await target(f)
            let result = await f.service.commit(t, newName: "z", view: f.view)
            #expect(result.message == nil)
            #expect(text(f.doc) == "let z = 1\nlet y = z\n")
            let other = try #require(r.rig.workspace.document("other.rs"))
            #expect(text(other) == "z\n")
            #expect(disk(r, "closed.rs") == "z\n")
            #expect(r.rig.workspace.document("closed.rs") == nil)
            #expect(Set(result.rows.map(\.path)) == ["main.rs", "other.rs", "closed.rs"])
            #expect(result.rows.first { $0.path == "main.rs" }?.edits == 2)
            for path in ["main.rs", "other.rs", "closed.rs"] { #expect(r.rig.workspace.hasEdit(group: result.group, path: path)) }
            #expect(f.state.undo())
            #expect(text(f.doc) == source)
        }
    }

    @Test func aTypedEditBeforeTheAnswerApplyingNothing() async throws {
        let rig = Rig()
        let slow = #"{"result":\#(changes([edit(rig, "main.rs", 4, 5, "z")])),"delayMs":300}"#
        try await IntelRig.run(rig: rig, script: script(rename: slow)) { r in
            let f = try await fixture(r)
            let t = try await target(f)
            let task = Task { @MainActor in await f.service.commit(t, newName: "z", view: f.view) }
            while r.count("textDocument/rename") == 0 { await Task.yield() }
            _ = f.doc.buffer.replace(0..<0, with: "q")
            let result = await task.value
            #expect(result.message == "File changed, rename not applied" && result.rows.isEmpty)
            #expect(text(f.doc) == "q" + source)
        }
    }

    @Test func aBufferThatMovedBeforeCommitIsRefused() async throws {
        let rig = Rig()
        try await IntelRig.run(rig: rig, script: script(rename: #"{"result":\#(changes([edit(rig, "main.rs", 4, 5, "z")]))}"#)) { r in
            let f = try await fixture(r)
            let t = try await target(f)
            _ = f.doc.buffer.replace(0..<0, with: "q")
            let result = await f.service.commit(t, newName: "z", view: f.view)
            #expect(result.message == "File changed, rename not applied")
            #expect(r.count("textDocument/rename") == 0)
        }
    }

    @Test func aNumericVersionThatDisagreesChangesNothing() async throws {
        let rig = Rig()
        let bad = #"{"result":\#(changes([edit(rig, "main.rs", 4, 5, "z", version: "999")]))}"#
        try await IntelRig.run(rig: rig, script: script(rename: bad)) { r in
            let f = try await fixture(r)
            let t = try await target(f)
            let result = await f.service.commit(t, newName: "z", view: f.view)
            #expect(result.message == "File changed, rename not applied")
            #expect(text(f.doc) == source)
        }
    }

    @Test func moreThanAThousandFilesChangeNothing() async throws {
        let rig = Rig()
        let parts = (0..<1001).map { edit(rig, "f\($0).rs", 0, 1, "z") }
        try await IntelRig.run(rig: rig, script: script(rename: #"{"result":\#(changes(parts))}"#)) { r in
            for i in 0..<1001 { try r.write("f\(i).rs", "x\n") }
            let f = try await fixture(r)
            let t = try await target(f)
            let result = await f.service.commit(t, newName: "z", view: f.view)
            #expect(result.message?.contains("1,000") == true)
            #expect(text(f.doc) == source)
            #expect(disk(r, "f0.rs") == "x\n")
        }
    }

    @Test func aResourceOperationRefusesTheWholeEdit() async throws {
        let rig = Rig()
        let op = #"{"kind":"create","uri":"\#(uri(rig, "new.rs"))"}"#
        try await IntelRig.run(rig: rig, script: script(rename: #"{"result":\#(changes([edit(rig, "main.rs", 4, 5, "z"), op]))}"#)) { r in
            let f = try await fixture(r)
            let t = try await target(f)
            let result = await f.service.commit(t, newName: "z", view: f.view)
            #expect(result.message == EditRejection.resourceOperation.message)
            #expect(text(f.doc) == source)
        }
    }

    @Test func aServerErrorShowsItsMessage() async throws {
        try await IntelRig.run(script: script(rename: #"{"error":{"code":-32600,"message":"invalid name"}}"#)) { r in
            let f = try await fixture(r)
            let t = try await target(f)
            #expect(await f.service.commit(t, newName: "1", view: f.view).message == "invalid name")
        }
    }

    @Test func aNullAnswerSaysNothingToRename() async throws {
        try await IntelRig.run(script: script(rename: #"{"result":null}"#)) { r in
            let f = try await fixture(r)
            let t = try await target(f)
            #expect(await f.service.commit(t, newName: "z", view: f.view).message == "Nothing to rename")
        }
    }

    @Test func aSlowServerTimesOut() async throws {
        let rig = Rig()
        let slow = #"{"result":\#(changes([edit(rig, "main.rs", 4, 5, "z")])),"delayMs":1500}"#
        try await IntelRig.run(rig: rig, script: script(rename: slow)) { r in
            let f = try await fixture(r)
            f.service.timeout = .milliseconds(100)
            let t = try await target(f)
            let result = await f.service.commit(t, newName: "z", view: f.view)
            #expect(result.message == "Rename timed out")
            #expect(text(f.doc) == source)
        }
    }

    // MARK: Ineligible views

    @Test func aReadOnlyDocumentNeverReachesTheServer() async throws {
        try await IntelRig.run(script: script(rename: #"{"result":null}"#)) { r in
            let f = try await fixture(r)
            f.doc.state = .readOnly(reason: "test")
            f.state.select(5..<5, reveal: false)
            guard case .refused = await f.service.prepare(view: f.view) else { Issue.record("expected refusal"); return }
            #expect(r.count("textDocument/prepareRename") == 0 && r.count("textDocument/rename") == 0)
        }
    }

    @Test func theOldTextPaneOfSideBySideNeverReachesTheServer() async throws {
        try await IntelRig.run(script: script(rename: #"{"result":null}"#)) { r in
            let f = try await fixture(r)
            r.rig.workspace.setPresentation(.sideBySide, of: "main.rs", in: f.view.pane)
            guard case .refused = await f.service.prepare(view: f.view) else { Issue.record("expected refusal"); return }
            #expect(r.count("textDocument/prepareRename") == 0)
        }
    }
}
