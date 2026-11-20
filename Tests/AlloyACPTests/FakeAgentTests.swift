import AlloyCore
import Foundation
import Testing
@testable import AlloyACP

@Suite struct FakeAgentTests {
    private func connect(_ p: ACPProcess, strays: Box<[String]>? = nil) -> ACPConnection {
        ACPConnection(input: p.stdout, output: { data in try? await p.send(data) },
                      onStray: { line in strays?.update { $0.append(line) } })
    }

    private func steps(_ lines: String...) -> [String] { lines }

    private let initReply = #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"authMethods":[]}}}"#

    @Test func handshakeAndPromptStreams() async throws {
        let s = Scratch()
        let p = try s.launch(steps(
            #"{"expect":"initialize"}"#, initReply,
            #"{"expect":"session/new"}"#,
            #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"sessionId":"sess-1"}}}"#,
            #"{"expect":"session/prompt"}"#,
            #"{"send":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hel"}}}}}"#,
            #"{"send":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"lo"}}}}}"#,
            #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"stopReason":"end_turn"}}}"#,
            #"{"sleep":200}"#
        ))
        let c = connect(p)
        let texts = Box<[String]>([])
        let drain = Task {
            for await item in c.incoming {
                if case .notification("session/update", let params) = item,
                   let n = try? params.decode(ACPSessionNotification.self),
                   case .agentMessageChunk(let m) = n.update, let t = m.content.textValue {
                    texts.update { $0.append(t) }
                }
            }
        }
        let initResult = try await c.request("initialize", ACPInitializeParams(clientInfo: .init(name: "alloy", version: "1")),
                                             as: ACPInitializeResult.self)
        #expect(initResult.agentCapabilities?.canLoad == true)
        let session = try await c.request("session/new", ACPSessionNewParams(cwd: s.url.path), as: ACPSessionNewResult.self)
        #expect(session.sessionId == "sess-1")
        let done = try await c.request("session/prompt", ACPPromptParams(sessionId: "sess-1", prompt: [.text("hi")]),
                                       as: ACPPromptResult.self)
        #expect(done.stopReason == "end_turn")
        #expect(await waitUntil { texts.get() == ["Hel", "lo"] })
        drain.cancel()
        await p.stopAndWait()
    }

    @Test func permissionRequestRoundTrip() async throws {
        let s = Scratch()
        let log = s.url.appendingPathComponent("log.txt").path
        let p = try s.launch(steps(
            #"{"expect":"initialize"}"#, initReply,
            #"{"send":{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"t","title":"Edit","kind":"edit"},"options":[{"optionId":"ok","name":"Yes","kind":"allow_once"}]}}}"#,
            #"{"expectResponse":0}"#
        ), extraEnv: ["FAKE_ACP_LOG": log])
        let c = connect(p)
        let seenOptions = Box<[String]>([])
        let drain = Task {
            for await item in c.incoming {
                if case .request(let id, "session/request_permission", let params) = item,
                   let req = try? params.decode(ACPPermissionRequest.self) {
                    seenOptions.set(req.options.map(\.optionId))
                    await c.respond(id: id, result: ACPPermissionOutcome.selected(optionId: "ok").json)
                }
            }
        }
        _ = try await c.request("initialize", ACPInitializeParams(clientInfo: .init(name: "alloy", version: "1")), as: ACPInitializeResult.self)
        #expect(await waitUntil { seenOptions.get() == ["ok"] })
        var exited = false
        for await _ in p.exited { exited = true }
        #expect(exited)
        #expect(await waitUntil { (try? String(contentsOfFile: log, encoding: .utf8))?.contains(#""optionId":"ok""#) == true })
        drain.cancel()
    }

    @Test func agentCrashEndsStreamWithStderrTail() async throws {
        let s = Scratch()
        let p = try s.launch(steps(
            #"{"expect":"initialize"}"#,
            #"{"stderr":"boom: something broke"}"#,
            #"{"exit":3}"#
        ))
        let c = connect(p)
        do {
            _ = try await c.request("initialize", ACPInitializeParams(clientInfo: .init(name: "alloy", version: "1")),
                                    as: ACPInitializeResult.self)
            Issue.record("expected the request to fail")
        } catch { #expect(error as? ACPError == .connectionClosed) }
        var code: Int32?
        for await c in p.exited { code = c }
        #expect(code == 3)
        #expect(p.stderrTail.contains("boom: something broke"))
        var it = c.incoming.makeAsyncIterator()
        #expect(await it.next() == nil)
    }

    @Test func stdoutClosedMidTurnFailsThePromptWithoutHanging() async throws {
        let s = Scratch()
        let p = try s.launch(steps(
            #"{"expect":"session/prompt"}"#,
            #"{"send":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"par"}}}}}"#,
            #"{"closeStdout":true}"#,
            #"{"sleep":300}"#
        ))
        let c = connect(p)
        do {
            _ = try await c.request("session/prompt", ACPPromptParams(sessionId: "s", prompt: [.text("x")]), as: ACPPromptResult.self)
            Issue.record("expected failure")
        } catch { #expect(error as? ACPError == .connectionClosed) }
        await p.stopAndWait()
        #expect(!p.isRunning)
    }

    @Test func strayLinesAndFourMegabyteLineAreHandled() async throws {
        let s = Scratch()
        let p = try s.launch(steps(
            #"{"expect":"initialize"}"#,
            #"{"stray":"Starting up, please wait"}"#,
            #"{"bigline":4194304}"#,
            initReply
        ))
        let strays = Box<[String]>([])
        let c = connect(p, strays: strays)
        let big = Box(0)
        let drain = Task {
            for await item in c.incoming {
                if case .notification(_, let params) = item { big.set(params["pad"]?.stringValue?.count ?? 0) }
            }
        }
        let r = try await c.request("initialize", ACPInitializeParams(clientInfo: .init(name: "alloy", version: "1")),
                                    as: ACPInitializeResult.self)
        #expect(r.protocolVersion == 1)
        #expect(strays.get() == ["Starting up, please wait"])
        #expect(await waitUntil { big.get() == 4_194_304 })
        drain.cancel()
        await p.stopAndWait()
    }

    @Test func stopAndWaitKillsAgentThatIgnoresSigint() async throws {
        let s = Scratch()
        let p = try s.launch(steps(#"{"ignoreSignals":true}"#, #"{"hang":true}"#))
        let pid = p.processIdentifier
        // The script runs a moment after launch; give it time to install the signal handlers.
        try await Task.sleep(for: .milliseconds(400))
        let started = ContinuousClock.now
        await p.stopAndWait(timeout: .seconds(3))
        let took = ContinuousClock.now - started
        #expect(took < .milliseconds(3500))
        #expect(!p.isRunning)
        #expect(kill(pid, 0) == -1)
    }

    @Test func missingCommandThrowsNotInstalled() {
        let s = Scratch()
        #expect(throws: ACPProcessError.notInstalled(command: "definitely-not-a-real-agent-xyz")) {
            _ = try ACPProcess(command: "definitely-not-a-real-agent-xyz", arguments: [], currentDirectory: s.url)
        }
    }

    @Test func loginPATHIsMergedForCommandLookup() throws {
        let s = Scratch()
        let bin = s.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: fakeAgentPath, toPath: bin.appendingPathComponent("my-agent").path)
        var env = ["FAKE_ACP_SCRIPT": s.script([])]
        env["X"] = "1"
        let p = try ACPProcess(command: "my-agent", arguments: [], environment: env, currentDirectory: s.url, loginPATH: bin.path)
        #expect(p.processIdentifier > 0)
    }
}
