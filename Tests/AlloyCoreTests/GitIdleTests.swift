@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

@Suite struct GitIdleTests {
    @Test func idleServiceSpawnsNothing() async throws {
        let root = try makeRepo(files: ["a.txt": "one\n"]); defer { try? FileManager.default.removeItem(at: root) }
        let clock = ManualClock()
        let service = GitService(root: root, clock: clock)
        let updates = await collectUpdates(service)
        await service.refreshNow()
        let spawned = service.spawnCount, seen = updates.all.count
        for _ in 0..<50 { clock.advance(by: 1); await Task.yield() }
        for _ in 0..<1000 { await Task.yield() }
        #expect(service.spawnCount == spawned)
        #expect(updates.all.count == seen)
        #expect(clock.pendingSleepers == 0)
    }
}
