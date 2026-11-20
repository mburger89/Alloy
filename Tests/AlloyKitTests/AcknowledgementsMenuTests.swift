import AlloyCore
import MetalUI
import MetalUITesting
import Testing
@testable import AlloyKit

@MainActor
@Suite struct AcknowledgementsMenuTests {
    private func window(open: (@MainActor () -> Void)?) throws -> TestWindow {
        let model = LauncherModel()
        let center = testCenter(for: model)
        let window = try TestWindow(size: Size(width: Pixels(900), height: Pixels(600))) { launcherRoot(model: model, center: center) }
        window.testApp.app.commands { alloyCommands(center: center, openAcknowledgements: open) }
        window.tick()
        return window
    }

    @Test func acknowledgementsItemSitsNextToAboutAndOpensTheNoticesFile() throws {
        var opened = 0
        let window = try window(open: { opened += 1 })
        let appMenu = try #require(window.testApp.menuBar.first)
        let titles = appMenu.items.map(\.title)
        let about = try #require(titles.firstIndex { $0.hasPrefix("About") })
        let ack = try #require(titles.firstIndex(of: "Acknowledgements"))
        #expect(abs(ack - about) <= 2)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "menu-acknowledgements")
        #expect(opened == 1)
    }

    @Test func noOpenerMeansNoMenuItem() throws {
        let window = try window(open: nil)
        let ids = window.testApp.menuBar.flatMap(\.items).map(\.accessibilityIdentifier)
        #expect(!ids.contains("menu-acknowledgements"))
    }
}
