@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

/// Fix round 1 for Task 4: shell activity windows, live and permission-aware sessions, cheap bulk handling.
@MainActor @Suite struct OutsideEditFixTests {
    private func seed(_ e: Env, _ name: String = "a.txt", text: String = "one\ntwo\nthree\n") async throws {
        e.write(name, text)
        await e.ws.open(name)
        let doc = try #require(e.ws.document(name))
        _ = doc.buffer.replace(0..<0, with: "x")
        try await e.ws.save(name)
        await e.ws.close(name)
    }
    private func authors(_ e: Env, _ name: String = "a.txt") -> [Author] { e.ws.ledger.files[name]?.edits.map(\.author) ?? [] }

    // MARK: C1 shell activity windows

    @Test func bashResultBeforeTheFlushIsStillAttributed() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let s = await e.startBash()
        e.write("a.txt", "xone\ntwo\nthree\nfour\n")
        await e.queue(["a.txt"])               // the event is in; the 150 ms window is still open
        await e.finishBash(s)                  // sed -i has already finished by the time the batch is looked at
        e.clock.advance(by: 0.15)
        await e.ws.settle()
        #expect(authors(e) == [.user, .session(s.id)])
    }

    @Test func overlappingWindowsGiveOutside() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let a = await e.startBash(session: "A", id: "b1")
        let b = await e.startBash(session: "B", id: "b2")
        await e.finishBash(a, id: "b1"); await e.finishBash(b, id: "b2")
        e.write("a.txt", "different\n")
        await e.fire(["a.txt"])
        #expect(authors(e) == [.user, .outside])
    }

    @Test func changeAfterTheGraceIsOutside() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let s = await e.startBash()
        await e.finishBash(s)
        e.clock.advance(by: 2.0)               // well past the 1 s grace
        e.write("a.txt", "later\n")
        await e.fire(["a.txt"])
        #expect(authors(e) == [.user, .outside])
    }

    @Test func changeInsideTheGraceIsAttributed() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let s = await e.startBash()
        await e.finishBash(s)
        e.clock.advance(by: 0.5)
        e.write("a.txt", "inside grace\n")
        await e.fire(["a.txt"])                // flushed at about 0.65 s, inside the 1 s grace
        #expect(authors(e) == [.user, .session(s.id)])
    }

    @Test func oldWindowsArePruned() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let s = await e.startBash()
        await e.finishBash(s)
        #expect(e.ws.shellWindowCount == 1)
        e.clock.advance(by: 61)
        e.write("a.txt", "x\n")
        await e.fire(["a.txt"])
        #expect(e.ws.shellWindowCount == 0)
    }

    @Test func saveLoopAttributesByWindowAfterTheResult() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\ntwo\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "x")
        let s = await e.startBash()
        e.write("a.txt", "one\ntwo\nthree\n")
        await e.finishBash(s)
        try await e.ws.save("a.txt")
        #expect(authors(e).contains(.session(s.id)))
        #expect(!authors(e).contains(.outside))
    }

    // MARK: I2 live, permission-aware sessions

    @Test func shellAwaitingPermissionIsNotAttributed() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let s = await e.startBash()
        await e.transport(of: s).emit(.controlRequest(ControlRequest(requestID: "r1", kind: .canUseTool(
            toolName: "Bash", input: .object([:]), description: nil, toolUseID: "bash1", suggestions: []))))
        await waitUntil("permission pending") { s.hasPendingPermission }
        e.write("a.txt", "an editor wrote this\n")
        await e.fire(["a.txt"])
        #expect(authors(e) == [.user, .outside])
    }

    @Test func exitedSessionNeverCountsAndItsToolsAreInterrupted() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let s = await e.startBash()
        await e.transport(of: s).exit(status: 1, stderr: "")
        await waitUntil("exited") { if case .exited = s.status { return true } else { return false } }
        let block = s.transcript.blocks.compactMap { b -> ToolBlock? in if case .tool(let t) = b { return t } else { return nil } }.first
        #expect(block?.status == .interrupted)
        e.clock.advance(by: 0.01)
        e.write("a.txt", "after exit\n")
        await e.fire(["a.txt"])
        #expect(authors(e) == [.user, .outside])
    }

    @Test func editAwaitingPermissionDoesNotDelayTheWatcher() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let s = await e.ws.newSession(name: "A")
        let t = try #require(e.transports.all.first)
        let path = e.url("a.txt").path
        await t.emit(.assistantBlock(messageID: "m1", block: .toolUse(id: "t1", name: "Edit", input: .object(["file_path": .string(path)]))))
        await t.emit(.controlRequest(ControlRequest(requestID: "r1", kind: .canUseTool(
            toolName: "Edit", input: .object(["file_path": .string(path)]), description: nil, toolUseID: "t1", suggestions: []))))
        await waitUntil("permission pending") { s.hasPendingPermission }
        e.write("a.txt", "somebody else\n")
        await e.send(["a.txt"])
        // No clock advance past the 150 ms window: the change is recorded without the 2 s wait.
        await waitUntil("recorded without waiting") { authors(e).count == 2 }
        #expect(authors(e) == [.user, .outside])
    }

    // MARK: I3

    @Test func watcherDoesNotRelabelAToolResultsMerge() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\ntwo\nthree\n")
        _ = await e.ws.newSession(name: "Ann")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<3, with: "mine")
        let gate = TestGate()
        e.ws.refreshGate = { _, _ in await gate.hold() }
        try await e.sessionEdit("a.txt", old: "one\ntwo\nthree\n", new: "ONE\ntwo\nthree\n")
        await gate.waitUntilEntered()           // the tool result's refresh is merging
        await e.send(["a.txt"])
        await waitUntil("flush started") { e.ws.pendingOutside.isEmpty }
        for _ in 0..<200 { await Task.yield() }
        await gate.release()
        await e.ws.settle()
        #expect(e.ws.notices.contains { $0.text.contains("Ann's edit") })
        #expect(!e.ws.notices.contains { $0.text.contains("another change to the file") })
    }

    // MARK: I4 bulk changes

    @Test func unrelatedPathsAreNeverRead() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        var names: [String] = []
        for i in 0..<50 { let n = "out/f\(i).o"; try? FileManager.default.createDirectory(at: e.url("out"), withIntermediateDirectories: true); e.write(n, "\(i)"); names.append(n) }
        e.write("a.txt", "xone\nchanged\n")
        await e.fire(names + ["a.txt"])
        #expect(e.ws.outsideReadCount == 1)      // only the ledger file
        #expect(authors(e) == [.user, .outside])
    }

    @Test func trackedStatusIsAskedOncePerFlush() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("t.txt", "head\n")
        try git(e.root, "init", "-q"); try git(e.root, "add", "t.txt"); try git(e.root, "commit", "-q", "-m", "i")
        let s = await e.startBash()
        var names: [String] = []
        for i in 0..<30 { let n = "gen\(i).txt"; e.write(n, "\(i)\n"); names.append(n) }
        e.write("t.txt", "head\nmore\n")
        await e.fire(names + ["t.txt"])
        // One `ls-files` for the whole batch and one `cat-file` for the one tracked file.
        #expect(e.ws.gitSpawnCount == 2)
        #expect(authors(e, "t.txt") == [.session(s.id)])
        #expect(names.allSatisfy { e.ws.ledger.files[$0] == nil })
    }

    // MARK: Minor

    @Test func directoryRemovalMarksOpenFilesBelowItDeleted() async throws {
        let e = Env(); defer { e.cleanup() }
        try FileManager.default.createDirectory(at: e.url("sub"), withIntermediateDirectories: true)
        e.write("sub/b.txt", "b\n"); e.write("c.txt", "c\n")
        await e.ws.open("sub/b.txt"); await e.ws.open("c.txt")
        try FileManager.default.removeItem(at: e.url("sub"))
        e.ws.startWatching()
        e.changes.send([e.url("sub").path + "/"])
        await waitUntil("queued") { !e.ws.pendingOutside.isEmpty }
        e.clock.advance(by: 0.15)
        await e.ws.settle()
        #expect(e.ws.document("sub/b.txt")?.state == .readOnly(reason: "File was deleted outside Alloy"))
        #expect(e.ws.document("c.txt")?.state == .editable)
    }

    @Test func rescanOfTheRootRechecksEveryOpenFile() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "a\n"); e.write("b.txt", "b\n")
        await e.ws.open("a.txt"); await e.ws.open("b.txt")
        try FileManager.default.removeItem(at: e.url("a.txt"))
        e.write("b.txt", "changed\n")
        e.ws.startWatching()
        e.changes.send([e.root.path + "/"])
        await waitUntil("queued") { !e.ws.pendingOutside.isEmpty }
        e.clock.advance(by: 0.15)
        await e.ws.settle()
        #expect(e.ws.document("a.txt")?.state == .readOnly(reason: "File was deleted outside Alloy"))
        let b = try #require(e.ws.document("b.txt"))
        #expect(String(decoding: b.buffer.snapshot().utf8(in: 0..<b.buffer.snapshot().utf8Count), as: UTF8.self) == "changed\n")
    }

    @Test func deletedDirtyNoticeIsNotRepeated() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\n")
        await e.ws.open("a.txt")
        _ = try #require(e.ws.document("a.txt")).buffer.replace(0..<0, with: "typed ")
        try FileManager.default.removeItem(at: e.url("a.txt"))
        await e.fire(["a.txt"])
        await e.fire(["a.txt"])
        #expect(e.ws.notices.filter { $0.text.contains("deleted outside Alloy") }.count == 1)
    }

    @Test func tabThatCouldNotOpenReconcilesWhenItRecovers() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        try Data([0x61, 0x00, 0x62]).write(to: e.url("a.txt"))
        await e.ws.open("a.txt")
        #expect(e.ws.tabMessages["a.txt"] == "Binary file")
        e.write("a.txt", "text again\n")
        await e.fire(["a.txt"])
        #expect(e.ws.document("a.txt") != nil)
        #expect(authors(e).last == .outside)
        #expect(e.ws.ledger.files["a.txt"]?.text.text == "text again\n")
    }

    @Test func flushInFlightAtShutdownWritesNothing() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        _ = await e.ws.newSession(name: "A")
        let t = try #require(e.transports.all.first)
        await t.emit(.assistantBlock(messageID: "m1", block: .toolUse(id: "t1", name: "Write",
                                     input: .object(["file_path": .string(e.url("a.txt").path)]))))
        await waitUntil("running") { e.ws.sessions.first?.transcript.blocks.isEmpty == false }
        e.write("a.txt", "changed\n")
        await e.send(["a.txt"])
        await waitUntil("waiting") { e.clock.pendingSleepers == 1 }
        await e.ws.stopAll()
        e.clock.advance(by: 2.0)
        await e.ws.settle()
        #expect(authors(e) == [.user])
    }

    // MARK: Round 2

    @Test func oldMtimeDoesNotDefeatTheWindow() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let s = await e.startBash()
        e.clock.advance(by: 0.5)
        e.write("a.txt", "moved in with its old date\n")        // mv, cp -p, rsync -a, tar -x, touch -r ...
        e.setModified("a.txt", e.nowDate.addingTimeInterval(-3600))
        await e.fire(["a.txt"])
        #expect(authors(e) == [.user, .session(s.id)])
    }

    /// Minor 7: `cp -p` over a file with unsaved typing, found by the save (not the watcher). The preserved mtime
    /// lies inside a Bash window that ended seconds ago; the save must clamp it as the watcher would.
    @Test func savePathClampsAnOldMtimeLikeTheWatcher() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let s = await e.startBash()
        e.clock.advance(by: 0.2)
        await e.finishBash(s)
        let inWindow = e.nowDate                            // the preserved mtime: inside the window
        e.clock.advance(by: 10)                             // the window ended 8.8 s ago
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "typed ")
        e.write("a.txt", "xone\ntwo\nthree\nfour\n")        // cp -p
        e.setModified("a.txt", inWindow)
        try await e.ws.save("a.txt")
        #expect(authors(e) == [.user, .outside, .user])   // the cp, then the merged typing
    }

    /// The same mapping as a unit: a recent watcher arrival for the path wins; a fresh mtime is believed; an old
    /// one becomes `now - eventLag`.
    @Test func saveChangeTimeUsesTheWatcherArrivalOrClamps() async throws {
        let e = Env(); defer { e.cleanup() }
        e.clock.advance(by: 30)
        let now = e.clock.now
        let old = e.nowDate.addingTimeInterval(-3_600), fresh = e.nowDate.addingTimeInterval(-1)
        #expect(e.ws.saveChangeTime("a.txt", old) == nil)   // untrusted and unwitnessed: no time at all
        #expect(abs(try #require(e.ws.saveChangeTime("a.txt", fresh)) - (now - 1)) < 0.001)
        e.ws.recentArrival["a.txt"] = now - 0.5
        #expect(abs(try #require(e.ws.saveChangeTime("a.txt", old)) - (now - 0.5 - Workspace.eventLag)) < 0.001)
        #expect(abs(try #require(e.ws.saveChangeTime("a.txt", fresh)) - (now - 1)) < 0.001)
        // An arrival that is no longer recent is not used.
        e.ws.recentArrival["a.txt"] = now - 100
        #expect(e.ws.saveChangeTime("a.txt", old) == nil)
    }

    /// N1: a change made while Alloy was closed, found when the file is opened during a Bash run, is not that
    /// session's: nothing witnesses its time, and an old mtime is untrusted.
    @Test func oldChangeFoundOnOpenIsOutsideEvenWhileABashRuns() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let s = await e.startBash()
        e.clock.advance(by: 0.5)
        e.write("a.txt", "changed while Alloy was closed\n")
        e.setModified("a.txt", e.nowDate.addingTimeInterval(-3600))
        await e.ws.open("a.txt")
        await e.ws.settle()
        #expect(authors(e) == [.user, .outside])
        _ = s
    }

    /// The `cp -p` save case WITH a recent watcher arrival still clamps (here into the running Bash's window).
    @Test func savePathClampsWhenTheWatcherRecentlyReportedThePath() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let s = await e.startBash()
        e.clock.advance(by: 0.5)
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "typed ")
        e.write("a.txt", "xone\ntwo\nthree\nfour\n")
        e.setModified("a.txt", e.nowDate.addingTimeInterval(-3600))
        e.ws.recentArrival["a.txt"] = e.clock.now
        try await e.ws.save("a.txt")
        #expect(authors(e) == [.user, .session(s.id), .user])
    }

    /// Minor: a flush forgets arrivals that are no longer recent.
    @Test func flushForgetsOldArrivals() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        e.clock.advance(by: 100)
        e.ws.recentArrival["gone.txt"] = 1
        e.write("a.txt", "x\n")
        await e.fire(["a.txt"])
        #expect(e.ws.recentArrival["gone.txt"] == nil)
        #expect(e.ws.recentArrival["a.txt"] != nil)
    }

    @Test func oldMtimeOnATrackedFileStillGetsAGitBaseline() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("t.txt", "head\n")
        try git(e.root, "init", "-q"); try git(e.root, "add", "t.txt"); try git(e.root, "commit", "-q", "-m", "i")
        let s = await e.startBash()
        e.clock.advance(by: 0.5)
        e.write("t.txt", "head\nchanged\n")
        e.setModified("t.txt", e.nowDate.addingTimeInterval(-86_400))
        await e.fire(["t.txt"])
        #expect(authors(e, "t.txt") == [.session(s.id)])
    }

    @Test func stopInterruptsRunningToolsAndDropsWindows() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = await e.startBash()
        #expect(e.ws.shellWindowCount == 1)
        await e.ws.stop(s.id)
        let block = s.transcript.blocks.compactMap { b -> ToolBlock? in if case .tool(let t) = b { return t } else { return nil } }.first
        #expect(block?.status == .interrupted)
        #expect(e.ws.shellWindowCount == 0)
    }

    @Test func backgroundShellGetsOnlyTheNormalGrace() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let s = await e.startBash(background: true)
        await e.finishBash(s)                       // "command running in background" comes back at once
        e.clock.advance(by: 0.5)
        e.write("a.txt", "inside the grace\n")
        await e.fire(["a.txt"])
        #expect(authors(e) == [.user, .session(s.id)])
        e.clock.advance(by: 5)                      // the background command's later writes are not attributed
        e.write("a.txt", "five seconds later\n")
        await e.fire(["a.txt"])
        #expect(authors(e) == [.user, .session(s.id), .outside])
    }

    @Test func lateMainActorStillTrustsAFreshMtime() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        let s = await e.startBash()
        await e.finishBash(s)                       // window ends at 1.0
        e.clock.advance(by: 0.8)
        e.write("a.txt", "written inside the grace\n")
        e.clock.advance(by: 1.5)                    // the event only reaches the watcher at 2.3
        await e.fire(["a.txt"])
        #expect(authors(e) == [.user, .session(s.id)])
    }

    @Test func lateTrackedFileWithAFreshMtimeAlsoPassesTheFilter() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("t.txt", "head\n")
        try git(e.root, "init", "-q"); try git(e.root, "add", "t.txt"); try git(e.root, "commit", "-q", "-m", "i")
        let s = await e.startBash()
        await e.finishBash(s)
        e.clock.advance(by: 0.8)
        e.write("t.txt", "head\nmore\n")
        e.clock.advance(by: 1.5)
        await e.fire(["t.txt"])
        #expect(authors(e, "t.txt") == [.session(s.id)])
    }

    @Test func coalescingKeepsTheLastArrivalOfAPath() async throws {
        let e = Env(); defer { e.cleanup() }
        try await seed(e)
        e.write("a.txt", "x\n")
        e.ws.startWatching()
        e.changes.send([e.url("a.txt").path])
        await waitUntil("first") { e.ws.pendingOutside.count == 1 }
        e.clock.advance(by: 0.1)
        e.changes.send([e.url("a.txt").path])
        await waitUntil("second arrival recorded") { e.ws.pendingOutside[e.url("a.txt").path] == 0.1 }
        e.clock.advance(by: 0.05)
        await e.ws.settle()
        // One batch, one change: the two events made a single outside record, and nothing is left waiting.
        #expect(e.ws.pendingOutside.isEmpty)
        #expect(authors(e) == [.user, .outside])
        #expect(e.ws.ledger.files["a.txt"]?.text.text == "x\n")
    }

    // MARK: FileStamp

    @Test(arguments: [true, false]) func sameSizeSameMtimeChangeIsStillSeenBySave(inPlace: Bool) async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\ntwo\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        let oldDate = try #require(try FileManager.default.attributesOfItem(atPath: e.url("a.txt").path)[.modificationDate] as? Date)
        _ = doc.buffer.replace(0..<0, with: "x")                 // unsaved typing
        // Another program rewrites line two: same size, then puts the old modification date back
        // (cp -p, touch -r, rsync -a all do).
        if inPlace {
            let h = try FileHandle(forWritingTo: e.url("a.txt"))
            try h.write(contentsOf: Data("one\nTWO\n".utf8)); try h.close()
        } else {
            try "one\nTWO\n".write(to: e.url("a.txt"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: e.url("a.txt").path)
        try await e.ws.save("a.txt")
        #expect(e.read("a.txt") == "xone\nTWO\n")               // merged, not overwritten
    }

    @Test func fileStampRoundTrips() throws {
        let stamp = FileStamp(modified: Date(timeIntervalSince1970: 1_700_000_000.25), size: 42, inode: 7,
                              changed: Date(timeIntervalSince1970: 1_700_000_001.5))
        let back = try JSONDecoder().decode(FileStamp.self, from: JSONEncoder().encode(stamp))
        #expect(back == stamp)
        let none = FileStamp(modified: nil, size: 0)
        #expect(try JSONDecoder().decode(FileStamp.self, from: JSONEncoder().encode(none)) == none)
    }

    /// The stamp that goes with the bytes read is the open file's, not whatever the path names a moment later.
    @Test func descriptorStampSurvivesAReplacementOfThePath() throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "old\n")
        let handle = try FileHandle(forReadingFrom: e.url("a.txt"))
        defer { try? handle.close() }
        let before = try #require(FileStamp.read(descriptor: handle.fileDescriptor))
        try "newer text\n".write(to: e.url("a.txt"), atomically: true, encoding: .utf8)   // replaces the inode
        let viaDescriptor = try #require(FileStamp.read(descriptor: handle.fileDescriptor))
        let viaPath = try #require(FileStamp.read(e.url("a.txt").path))
        // (The old inode's change time moves when it is unlinked, so compare the identity fields.)
        #expect(viaDescriptor.inode == before.inode && viaDescriptor.modified == before.modified)
        #expect(viaDescriptor.size == 4 && viaPath.size == 11)
        #expect(viaDescriptor.inode != viaPath.inode)
        // And readForEditing agrees with the file it read.
        if case .text(let bytes, let stamp, _) = Workspace.readForEditing(url: e.url("a.txt")) {
            #expect(String(decoding: bytes, as: UTF8.self) == "newer text\n")
            #expect(stamp == viaPath)
        } else { Issue.record("not text") }
    }

    @Test func stampsDifferByInodeAndCtime() throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "abc")
        let a = try #require(FileStamp.read(e.url("a.txt").path))
        let date = try #require(try FileManager.default.attributesOfItem(atPath: e.url("a.txt").path)[.modificationDate] as? Date)
        try "xyz".write(to: e.url("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: e.url("a.txt").path)
        let b = try #require(FileStamp.read(e.url("a.txt").path))
        #expect(a.size == b.size && a.modified == b.modified)
        #expect(a != b)
    }
    @Test func deletionNoticeShowsAgainAfterTheFileCameBack() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\n")
        await e.ws.open("a.txt")
        _ = try #require(e.ws.document("a.txt")).buffer.replace(0..<0, with: "typed ")
        try FileManager.default.removeItem(at: e.url("a.txt"))
        await e.fire(["a.txt"])
        await e.fire(["a.txt"])
        #expect(e.ws.notices.filter { $0.text.contains("deleted outside Alloy") }.count == 1)
        e.write("a.txt", "typed one\n")                  // it came back and the merge saved the buffer
        await e.fire(["a.txt"])
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "more ")      // typing again, then it is deleted again
        try FileManager.default.removeItem(at: e.url("a.txt"))
        await e.fire(["a.txt"])
        #expect(e.ws.notices.filter { $0.text.contains("deleted outside Alloy") }.count == 2)
    }

    @Test func hungGitIsAbandonedAfterTheHardCap() async throws {
        let e = Env(); defer { e.cleanup() }
        // `git hang` runs `sleep 2`; the run is cut off after a fraction of a second. Without the cut-off the
        // result is empty output (not nil) after 2 s. A loaded machine can delay a single attempt past the bound,
        // so the bound has to hold for one of three attempts.
        var cutOff = false
        for _ in 0..<3 where !cutOff {
            let start = Date()
            let out = await Workspace.gitRun(["-c", "alias.hang=!sleep 2", "hang"], in: e.root, terminateAfter: 0.1, killAfter: 0.3)
            #expect(out == nil)
            cutOff = Date().timeIntervalSince(start) < 1.9
        }
        #expect(cutOff)
    }
}
