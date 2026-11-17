@testable import AlloyCore
import Foundation
import Testing

@Suite struct GitBlameParserTests {
    private let a = String(repeating: "a", count: 40)
    private let b = String(repeating: "b", count: 40)
    private let z = String(repeating: "0", count: 40)

    @Test func mergesConsecutiveLinesAndReusesHeaders() {
        let text = """
        \(a) 1 1 2
        author Jane Doe
        author-mail <j@x>
        author-time 1700000000
        summary First
        filename f
        \tone
        \(a) 2 2
        \ttwo
        \(b) 1 3 1
        author madonna
        author-time 1700000100
        summary Second
        filename f
        \tthree
        \(a) 3 4 1
        \tfour
        \(z) 5 5 1
        author Not Committed Yet
        author-time 1700000200
        summary Version of f from f
        filename f
        \tfive

        """
        let runs = GitBlameParser.parse(Data(text.utf8))
        #expect(runs.map(\.startLine) == [0, 2, 3, 4])
        #expect(runs.map(\.count) == [2, 1, 1, 1])
        #expect(runs[0].author == "Jane Doe" && runs[0].summary == "First" && runs[0].shortHash == "aaaaaaa")
        #expect(runs[0].authorTime == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(runs[2].author == "Jane Doe" && runs[2].hash == a)
        #expect(runs[4 - 1].isUncommitted && !runs[0].isUncommitted)
    }

    @Test func initials() {
        func run(_ n: String) -> GitBlameRun { GitBlameRun(startLine: 0, count: 1, hash: "a", author: n, authorTime: .now, summary: "") }
        #expect(run("Jane Doe").initials == "JD")
        #expect(run("madonna").initials == "MA")
        #expect(run("").initials == "??")
    }
}
