import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Sparkle
import Testing

@MainActor
final class FakeUpdateDriver: UpdateDriving {
    var automaticChecks = true
    var lastUpdateCheckDate: Date?
    var events: [String] = []
    var startCount = 0
    func start() throws { startCount += 1; events.append("start") }
    func checkForUpdates() { events.append("check") }
    func installNow() { events.append("installNow") }
    func installOnQuit() { events.append("installOnQuit") }
}

private let appURL = URL(fileURLWithPath: "/Applications/Alloy.app")
private let validKey = Data(repeating: 7, count: 32).base64EncodedString()
private var goodInfo: [String: Any] { ["SUFeedURL": "https://mburger89.github.io/Alloy/appcast.xml", "SUPublicEDKey": validKey] }

@MainActor
private func started(_ driver: FakeUpdateDriver = FakeUpdateDriver(), shutdown: @escaping @MainActor () async -> Void = {})
    -> (UpdateController, UpdateModel, FakeUpdateDriver) {
    let model = UpdateModel()
    let controller = UpdateController(driver: driver, model: model, now: { Date(timeIntervalSince1970: 1_800_000_000) }, shutdown: shutdown)
    #expect(controller.start(bundleURL: appURL, info: goodInfo, environment: [:]))
    return (controller, model, driver)
}

@MainActor
private func text(_ window: TestWindow, _ id: String) -> String? { (try? window.element(identifier: id)).flatMap { $0.value ?? $0.label } }

private let notes = "## 0.2.0\n\n- Faster **startup**\n- Fixes a crash"

@MainActor
@Suite struct UpdateTests {
    @Test func lastCheckIsLoadedFromTheEngineAtStart() async throws {
        let driver = FakeUpdateDriver()
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        driver.lastUpdateCheckDate = when
        let (_, model, _) = started(driver)
        #expect(model.lastCheck == when)
        #expect(UpdatesSection.lastChecked(model).hasPrefix("Last checked"))
        let (_, fresh, _) = started()
        #expect(fresh.lastCheck == nil)
        #expect(UpdatesSection.lastChecked(fresh) == "Not checked yet")
    }

    @Test func releaseNotesFollowTheItemsFormat() {
        let md = "## 0.2.0\n\n- Faster **startup**\n- A <b>literal</b>"
        #expect(ReleaseNotesFormat.text(md, format: "markdown") == md)
        #expect(ReleaseNotesFormat.text(md, format: "plain-text") == md)
        let html = "<h2>0.2.0</h2><p>Fast &amp; <b>small</b>.</p><ul><li>Faster startup</li><li>Fixes a &lt;crash&gt;</li></ul><script>alert(1)</script>"
        let text = ReleaseNotesFormat.text(html, format: "html")
        #expect(text == "0.2.0\n\nFast & small.\n\n- Faster startup\n- Fixes a <crash>", "\(text ?? "nil")")
        #expect(ReleaseNotesFormat.text("<p>No format</p>", format: nil) == "No format")
        #expect(ReleaseNotesFormat.text(nil, format: "html") == nil)
        #expect(ReleaseNotesFormat.format(forMIMEType: "text/markdown") == "markdown")
        #expect(ReleaseNotesFormat.format(forMIMEType: "text/html") == nil)
    }

    @Test func feedOverrideIsIgnoredInReleaseBuilds() {
        let env = ["ALLOY_UPDATE_FEED_URL": "https://example.test/appcast.xml"]
        #expect(UpdateFeedPolicy.override(info: [:], environment: env) == "https://example.test/appcast.xml")
        #expect(UpdateFeedPolicy.override(info: ["AlloyReleaseBuild": false], environment: env) == "https://example.test/appcast.xml")
        #expect(UpdateFeedPolicy.override(info: ["AlloyReleaseBuild": true], environment: env) == nil)
        #expect(UpdateFeedPolicy.override(info: [:], environment: [:]) == nil)
        #expect(UpdateFeedPolicy.override(info: [:], environment: ["ALLOY_UPDATE_FEED_URL": "not a url"]) == nil)
        #expect(UpdateFeedPolicy.override(info: [:], environment: ["ALLOY_UPDATE_FEED_URL": "file:///etc/passwd"]) == nil)
    }

    @Test func bannerShowsInTheProjectChooserToo() async throws {
        let (controller, model, _) = started()
        let launcher = LauncherModel()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) { launcherRoot(model: launcher, updates: model, center: testCenter(for: launcher)) }
        window.tick()
        #expect((try? window.element(identifier: "update-banner")) == nil)
        _ = try window.element(identifier: "choose-folder")
        controller.updateFound(version: "0.2.0", notes: notes)
        controller.readyToInstall(version: "0.2.0")
        for _ in 0..<3 { window.tick() }
        #expect(text(window, "update-banner-title") == "Alloy 0.2.0 is ready")
        _ = try window.element(identifier: "choose-folder")
        try window.click(window.element(identifier: "update-show-notes"))
        for _ in 0..<5 { window.tick() }
        _ = try window.element(identifier: "update-notes")
    }

    @Test func foundUpdateShowsBanner() async throws {
        let (controller, model, _) = started()
        let rig = Rig()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) { rootView(workspace: rig.workspace, updates: model, center: testCenter(for: rig.workspace)) }
        window.tick(); window.tick()
        #expect((try? window.element(identifier: "update-banner")) == nil)
        controller.updateFound(version: "0.2.0", notes: notes)
        controller.downloadProgress(0.5)
        window.tick()
        #expect((try? window.element(identifier: "update-banner")) == nil)   // downloading is quiet
        controller.readyToInstall(version: "0.2.0")
        for _ in 0..<3 { window.tick() }
        #expect(text(window, "update-banner-title") == "Alloy 0.2.0 is ready")
        _ = try window.element(identifier: "update-restart")
    }

    @Test func notesSheetShowsReleaseNotes() async throws {
        let (controller, model, _) = started()
        let rig = Rig()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) { rootView(workspace: rig.workspace, updates: model, center: testCenter(for: rig.workspace)) }
        controller.updateFound(version: "0.2.0", notes: notes)
        controller.readyToInstall(version: "0.2.0")
        for _ in 0..<3 { window.tick() }
        #expect((try? window.element(identifier: "update-notes")) == nil)
        try window.click(window.element(identifier: "update-show-notes"))
        for _ in 0..<5 { window.tick() }
        _ = try window.element(identifier: "update-notes")
        #expect(text(window, "update-notes-title") == "What's new in Alloy 0.2.0")
        _ = try window.element(label: "Fixes a crash")
        try window.click(window.element(identifier: "update-notes-close"))
        for _ in 0..<3 { window.tick() }
        #expect((try? window.element(identifier: "update-notes")) == nil)
    }

    @Test func installWaitsForQuit() async throws {
        let rig = Rig()
        let launcher = LauncherModel(workspace: rig.workspace)
        _ = await rig.workspace.newSession(name: "A")
        let (controller, model, driver) = started()
        var runningAtHook: [Bool] = []
        launcher.onShutdownComplete = {
            runningAtHook = rig.workspace.sessions.map { $0.status == .working || $0.status == .idle || $0.status == .starting }
            controller.applicationWillQuit()
        }
        controller.readyToInstall(version: "0.2.0")
        for _ in 0..<50 { await Task.yield() }
        #expect(!driver.events.contains("installOnQuit") && !driver.events.contains("installNow"))
        #expect(model.readyVersion == "0.2.0")
        var replied = false
        _ = launcher.shutdownRequested { _ in replied = true }
        for _ in 0..<2000 where !replied { await Task.yield() }
        #expect(replied)
        #expect(runningAtHook == [false], "sessions were still running when the update was told to install")
        #expect(driver.events.last == "installOnQuit")
        #expect(await rig.transports[0].stopAndWaitCalls + (await rig.transports[0].terminated ? 1 : 0) > 0)
    }

    @Test func quitWithoutReadyUpdateInstallsNothing() async throws {
        let (controller, _, driver) = started()
        controller.applicationWillQuit()
        #expect(!driver.events.contains("installOnQuit"))
    }

    @Test func restartRunsShutdownThenInstalls() async throws {
        let driver = FakeUpdateDriver()
        let (controller, model, _) = started(driver, shutdown: { driver.events.append("shutdown") })
        controller.restartToUpdate()   // nothing ready yet: ignored
        for _ in 0..<20 { await Task.yield() }
        #expect(!driver.events.contains("shutdown"))
        controller.readyToInstall(version: "0.2.0")
        model.restartToUpdate()
        for _ in 0..<50 where !driver.events.contains("installNow") { await Task.yield() }
        #expect(driver.events.suffix(2) == ["shutdown", "installNow"])
        // The shutdown's own quit hook must not take the install-on-quit path while restarting.
        controller.applicationWillQuit()
        #expect(!driver.events.contains("installOnQuit"))
    }

    @Test func feedErrorIsQuiet() async throws {
        let (controller, model, _) = started()
        let rig = Rig()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) { rootView(workspace: rig.workspace, updates: model, center: testCenter(for: rig.workspace)) }
        controller.checkStarted()
        controller.failed(message: "The network connection was lost.")
        #expect(model.state == .error(message: "The network connection was lost."))
        #expect(model.lastFailure != nil)
        for _ in 0..<3 { window.tick() }
        #expect((try? window.element(identifier: "update-banner")) == nil)
        #expect((try? window.element(identifier: "update-notes")) == nil)
        let sw = try TestWindow(size: Size(width: Pixels(560), height: Pixels(820))) { settingsWindowElement(SettingsWindowRoot(workspace: rig.workspace, themes: nil, updates: model, close: {}, gone: {})) }
        for _ in 0..<5 { sw.tick() }
        let status = try #require(text(sw, "settings-update-status"))
        #expect(status.hasPrefix("Couldn\u{2019}t check for updates ("))
        #expect(status.count > "Couldn\u{2019}t check for updates ()".count, "shows the time")
        // A waiting update survives a later failed check.
        controller.readyToInstall(version: "0.2.0")
        controller.failed(message: "offline")
        #expect(model.readyVersion == "0.2.0")
        controller.noUpdate()
        #expect(model.readyVersion == "0.2.0")
    }

    @Test func automaticChecksToggleIsPersisted() async throws {
        let driver = FakeUpdateDriver()
        let (controller, model, _) = started(driver)
        #expect(model.automaticChecks)
        controller.setAutomaticChecks(false)
        #expect(!driver.automaticChecks && !model.automaticChecks)
        // A new controller over the same engine reads the persisted flag back.
        let again = UpdateModel()
        _ = UpdateController(driver: driver, model: again)
        #expect(!again.automaticChecks)
        // And Settings drives it.
        let rig = Rig()
        let window = try TestWindow(size: Size(width: Pixels(560), height: Pixels(820))) { settingsWindowElement(SettingsWindowRoot(workspace: rig.workspace, themes: nil, updates: model, close: {}, gone: {})) }
        for _ in 0..<5 { window.tick() }
        try window.click(window.element(identifier: "settings-update-automatic"))
        window.tick()
        #expect(driver.automaticChecks && model.automaticChecks)
    }

    @Test func settingsCheckButtonAsksTheDriver() async throws {
        let (controller, model, driver) = started()
        defer { withExtendedLifetime(controller) {} }
        let rig = Rig()
        let window = try TestWindow(size: Size(width: Pixels(560), height: Pixels(820))) { settingsWindowElement(SettingsWindowRoot(workspace: rig.workspace, themes: nil, updates: model, close: {}, gone: {})) }
        for _ in 0..<5 { window.tick() }
        try window.click(window.element(identifier: "settings-update-check"))
        #expect(driver.events.last == "check")
    }

    @Test func startPolicyRejectsNonHTTPSFeeds() {
        for feed in ["http://example.test/appcast.xml", "ftp://example.test/appcast.xml", "file:///x", "https://", "https:///appcast.xml", "not a url", ""] {
            var info = goodInfo
            info["SUFeedURL"] = feed
            #expect(!UpdateStartPolicy.canStart(bundleURL: appURL, info: info, environment: [:]), "\(feed)")
        }
    }

    @Test func startPolicyAcceptsHTTPS() {
        #expect(UpdateStartPolicy.canStart(bundleURL: appURL, info: goodInfo, environment: [:]))
    }

    @Test func updaterNotStartedOutsideBundle() async throws {
        let driver = FakeUpdateDriver()
        let controller = UpdateController(driver: driver, model: UpdateModel())
        // swift run / debug binary: not a .app.
        #expect(!controller.start(bundleURL: URL(fileURLWithPath: "/x/.build/debug"), info: goodInfo, environment: [:]))
        // Bundle without a key (dev or ad hoc build), without a feed, with a blank key.
        #expect(!controller.start(bundleURL: appURL, info: ["SUFeedURL": goodInfo["SUFeedURL"]!], environment: [:]))
        #expect(!controller.start(bundleURL: appURL, info: ["SUPublicEDKey": validKey], environment: [:]))
        #expect(!controller.start(bundleURL: appURL, info: ["SUFeedURL": "https://x/a.xml", "SUPublicEDKey": " "], environment: [:]))
        // Placeholder, short and non-base64 keys are no key.
        for bad in ["REPLACE_AT_BUNDLE_TIME", "abc=", Data(repeating: 1, count: 31).base64EncodedString()] {
            #expect(!controller.start(bundleURL: appURL, info: ["SUFeedURL": "https://x/a.xml", "SUPublicEDKey": bad], environment: [:]), "\(bad)")
        }
        // Under a test runner, even a complete bundle does not start.
        #expect(!controller.start(bundleURL: appURL, info: goodInfo, environment: ["XCTestConfigurationFilePath": "/t"]))
        #expect(!controller.started)
        #expect(driver.startCount == 0)
        #expect(controller.start(bundleURL: appURL, info: goodInfo, environment: [:]))
        #expect(driver.startCount == 1)
        // The test process itself is not a bundled app: the real bundle never qualifies.
        #expect(!UpdateStartPolicy.canStart(bundleURL: Bundle.main.bundleURL, info: Bundle.main.infoDictionary ?? [:],
                                            environment: ProcessInfo.processInfo.environment))
    }

    @Test func bannerDoesNotRerunWhileTyping() async throws {
        let (rig, _) = try await editedRig()
        let (controller, model, _) = started()
        controller.readyToInstall(version: "0.2.0")
        rig.workspace.openFilePath = "login.swift"
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) { rootView(workspace: rig.workspace, updates: model, center: testCenter(for: rig.workspace)) }
        window.tick(); window.tick()
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        _ = try window.element(identifier: "update-banner")
        try window.click(window.element(identifier: "code-view"))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        let names = ["SidebarView", "UpdateBanner", "AlloyScreen"]
        var reruns: [String: Int] = [:]
        for _ in 0..<20 {
            let before = names.map(BodyProbe.count)
            window.typeText("a"); window.tick()
            for (i, n) in names.enumerated() { reruns[n, default: 0] += BodyProbe.count(n) - before[i] }
            await Task.yield()
        }
        #expect(reruns["UpdateBanner"] == 0, "banner re-ran \(reruns["UpdateBanner"]!)")
        #expect(reruns["AlloyScreen"] == 0, "screen re-ran \(reruns["AlloyScreen"]!)")
        #expect(reruns["SidebarView"] == 0, "sidebar re-ran \(reruns["SidebarView"]!)")
        // A model change re-runs the banner alone, not the sidebar.
        let before = names.map(BodyProbe.count)
        controller.readyToInstall(version: "0.3.0")
        // No await here: another suite's window must not tick between the two counts.
        for _ in 0..<3 { window.tick() }
        #expect(BodyProbe.count("UpdateBanner") > before[1])
        #expect(BodyProbe.count("SidebarView") == before[0])
        #expect(text(window, "update-banner-title") == "Alloy 0.3.0 is ready")
    }

    @Test func foundUpdateDecisionCoversEveryStage() {
        #expect(UpdateFoundDecision.decide(stage: .notDownloaded, informationOnly: false) == .download)
        #expect(UpdateFoundDecision.decide(stage: .downloaded, informationOnly: false) == .download)
        // A resumed prepared installer must never be answered "install" (that relaunches at once).
        #expect(UpdateFoundDecision.decide(stage: .installing, informationOnly: false) == .holdAsReady)
        for stage in [SPUUserUpdateStage.notDownloaded, .downloaded, .installing] {
            #expect(UpdateFoundDecision.decide(stage: stage, informationOnly: true) == .dismiss)
        }
    }

    @Test func cycleErrorsAreMapped() {
        #expect(UpdateCycleError.message(nil) == nil)
        let none = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))
        #expect(UpdateCycleError.message(none) == nil)
        let feed = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                           userInfo: [NSLocalizedDescriptionKey: "offline"])
        #expect(UpdateCycleError.message(feed) == "offline")
    }

    @Test func backgroundCycleRecordsLastCheckAndQuietFailure() {
        let (controller, model, _) = started()
        #expect(model.lastCheck == nil)
        controller.cycleFinished(errorMessage: nil)
        #expect(model.lastCheck != nil && model.lastFailure == nil)
        controller.cycleFinished(errorMessage: "offline")
        #expect(model.lastFailure != nil)
        #expect(model.state == .error(message: "offline"))
        controller.cycleFinished(errorMessage: nil)
        #expect(model.lastFailure == nil && model.state == .idle)
    }

    @Test func restartAsksWhenASessionIsBusy() async {
        let driver = FakeUpdateDriver()
        var busy = 1
        let model = UpdateModel()
        let controller = UpdateController(driver: driver, model: model, busySessions: { busy }, shutdown: { driver.events.append("shutdown") })
        controller.start(bundleURL: appURL, info: goodInfo, environment: [:])
        controller.readyToInstall(version: "0.2.0")
        model.restartToUpdate()
        for _ in 0..<30 { await Task.yield() }
        #expect(model.confirmingRestart && model.busySessionCount == 1)
        #expect(!driver.events.contains("shutdown"), "nothing stops before the user confirms")
        model.cancelRestart()
        #expect(!model.confirmingRestart)
        for _ in 0..<30 { await Task.yield() }
        #expect(!driver.events.contains("shutdown") && !driver.events.contains("installNow"))
        model.restartToUpdate()
        model.confirmRestart()
        for _ in 0..<50 where !driver.events.contains("installNow") { await Task.yield() }
        #expect(driver.events.suffix(2) == ["shutdown", "installNow"])
        // Idle sessions: restarts directly.
        busy = 0
        let d2 = FakeUpdateDriver()
        let m2 = UpdateModel()
        let c2 = UpdateController(driver: d2, model: m2, busySessions: { busy }, shutdown: { d2.events.append("shutdown") })
        c2.start(bundleURL: appURL, info: goodInfo, environment: [:])
        c2.readyToInstall(version: "0.2.0")
        m2.restartToUpdate()
        for _ in 0..<50 where !d2.events.contains("installNow") { await Task.yield() }
        #expect(!m2.confirmingRestart)
        #expect(d2.events.suffix(2) == ["shutdown", "installNow"])
    }

    @Test func confirmationShowsInTheBanner() throws {
        var busy = 2
        let model = UpdateModel()
        let driver = FakeUpdateDriver()
        let controller = UpdateController(driver: driver, model: model, busySessions: { busy })
        controller.start(bundleURL: appURL, info: goodInfo, environment: [:])
        controller.readyToInstall(version: "0.2.0")
        let rig = Rig()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) { rootView(workspace: rig.workspace, updates: model, center: testCenter(for: rig.workspace)) }
        for _ in 0..<3 { window.tick() }
        try window.click(window.element(identifier: "update-restart"))
        for _ in 0..<3 { window.tick() }
        #expect(text(window, "update-restart-confirm-text") == "2 sessions are still working. Restarting stops them.")
        try window.click(window.element(identifier: "update-restart-cancel"))
        for _ in 0..<3 { window.tick() }
        #expect((try? window.element(identifier: "update-restart-confirm")) == nil)
        _ = try window.element(identifier: "update-restart")
        busy = 0
    }

    @Test func droppedPreparedUpdateClearsBannerAndRestartRecovers() async {
        let driver = FakeUpdateDriver()
        let (controller, model, _) = started(driver)
        controller.readyToInstall(version: "0.2.0")
        controller.restartToUpdate()
        for _ in 0..<50 where !driver.events.contains("installNow") { await Task.yield() }
        controller.preparedUpdateDropped()
        #expect(model.readyVersion == nil && model.state == .idle)
        controller.readyToInstall(version: "0.3.0")
        controller.restartToUpdate()   // not stuck in "restarting"
        for _ in 0..<50 where driver.events.filter({ $0 == "installNow" }).count < 2 { await Task.yield() }
        #expect(driver.events.filter { $0 == "installNow" }.count == 2)
    }

    @Test func checkWhileReadyShowsTheReadyUpdate() {
        let (controller, model, driver) = started()
        controller.updateFound(version: "0.2.0", notes: notes)
        controller.readyToInstall(version: "0.2.0")
        let checks = driver.events.filter { $0 == "check" }.count
        controller.checkForUpdates()
        #expect(model.showingNotes)
        #expect(driver.events.filter { $0 == "check" }.count == checks, "Sparkle would refuse a check while a session is waiting")
    }

    @Test func cancelledTerminationThenRestartWorks() async {
        let driver = FakeUpdateDriver()
        let (controller, _, _) = started(driver)
        controller.readyToInstall(version: "0.2.0")
        controller.restartToUpdate()
        for _ in 0..<50 where !driver.events.contains("installNow") { await Task.yield() }
        controller.restartToUpdate()   // still restarting: ignored
        for _ in 0..<20 { await Task.yield() }
        #expect(driver.events.filter { $0 == "installNow" }.count == 1)
        controller.restartAborted()    // termination was cancelled
        controller.restartToUpdate()
        for _ in 0..<50 where driver.events.filter({ $0 == "installNow" }).count < 2 { await Task.yield() }
        #expect(driver.events.filter { $0 == "installNow" }.count == 2)
    }

    @Test func staleAutomaticBlockIsDroppedAndReplyWins() {
        let driver = SparkleDriver(defaults: UserDefaults(suiteName: "alloy-update-\(UUID().uuidString)")!)
        let model = UpdateModel()
        let controller = UpdateController(driver: FakeUpdateDriver(), model: model)
        driver.controller = controller
        let calls = Calls()
        // Automatic block, then a newer manual reply: the reply is used, the block never.
        driver.holdImmediateInstall { calls.add("block") }
        driver.holdReadyReply { calls.add("reply \($0 == .install)") }
        driver.installNow()
        #expect(calls.list == ["reply true"])
        // An aborted automatic session: the block is dead, installNow does nothing.
        let other = SparkleDriver(defaults: UserDefaults(suiteName: "alloy-update-\(UUID().uuidString)")!)
        other.controller = controller
        model.state = .readyToInstall(version: "0.2.0")
        other.holdImmediateInstall { calls.add("dead block") }
        other.automaticSessionEnded()
        other.installNow()
        #expect(!calls.list.contains("dead block"))
        #expect(model.readyVersion == nil, "the banner goes with the dead block")
    }

    @Test func informationOnlyUpdateStaysOffered() {
        let (controller, model, _) = started()
        controller.updateFound(version: "1.0.0", notes: nil)
        controller.cycleFinished(errorMessage: nil)
        #expect(model.state == .available(version: "1.0.0", notes: nil))
    }
}

final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var list: [String] { lock.withLock { items } }
}
