import AlloyCore
import Testing

@Suite struct ThemeGuidanceTests {
    @Test func acpTextUsesShortNames() {
        #expect(ThemeGuidance.acpText.contains("theme_preview"))
        #expect(!ThemeGuidance.acpText.contains("mcp__alloy__"))
    }

    @Test func claudeTextKeepsItsWording() {
        #expect(ThemeGuidance.text.contains("call mcp__alloy__theme_slots to learn the slots"))
    }

    @Test func fileModeTextNamesFolder() {
        let text = ThemeGuidance.fileModeText(themesFolder: "/x/Themes")
        #expect(text.contains("/x/Themes"))
        #expect(!text.contains("mcp__"))
        #expect(text.contains("Never overwrite an existing file"))
    }

    @Test func themeTitleAutoAllow() {
        #expect(Guidance.isAlloyToolTitle("alloy: theme_preview", server: "alloy", includeTheme: true))
        #expect(!Guidance.isAlloyToolTitle("alloy: theme_preview", server: "alloy", includeTheme: false))
        #expect(!Guidance.isAlloyToolTitle("alloy: theme_preview", server: "alloy"))
        #expect(!Guidance.isAlloyToolTitle("alloy: p_abc123_theme_preview", server: "alloy", includeTheme: true))
        #expect(!Guidance.isAlloyToolTitle("alloy: p_abc123_theme_preview", server: "alloy", includeTheme: false))
        #expect(Guidance.isAlloyToolTitle("alloy: notes_lookup", server: "alloy", includeTheme: true))
        #expect(Guidance.themeToolShortNames == ["theme_slots", "theme_read", "theme_check", "theme_preview", "theme_save"])
    }
}
