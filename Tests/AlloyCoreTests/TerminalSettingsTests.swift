@testable import AlloyCore
import Foundation
import Testing

@Suite struct TerminalSettingsTests {
    private func decode(_ json: String) throws -> AlloySettings {
        try JSONDecoder().decode(AlloySettings.self, from: Data(json.utf8))
    }

    @Test func emptyFileGivesSpecDefaults() throws {
        let s = try decode("{}")
        #expect(s.terminal == TerminalSettings())
        let t = s.terminal
        #expect(t.shellPath == nil && t.fontSize == nil)
        #expect(t.scrollbackLines == 10_000)
        #expect(t.optionAsMeta && t.cursorBlink && t.confirmMultilinePaste)
        #expect(t.cursorStyle == .block)
    }

    @Test func oldSettingsFileStillLoads() throws {
        let s = try decode(#"{"followEdits": false, "theme": "alloy-light", "shareKnowledge": false}"#)
        #expect(!s.followEdits && !s.shareKnowledge && s.theme == "alloy-light")
        #expect(s.terminal == TerminalSettings())
    }

    @Test func malformedTerminalKeyFallsBackWithoutLosingOthers() throws {
        let s = try decode(#"{"terminal": 3, "followEdits": false}"#)
        #expect(!s.followEdits)
        #expect(s.terminal == TerminalSettings())
        let partial = try decode(#"{"terminal": {"scrollbackLines": "many", "cursorStyle": "wobbly", "cursorBlink": false}}"#)
        #expect(partial.terminal.scrollbackLines == 10_000)
        #expect(partial.terminal.cursorStyle == .block)
        #expect(!partial.terminal.cursorBlink)
    }

    @Test func outOfRangeValuesClamp() throws {
        let low = try decode(#"{"terminal": {"scrollbackLines": 5, "fontSize": 1}}"#).terminal
        #expect(low.scrollbackLines == 100 && low.fontSize == 6)
        let high = try decode(#"{"terminal": {"scrollbackLines": 99999999, "fontSize": 500}}"#).terminal
        #expect(high.scrollbackLines == 1_000_000 && high.fontSize == 72)
        #expect(TerminalSettings(scrollbackLines: -1).scrollbackLines == 100)
    }

    @Test func blankShellIsNil() throws {
        #expect(try decode(#"{"terminal": {"shellPath": "   "}}"#).terminal.shellPath == nil)
        #expect(try decode(#"{"terminal": {"shellPath": " /bin/fish "}}"#).terminal.shellPath == "/bin/fish")
        #expect(TerminalSettings(shellPath: "").shellPath == nil)
    }

    @Test func roundTrip() throws {
        let t = TerminalSettings(shellPath: "/bin/zsh", fontSize: 13, scrollbackLines: 500, optionAsMeta: false,
                                 cursorStyle: .bar, cursorBlink: false, confirmMultilinePaste: false)
        let data = try JSONEncoder().encode(AlloySettings(terminal: t))
        #expect(try JSONDecoder().decode(AlloySettings.self, from: data).terminal == t)
    }
}
