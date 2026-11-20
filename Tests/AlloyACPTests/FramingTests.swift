import Foundation
import Testing
@testable import AlloyACP

@Suite struct FramingTests {
    @Test func lineReaderHandlesSplitChunksAndMultiMegabyteLine() {
        let big = String(repeating: "x", count: 4 * 1024 * 1024)
        let payload = Data((big + "\n").utf8)
        var reader = ACPLineReader()
        var lines: [Data] = []
        var offset = 0
        while offset < payload.count {
            let end = min(offset + 64 * 1024, payload.count)
            lines += reader.feed(payload.subdata(in: offset..<end))
            offset = end
        }
        #expect(lines.count == 1)
        #expect(lines.first?.count == big.utf8.count)
    }

    @Test func lineReaderSplitsBatchesDropsBlankLinesAndTrimsCR() {
        var reader = ACPLineReader()
        let out = reader.feed(Data("a\r\n\n\nb\nc".utf8))
        #expect(out == [Data("a".utf8), Data("b".utf8)])
        #expect(reader.feed(Data("d\n".utf8)) == [Data("cd".utf8)])
        #expect(reader.finish() == nil)
    }

    @Test func lineReaderFinishReturnsUnterminatedTail() {
        var reader = ACPLineReader()
        #expect(reader.feed(Data("{\"a\":1}".utf8)).isEmpty)
        #expect(reader.finish() == Data("{\"a\":1}".utf8))
    }

    @Test func encodeAppendsNewline() {
        #expect(ACPFraming.encode(Data("{}".utf8)) == Data("{}\n".utf8))
    }
}
