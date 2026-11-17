import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

private func json(_ text: String) -> JSONValue { JSONValue.parse(Data(text.utf8))! }

@Suite
@MainActor
struct ExecuteCommandTests {
    private let main = Rig.config("main", ext: "x")

    private func script(after: Bool = false) -> String {
        let afterRequest = after
            ? #","afterRequest":{"workspace/executeCommand":[{"method":"workspace/applyEdit","id":900,"params":{"label":"Do","edit":{"changes":{}}}}]}"#
            : ""
        return #"{"capabilities":{"textDocumentSync":2,"executeCommandProvider":{"commands":["do.it"]}},"replies":{"workspace/executeCommand":[{"result":null}]}\#(afterRequest)}"#
    }

    private func log(_ rig: Rig) -> [JSONValue] {
        guard let text = try? String(contentsOf: rig.dir.appendingPathComponent("main.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
    }

    private func applyAnswers(_ rig: Rig) -> [JSONValue] {
        log(rig).filter { $0["id"]?.intValue == 900 && $0["method"] == nil }
    }

    @Test func sendsCommandWithArguments() async throws {
        try await Rig.run([main], scripts: ["main": script()]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            let outcome = await rig.manager.executeCommand(path: "a.x", serverID: "main",
                                                           command: CodeActionCommand(command: "do.it", arguments: [.string("a"), .number(2)]), snapshot: snapshot)
            guard case .answered = outcome else { Issue.record("\(outcome)"); return }
            let sent = log(rig).first { $0["method"]?.stringValue == "workspace/executeCommand" }
            #expect(sent?["params"]?["command"]?.stringValue == "do.it")
            #expect(sent?["params"]?["arguments"]?.arrayValue == [.string("a"), .number(2)])
        }
    }

    @Test func unlistedCommandIsRefusedWithoutAsking() async throws {
        try await Rig.run([main], scripts: ["main": script()]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            let outcome = await rig.manager.executeCommand(path: "a.x", serverID: "main", command: CodeActionCommand(command: "evil"), snapshot: snapshot)
            guard case .unavailable = outcome else { Issue.record("\(outcome)"); return }
            #expect(!rig.methods("main").contains("workspace/executeCommand"))
        }
    }

    @Test func applyEditIsEmittedAndAnsweredOnce() async throws {
        try await Rig.run([main], scripts: ["main": script(after: true)]) { rig in
            let seen = Collector(rig.manager.results)
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            _ = await rig.manager.executeCommand(path: "a.x", serverID: "main", command: CodeActionCommand(command: "do.it"), snapshot: snapshot)
            func find() -> (String, String, String?, ApplyEditReply)? {
                for r in seen.all { if case .applyEdit(let path, let id, let label, _, let reply) = r { return (path, id, label, reply) } }
                return nil
            }
            #expect(await waitUntil { find() != nil })
            let found = find()
            #expect(found?.0 == "a.x" && found?.1 == "main" && found?.2 == "Do")
            let captured = found?.3
            captured?.answer(applied: true, failureReason: nil)
            captured?.answer(applied: false, failureReason: "second")
            #expect(await waitUntil { applyAnswers(rig).count == 1 })
            try await Task.sleep(for: .milliseconds(100))
            let answers = applyAnswers(rig)
            #expect(answers.count == 1)
            #expect(answers.first?["result"]?["applied"]?.boolValue == true)
        }
    }

    @Test func shutdownAnswersPendingEditNotApplied() async throws {
        let rig = try Rig(configs: [main], scripts: ["main": script(after: true)])
        defer { rig.cleanup() }
        let seen = Collector(rig.manager.results)
        let snapshot = snap("abc\n")
        await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
        _ = await rig.manager.executeCommand(path: "a.x", serverID: "main", command: CodeActionCommand(command: "do.it"), snapshot: snapshot)
        #expect(await waitUntil { seen.all.contains { if case .applyEdit = $0 { true } else { false } } })
        await rig.manager.shutdownAll()
        #expect(await waitUntil { applyAnswers(rig).count == 1 })
        #expect(applyAnswers(rig).first?["result"]?["applied"]?.boolValue == false)
    }

    @Test func droppedReplyAnswersNotApplied() async throws {
        try await Rig.run([main], scripts: ["main": script(after: true)]) { rig in
            // Nobody collects the edit request: the stream's element is dropped without an answer.
            let stream = rig.manager.results
            let drain = Task { for await result in stream { if case .applyEdit = result { continue } } }
            defer { drain.cancel() }
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            _ = await rig.manager.executeCommand(path: "a.x", serverID: "main", command: CodeActionCommand(command: "do.it"), snapshot: snapshot)
            #expect(await waitUntil { applyAnswers(rig).count == 1 })
            #expect(applyAnswers(rig).first?["result"]?["applied"]?.boolValue == false)
        }
    }
}
