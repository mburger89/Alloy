import Foundation
import Testing

@Suite struct InfoPlistTests {
    private static func load() -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packaging/macOS/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return [:] }
        return dict
    }

    @Test func usageStringsAreOnePlainLine() {
        let line = "Alloy opens and runs tools in the folders you choose."
        for key in ["NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription",
                    "NSDownloadsFolderUsageDescription", "NSAppleEventsUsageDescription"] {
            #expect(Self.load()[key] as? String == line, "\(key)")
        }
    }

    @Test func categoryAndCopyright() {
        #expect(Self.load()["LSApplicationCategoryType"] as? String == "public.app-category.developer-tools")
        #expect(Self.load()["NSHumanReadableCopyright"] as? String == "Copyright © 2026 Max Burger. MIT License.")
    }

    @Test func feedIsHTTPS() {
        let feed = Self.load()["SUFeedURL"] as? String
        #expect(feed.flatMap { URL(string: $0)?.scheme } == "https")
    }
}
