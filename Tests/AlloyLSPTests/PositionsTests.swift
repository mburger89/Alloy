import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

@MainActor
struct PositionsTests {
    private func snapshot(_ text: String) -> CodeSnapshot { CodeBuffer(text).snapshot() }

    @Test func utf16RangesRoundTripNonASCII() {
        // a (1 byte) + emoji (4 bytes, 2 UTF-16 units) + e + combining acute (1 + 2 bytes, 2 units) + b
        let s = snapshot("a😀e\u{301}b")
        let bOffset = 8
        #expect(s.utf8Count == 9)
        let u16 = Positions.lspPosition(utf8Offset: bOffset, in: s, encoding: .utf16)
        #expect(u16 == LSPPosition(line: 0, character: 5))
        #expect(Positions.lspPosition(utf8Offset: bOffset, in: s, encoding: .utf8) == LSPPosition(line: 0, character: 8))
        #expect(Positions.lspPosition(utf8Offset: bOffset, in: s, encoding: .utf32) == LSPPosition(line: 0, character: 4))
        for encoding in [PositionEncoding.utf8, .utf16, .utf32] {
            let p = Positions.lspPosition(utf8Offset: bOffset, in: s, encoding: encoding)
            #expect(Positions.utf8Offset(of: p, in: s, encoding: encoding) == bOffset)
        }
        let range = LSPRange(start: LSPPosition(line: 0, character: 1), end: LSPPosition(line: 0, character: 3))
        #expect(Positions.utf8Range(of: range, in: s, encoding: .utf16) == 1..<5)
    }

    @Test func clampsPastLineEnd() {
        let s = snapshot("ab\ncde")
        #expect(Positions.utf8Offset(of: LSPPosition(line: 0, character: 99), in: s, encoding: .utf16) == 2)
        #expect(Positions.utf8Offset(of: LSPPosition(line: 1, character: 99), in: s, encoding: .utf8) == 6)
        #expect(Positions.utf8Offset(of: LSPPosition(line: 9, character: 0), in: s, encoding: .utf16) == 6)
        #expect(Positions.utf8Offset(of: LSPPosition(line: 0, character: -3), in: s, encoding: .utf16) == 0)
        #expect(Positions.lspPosition(utf8Offset: 999, in: s, encoding: .utf16) == LSPPosition(line: 1, character: 3))
    }

    @Test func crlfLineEndExcludesCR() {
        let s = snapshot("ab\r\ncd")
        #expect(Positions.utf8Offset(of: LSPPosition(line: 0, character: 5), in: s, encoding: .utf16) == 2)
        #expect(Positions.utf8Offset(of: LSPPosition(line: 1, character: 0), in: s, encoding: .utf16) == 4)
        // Offset 3 sits between the CR and the LF; it reports the end of the line's content.
        #expect(Positions.lspPosition(utf8Offset: 3, in: s, encoding: .utf16) == LSPPosition(line: 0, character: 2))
        #expect(Positions.lspPosition(utf8Offset: 4, in: s, encoding: .utf16) == LSPPosition(line: 1, character: 0))
    }
}
