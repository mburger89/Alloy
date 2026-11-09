@testable import AlloyCore
import Foundation
import Testing

@MainActor
@Suite struct SessionCostTests {
    private func session() -> Session {
        Session(id: UUID(), name: "S", colorIndex: 0, projectRoot: URL(fileURLWithPath: "/tmp"))
    }

    @Test func compactFixtureTotalIsTheLastResultsCost() throws {
        let s = session()
        var last = 0.0
        for line in Fixture.lines("compact") {
            let m = InboundDecoder.decode(line)
            if case .result(let r) = m { last = r.costUSD }
            s.handle(.message(m))
        }
        #expect(last > 0.002)
        #expect(s.costUSD == last)
    }

    @Test func aNewProcessAddsTheEarlierTotalAsItsBase() {
        let s = session()
        func result(_ c: Double) -> ProcessEvent {
            .message(.result(TurnResult(subtype: "success", isError: false, costUSD: c, inputTokens: 1, outputTokens: 1,
                                        sessionID: "x", terminalReason: nil)))
        }
        s.handle(result(0.2)); s.handle(result(0.3))
        #expect(s.costUSD == 0.3)
        s.beginProcess()
        s.handle(result(0.1))
        #expect(s.costUSD == 0.4)
        #expect(s.inputTokens == 3)
        #expect(s.totalTokens == 6)
    }
}
