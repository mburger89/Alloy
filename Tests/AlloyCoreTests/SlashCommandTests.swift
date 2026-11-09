import Testing
import Foundation
@testable import AlloyCore
import AlloyTestSupport

@Suite struct SlashRouteTests {
    @Test func routingTable() {
        let table: [(String, SlashRoute)] = [
            ("/model sonnet", .setModel("sonnet")),
            ("  /model   opus  ", .setModel("opus")),
            ("/model", .showModelPicker),
            ("/model   ", .showModelPicker),
            ("/plan", .setMode(.plan)),
            ("/plan add tests", .passThrough),
            ("/help", .localHelp),
            ("/help me", .localHelp),
            ("/compact", .passThrough),
            ("/compact keep the API", .passThrough),
            ("/clear", .passThrough),
            ("/cost", .passThrough),
            ("/context", .passThrough),
            ("/simplify", .passThrough),
            ("/bogus-cmd", .passThrough),
            ("/modelx", .passThrough),
            ("/planning", .passThrough),
            ("hello /model", .passThrough),
            ("what does /help do", .passThrough),
            ("", .passThrough),
            ("/", .passThrough),
        ]
        for (text, expected) in table { #expect(SlashCommands.route(text) == expected, "\(text)") }
    }

    @Test func helpTextListsNameAndDescription() {
        let text = SlashCommands.helpText([
            SlashCommandInfo(name: "compact", description: "Compact the conversation", argumentHint: "[focus]"),
            SlashCommandInfo(name: "cost", description: "", argumentHint: nil),
        ])
        #expect(text == "/compact [focus] — Compact the conversation\n/cost")
    }
}
