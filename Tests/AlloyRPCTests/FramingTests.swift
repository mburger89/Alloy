@testable import AlloyRPC
import Foundation
import Testing

@Suite struct FramingTests {
    @Test func decodesSplitAndBatchedFrames() throws {
        let a = Data(#"{"a":1}"#.utf8), b = Data(#"{"b":"two"}"#.utf8)
        let stream = RPCFrame.encode(a) + RPCFrame.encode(b)
        let cuts = [7, stream.count / 2 + 1]
        var decoder = RPCFrameDecoder()
        var out: [Data] = []
        var start = 0
        for end in cuts + [stream.count] {
            out += try decoder.append(stream.subdata(in: start..<end))
            start = end
        }
        #expect(out == [a, b])
    }

    @Test func toleratesContentTypeAndHeaderOrder() throws {
        let body = Data("{}".utf8)
        let raw = Data("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: 2\r\n\r\n".utf8) + body
        var decoder = RPCFrameDecoder()
        #expect(try decoder.append(raw) == [body])
    }

    @Test func rejectsMissingContentLength() {
        var decoder = RPCFrameDecoder()
        #expect(throws: RPCFramingError.badHeader) {
            _ = try decoder.append(Data("Content-Type: x\r\n\r\n{}".utf8))
        }
    }

    @Test func encodeRoundTrips() throws {
        let body = Data(#"{"s":"é"}"#.utf8)
        let framed = RPCFrame.encode(body)
        #expect(String(decoding: framed, as: UTF8.self).hasPrefix("Content-Length: \(body.count)\r\n\r\n"))
        #expect(body.count == 10)
        var decoder = RPCFrameDecoder()
        #expect(try decoder.append(framed) == [body])
    }

    @Test func rejectsOversizedHeader() {
        var decoder = RPCFrameDecoder()
        #expect(throws: RPCFramingError.headerTooLarge) {
            _ = try decoder.append(Data(repeating: UInt8(ascii: "a"), count: RPCFrameDecoder.maxHeaderBytes + 1))
        }
    }

    @Test func rejectsOversizedBody() {
        var decoder = RPCFrameDecoder()
        let header = "Content-Length: \(RPCFrameDecoder.maxBodyBytes + 1)\r\n\r\n"
        #expect(throws: RPCFramingError.bodyTooLarge) { _ = try decoder.append(Data(header.utf8)) }
    }
}
