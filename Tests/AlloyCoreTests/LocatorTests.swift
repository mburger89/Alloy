import AlloyCore
import Foundation
import Testing

@Suite struct LocatorTests {
    let home = "/home/me"

    @Test func locatorPrefersOverride() throws {
        let url = try ClaudeLocator.locate(override: "/custom/claude", loginShellLookup: { "/shell/claude" },
                                           isExecutable: { _ in true }, home: home)
        #expect(url.path == "/custom/claude")
    }

    @Test func locatorUsesLoginShellThenFallbacks() throws {
        let shell = try ClaudeLocator.locate(override: "/custom/claude", loginShellLookup: { "/shell/claude" },
                                             isExecutable: { $0 == "/shell/claude" }, home: home)
        #expect(shell.path == "/shell/claude")
        let local = try ClaudeLocator.locate(override: nil, loginShellLookup: { nil },
                                             isExecutable: { $0 == "/home/me/.local/bin/claude" || $0 == "/usr/local/bin/claude" }, home: home)
        #expect(local.path == "/home/me/.local/bin/claude")
        let brew = try ClaudeLocator.locate(override: nil, loginShellLookup: { nil },
                                            isExecutable: { $0 == "/opt/homebrew/bin/claude" || $0 == "/usr/local/bin/claude" }, home: home)
        #expect(brew.path == "/opt/homebrew/bin/claude")
        let usr = try ClaudeLocator.locate(override: nil, loginShellLookup: { nil },
                                           isExecutable: { $0 == "/usr/local/bin/claude" }, home: home)
        #expect(usr.path == "/usr/local/bin/claude")
    }

    @Test func locatorReportsEverythingTried() {
        #expect(throws: ClaudeNotFound(tried: ["/custom/claude", "/shell/claude", "/home/me/.local/bin/claude",
                                               "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])) {
            try ClaudeLocator.locate(override: "/custom/claude", loginShellLookup: { "/shell/claude" },
                                     isExecutable: { _ in false }, home: home)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ALLOY_LIVE"] == "1"))
    func liveLoginShellLookup() {
        let r = ClaudeLocator.loginShellLookup()
        #expect(r == nil || r!.hasPrefix("/"))
    }

    @Test func parsesTheClaudePathAndPathFromBannerNoise() {
        let out = "Welcome back\n/home/me/.local/bin/claude\n\nALLOY_LOGIN_PATH=/opt/homebrew/bin:/usr/bin\n"
        #expect(ClaudeLocator.parseLoginShellOutput(out)
                == .init(claude: "/home/me/.local/bin/claude", path: "/opt/homebrew/bin:/usr/bin"))
        #expect(ClaudeLocator.parseLoginShellOutput("\nALLOY_LOGIN_PATH=/usr/bin\n") == .init(claude: nil, path: "/usr/bin"))
        #expect(ClaudeLocator.parseLoginShellOutput("") == .init(claude: nil, path: nil))
    }

    @Test func mergePATHPutsLoginEntriesFirstAndKeepsTheRest() {
        #expect(ClaudeLocator.mergePATH(login: "/opt/homebrew/bin:/usr/bin", existing: "/usr/bin:/bin:/sbin")
                == "/opt/homebrew/bin:/usr/bin:/bin:/sbin")
        #expect(ClaudeLocator.mergePATH(login: nil, existing: "/usr/bin") == "/usr/bin")
        #expect(ClaudeLocator.mergePATH(login: "", existing: "/usr/bin") == "/usr/bin")
        #expect(ClaudeLocator.mergePATH(login: "/a", existing: nil) == "/a")
    }
}
