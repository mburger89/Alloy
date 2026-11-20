import AlloyCore
import Foundation
import Testing
@testable import AlloyACP

@Suite struct ConnectionTests {
    struct Ping: Encodable { var n: Int }

    @Test func requestResponseCorrelationOutOfOrder() async throws {
        let l = Loopback()
        async let a: JSONValue = l.connection.request("a", Ping(n: 1))
        async let b: JSONValue = l.connection.request("b", Ping(n: 2))
        #expect(await waitUntil { l.sentObjects.count == 2 })
        let ids = l.sentObjects.reduce(into: [String: Int]()) { acc, o in
            if let m = o["method"]?.stringValue, let id = o["id"]?.intValue { acc[m] = id }
        }
        l.send(#"{"jsonrpc":"2.0","id":\#(ids["b"]!),"result":{"who":"b"}}"#)
        l.send(#"{"jsonrpc":"2.0","id":\#(ids["a"]!),"result":{"who":"a"}}"#)
        let (ra, rb) = try await (a, b)
        #expect(ra["who"]?.stringValue == "a")
        #expect(rb["who"]?.stringValue == "b")
    }

    @Test func errorResponseThrowsACPErrorWithAuthRequiredFlag() async {
        let l = Loopback()
        async let r: JSONValue = l.connection.request("session/new", Ping(n: 0))
        #expect(await waitUntil { !l.sentObjects.isEmpty })
        let id = l.sentObjects[0]["id"]!.intValue!
        l.send(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"Authentication required"}}"#)
        do {
            _ = try await r
            Issue.record("expected a throw")
        } catch let e as ACPError {
            #expect(e.isAuthRequired)
            #expect(e.message == "Authentication required")
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func strayNonJSONLineIsSkippedAndReported() async {
        let l = Loopback()
        l.send("Loading agent...")
        l.send(#"{"jsonrpc":"2.0","method":"session/update","params":{"x":1}}"#)
        var it = l.connection.incoming.makeAsyncIterator()
        let first = await it.next()
        #expect(first == .notification(method: "session/update", params: .object(["x": .number(1)])))
        #expect(l.strays.get() == ["Loading agent..."])
    }

    @Test func agentRequestSurfacesAsIncomingAndRespondSendsResult() async {
        let l = Loopback()
        // Numeric id 0 is valid (Codex starts at 0).
        l.send(#"{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"a":"b"}}"#)
        var it = l.connection.incoming.makeAsyncIterator()
        guard case .request(let id, let method, _)? = await it.next() else { Issue.record("no request"); return }
        #expect(id == .number(0))
        #expect(method == "session/request_permission")
        await l.connection.respond(id: id, result: ACPPermissionOutcome.selected(optionId: "allow").json)
        #expect(await waitUntil { !l.sentObjects.isEmpty })
        let reply = l.sentObjects[0]
        #expect(reply["id"] == .number(0))
        #expect(reply["result"]?["outcome"]?["optionId"]?.stringValue == "allow")
        await l.connection.respondError(id: .string("x"), code: -32601, message: "no")
        #expect(await waitUntil { l.sentObjects.count == 2 })
        #expect(l.sentObjects[1]["error"]?["code"]?.intValue == -32601)
    }

    @Test func cancelRequestSendsDollarCancelRequest() async {
        let l = Loopback()
        await l.connection.cancel(requestID: 7)
        #expect(await waitUntil { !l.sentObjects.isEmpty })
        #expect(l.sentObjects[0]["method"]?.stringValue == "$/cancel_request")
        #expect(l.sentObjects[0]["params"]?["requestId"]?.intValue == 7)
        #expect(l.sentObjects[0]["id"] == nil)
    }

    @Test func onIDReportsRequestIDBeforeSend() async throws {
        let l = Loopback()
        let seen = Box<Int?>(nil)
        async let r: JSONValue = l.connection.request("x", Ping(n: 0), onID: { seen.set($0) })
        #expect(await waitUntil { !l.sentObjects.isEmpty })
        let id = l.sentObjects[0]["id"]!.intValue!
        #expect(seen.get() == id)
        l.send(#"{"jsonrpc":"2.0","id":\#(id),"result":null}"#)
        _ = try await r
    }

    @Test func endOfInputFailsPendingRequestsAndFinishesIncoming() async {
        let l = Loopback()
        async let r: JSONValue = l.connection.request("x", Ping(n: 0))
        #expect(await waitUntil { !l.sentObjects.isEmpty })
        l.feed.finish()
        do { _ = try await r; Issue.record("expected a throw") } catch { #expect(error as? ACPError == .connectionClosed) }
        var it = l.connection.incoming.makeAsyncIterator()
        #expect(await it.next() == nil)
        // A request after close fails immediately instead of hanging.
        do { _ = try await l.connection.request("y", Ping(n: 0), as: JSONValue.self); Issue.record("expected a throw") }
        catch { #expect(error as? ACPError == .connectionClosed) }
    }

    @Test func multiMegabyteResponseLineDecodes() async throws {
        let l = Loopback()
        async let r: JSONValue = l.connection.request("x", Ping(n: 0))
        #expect(await waitUntil { !l.sentObjects.isEmpty })
        let id = l.sentObjects[0]["id"]!.intValue!
        let pad = String(repeating: "y", count: 4 * 1024 * 1024)
        let line = #"{"jsonrpc":"2.0","id":\#(id),"result":{"pad":"\#(pad)"}}"#
        var data = Data((line + "\n").utf8)
        while !data.isEmpty {
            l.feed.yield(data.prefix(64 * 1024)); data = data.dropFirst(64 * 1024)
        }
        let v = try await r
        #expect(v["pad"]?.stringValue?.count == pad.count)
    }
}
