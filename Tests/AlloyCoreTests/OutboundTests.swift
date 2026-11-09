import AlloyCore
import Foundation
import Testing

private func decode(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
}

private func json(_ s: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
}

@Suite struct OutboundTests {
    let u = UUID(uuidString: "A1B2C3D4-0000-4000-8000-ABCDEF012345")!

    @Test func userLineShape() throws {
        let data = OutboundMessage.user(text: "hi", uuid: u, priority: .next).line()
        #expect(data.last == UInt8(ascii: "\n"))
        #expect(try decode(data) == json(#"{"type":"user","message":{"role":"user","content":"hi"},"parent_tool_use_id":null,"uuid":"a1b2c3d4-0000-4000-8000-abcdef012345","priority":"next"}"#))
        let none = OutboundMessage.user(text: "hi", uuid: u, priority: nil).line()
        #expect(try decode(none)["priority"] == nil)
        #expect(String(decoding: none, as: UTF8.self).filter { $0 == "\n" }.count == 1)
    }

    @Test func allowAndDenyShapes() throws {
        let allow = OutboundMessage.allow(requestID: "r1", updatedInput: .object(["a": .number(1)]), updatedPermissions: nil).line()
        #expect(try decode(allow) == json(#"{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"behavior":"allow","updatedInput":{"a":1}}}}"#))
        let deny = OutboundMessage.deny(requestID: "r1", message: "no").line()
        #expect(try decode(deny) == json(#"{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"behavior":"deny","message":"no"}}}"#))
    }

    @Test func controlErrorShape() throws {
        let line = OutboundMessage.controlError(requestID: "r9", message: "Unsupported by Alloy").line()
        #expect(try decode(line) == json(#"{"type":"control_response","response":{"subtype":"error","request_id":"r9","error":"Unsupported by Alloy"}}"#))
    }

    @Test func controlShapes() throws {
        #expect(try decode(OutboundMessage.control(requestID: "r2", .interrupt).line()) == json(#"{"type":"control_request","request_id":"r2","request":{"subtype":"interrupt"}}"#))
        #expect(try decode(OutboundMessage.control(requestID: "r2", .setModel("sonnet")).line()) == json(#"{"type":"control_request","request_id":"r2","request":{"subtype":"set_model","model":"sonnet"}}"#))
        #expect(try decode(OutboundMessage.control(requestID: "r2", .setPermissionMode("plan")).line()) == json(#"{"type":"control_request","request_id":"r2","request":{"subtype":"set_permission_mode","mode":"plan"}}"#))
    }

    private func config(resume: Bool = false, settings: String? = nil, mcp: String? = nil) -> LaunchConfiguration {
        LaunchConfiguration(executable: URL(fileURLWithPath: "/x/claude"), projectDirectory: URL(fileURLWithPath: "/p"),
                            sessionID: u, resume: resume, extraSettingsJSON: settings, mcpConfigJSON: mcp)
    }

    static let base = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio",
                       "--thinking-display", "summarized"]

    @Test func launchArgumentsNewSession() {
        let id = "a1b2c3d4-0000-4000-8000-abcdef012345"
        let args = config().arguments()
        #expect(args == Self.base + ["--session-id", id])
        for bad in ["--bare", "--permission-mode", "--setting-sources"] { #expect(!args.contains(bad)) }
        #expect(config(settings: "{}", mcp: "{\"m\":1}").arguments() == Self.base + ["--session-id", id, "--settings", "{}", "--mcp-config", "{\"m\":1}"])
    }

    @Test func launchArgumentsResume() {
        #expect(config(resume: true).arguments() == Self.base + ["--resume", "a1b2c3d4-0000-4000-8000-abcdef012345"])
    }

    @Test func userWithImageEncodesContentArray() throws {
        let line = OutboundMessage.user(content: [.image(mediaType: "image/png", base64: "QUJD"), .text("hi")],
                                        uuid: u, priority: nil).line()
        let expected = #"{"message":{"content":[{"source":{"data":"QUJD","media_type":"image/png","type":"base64"},"type":"image"},{"text":"hi","type":"text"}],"role":"user"},"parent_tool_use_id":null,"type":"user","uuid":"a1b2c3d4-0000-4000-8000-abcdef012345"}"# + "\n"
        #expect(String(decoding: line, as: UTF8.self) == expected)
    }

    @Test func textOnlyUserStaysString() {
        let line = OutboundMessage.user(content: [.text("hi")], uuid: u, priority: nil).line()
        let legacy = OutboundMessage.user(text: "hi", uuid: u, priority: nil).line()
        #expect(line == legacy)
        #expect(String(decoding: line, as: UTF8.self) == #"{"message":{"content":"hi","role":"user"},"parent_tool_use_id":null,"type":"user","uuid":"a1b2c3d4-0000-4000-8000-abcdef012345"}"# + "\n")
    }

    @Test func allowWithPermissions() throws {
        let perms: [JSONValue] = [.object(["type": .string("setMode"), "mode": .string("default"), "destination": .string("session")])]
        let line = OutboundMessage.allow(requestID: "r1", updatedInput: .object(["a": .number(1)]), updatedPermissions: perms).line()
        #expect(try decode(line) == json(#"{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"behavior":"allow","updatedInput":{"a":1},"updatedPermissions":[{"type":"setMode","mode":"default","destination":"session"}]}}}"#))
        let none = OutboundMessage.allow(requestID: "r1", updatedInput: .null, updatedPermissions: nil).line()
        #expect(try decode(none)["response"]?["response"]?["updatedPermissions"] == nil)
    }

    @Test func initializeEncodes() throws {
        #expect(try decode(OutboundMessage.control(requestID: "i1", .initialize).line()) == json(#"{"type":"control_request","request_id":"i1","request":{"subtype":"initialize"}}"#))
    }
}
