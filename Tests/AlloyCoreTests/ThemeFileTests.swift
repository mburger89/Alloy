import AlloyCore
import Foundation
import Testing

@Suite struct ThemeFileTests {
    private func parse(_ json: String) throws(ThemeFileError) -> ThemeFile {
        try ThemeFile.parse(Data(json.utf8))
    }

    @Test func hexParsesSixAndEightDigits() {
        let c = ThemeRGBA(hex: "#282a36")
        #expect(abs((c?.r ?? 0) - 40.0 / 255) < 1e-9)
        #expect(c?.a == 1)
        #expect(abs((ThemeRGBA(hex: "#FF000080")?.a ?? 0) - 128.0 / 255) < 1e-9)
        #expect(ThemeRGBA(hex: "#FFF") == nil)
        #expect(ThemeRGBA(hex: "red") == nil)
        #expect(ThemeRGBA(hex: "282a36") == nil)
        #expect(ThemeRGBA(hex: "#GG0000") == nil)
        #expect(ThemeRGBA(hex: "#abcdef")?.hex == "#ABCDEF")
        #expect(ThemeRGBA(hex: "#FF000080")?.hex == "#FF000080")
    }

    @Test func parseReadsAllFields() throws {
        let file = try parse("""
        {"name":"T","appearance":"dark","base":"dracula","author":"me","source":"MIT, x",
         "colors":{"accent":"#112233"},
         "sessionColors":["#000000","#111111","#222222","#333333","#444444","#555555"]}
        """)
        #expect(file.name == "T")
        #expect(file.appearance == .dark)
        #expect(file.base == "dracula")
        #expect(file.author == "me")
        #expect(file.credit == "MIT, x")
        #expect(file.colors["accent"]?.hex == "#112233")
        #expect(file.sessionColors?.count == 6)
    }

    @Test func parseRejects() {
        #expect(throws: ThemeFileError.missingName) { try parse(#"{"appearance":"dark"}"#) }
        #expect(throws: ThemeFileError.badAppearance("dim")) { try parse(#"{"name":"a","appearance":"dim"}"#) }
        #expect(throws: ThemeFileError.badColor(slot: "accent", value: "blue")) {
            try parse(#"{"name":"a","appearance":"dark","colors":{"accent":"blue"}}"#)
        }
        func session(_ n: Int) -> String {
            let list = Array(repeating: "\"#000000\"", count: n).joined(separator: ",")
            return #"{"name":"a","appearance":"dark","sessionColors":[\#(list)]}"#
        }
        #expect(throws: ThemeFileError.sessionColorCount(5)) { try parse(session(5)) }
        #expect(throws: ThemeFileError.sessionColorCount(13)) { try parse(session(13)) }
        #expect(throws: ThemeFileError.notJSON) { try parse("[]") }
        #expect(throws: ThemeFileError.notJSON) { try parse("{") }
    }

    @Test func unknownSlotsAreKept() throws {
        let file = try parse(##"{"name":"a","appearance":"light","colors":{"notASlot":"#010203"}}"##)
        #expect(file.colors["notASlot"]?.hex == "#010203")
    }

    @Test func messagesAreOneLine() {
        let errors: [ThemeFileError] = [.notJSON, .missingName, .badAppearance("x"),
                                        .badColor(slot: "a", value: "b"), .sessionColorCount(3), .tooLarge(9)]
        for error in errors {
            #expect(!error.message.isEmpty)
            #expect(!error.message.contains("\n"))
        }
    }

    @Test func hexRejectsLookalikes() {
        for bad in ["#+12345", " #112233", "#112233\n", "#１２３４５６"] {
            #expect(ThemeRGBA(hex: bad) == nil, "\(bad.debugDescription)")
        }
    }

    @Test func badFieldsAreErrors() {
        #expect(throws: ThemeFileError.badField("colors")) {
            try parse(##"{"name":"a","appearance":"dark","colors":["#000000"]}"##)
        }
        #expect(throws: ThemeFileError.badField("sessionColors")) {
            try parse(##"{"name":"a","appearance":"dark","sessionColors":"#000000"}"##)
        }
        #expect(ThemeFileError.badField("colors").message.contains("colors"))
    }

    @Test func nonStringColourReadsAsNotAString() {
        do {
            _ = try parse(#"{"name":"a","appearance":"dark","colors":{"accent":12}}"#)
            Issue.record("expected failure")
        } catch {
            #expect(error.message.contains("not a string"))
        }
    }

    @Test func missingAppearanceHasOwnMessage() {
        do {
            _ = try parse(#"{"name":"a"}"#)
            Issue.record("expected failure")
        } catch {
            #expect(error.message == #"missing "appearance" (dark or light)"#)
        }
    }

    @Test func offendingValuesAreTruncatedAndFlattened() throws {
        let long = "x\\ny" + String(repeating: "z", count: 200 * 1024)
        let json = #"{"name":"a","appearance":"dark","colors":{"accent":"\#(long)"}}"#
        do {
            _ = try parse(json)
            Issue.record("expected failure")
        } catch {
            #expect(error.message.count < 200)
            #expect(!error.message.contains("\n"))
        }
        do {
            _ = try parse(#"{"name":"a","appearance":"dim\nx\n"}"#)
            Issue.record("expected failure")
        } catch {
            #expect(!error.message.contains("\n"))
        }
    }
}
