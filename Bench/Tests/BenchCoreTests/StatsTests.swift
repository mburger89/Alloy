import Testing
@testable import BenchCore

@Suite struct StatsTests {
    @Test func medianOddEven() {
        #expect(Stats.summarize([3, 1, 2], unit: "ms")?.median == 2)
        #expect(Stats.summarize([1, 2, 3, 4], unit: "ms")?.median == 2.5)
    }
    @Test func p95NearestRank() {
        let s = Stats.summarize((1...100).map(Double.init), unit: "ms")
        #expect(s?.p95 == 95)
        #expect(s?.min == 1); #expect(s?.max == 100); #expect(s?.count == 100)
    }
    @Test func emptyIsNil() {
        #expect(Stats.summarize([], unit: "ms") == nil)
    }
}
