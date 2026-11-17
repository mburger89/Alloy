#if !os(Windows)

import AlloyCore
import AlloyTerminal
import Testing

struct TerminalLaunchTests {
    private func plan(shell: String? = nil, env: [String: String] = [:], pane: String? = nil,
                      root: String = "/proj", home: String = "/home/u",
                      executable: Set<String> = ["/bin/zsh", "/bin/sh", "/opt/fish"],
                      dirs: Set<String> = ["/proj", "/home/u", "/pane"]) -> TerminalLaunch {
        TerminalLaunchPlanner.plan(settings: TerminalSettings(shellPath: shell), environment: env, paneCwd: pane,
                                   projectRoot: root, home: home,
                                   isExecutable: { executable.contains($0) }, isDirectory: { dirs.contains($0) })
    }

    @Test func usesConfiguredShellThenSHELLThenZsh() {
        #expect(plan(shell: "/opt/fish", env: ["SHELL": "/bin/sh"]).executable == "/opt/fish")
        #expect(plan(env: ["SHELL": "/bin/sh"]).executable == "/bin/sh")
        #expect(plan().executable == "/bin/zsh")
        #expect(plan().notices.isEmpty)
    }

    @Test func loginShellGetsDashedArgv0() {
        let launch = plan()
        #expect(launch.executable == "/bin/zsh")
        #expect(launch.argv == ["-zsh"])
    }

    @Test func missingShellFallsBackToZshThenShWithNotice() {
        let toZsh = plan(shell: "/nope/bash")
        #expect(toZsh.executable == "/bin/zsh")
        #expect(toZsh.notices.count == 1)
        #expect(toZsh.notices[0].contains("/nope/bash") && toZsh.notices[0].contains("/bin/zsh"))
        let toSh = plan(shell: "/nope/bash", executable: ["/bin/sh"])
        #expect(toSh.executable == "/bin/sh")
        #expect(toSh.argv == ["-sh"])
        #expect(toSh.notices.count == 1)
    }

    @Test func envSetsTermColortermAndScrubsAlloyVariables() {
        let env = plan(env: ["ALLOY_TOKEN": "s", "ALLOY_X": "1", "PATH": "/usr/bin", "HOME": "/home/u",
                             "TERM": "dumb"]).env
        #expect(env["ALLOY_TOKEN"] == nil && env["ALLOY_X"] == nil)
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["PATH"] == "/usr/bin" && env["HOME"] == "/home/u")
    }

    @Test func nonUTF8LocaleForcesUTF8Lang() {
        let c = plan(env: ["LC_ALL": "C", "LC_CTYPE": "C", "LANG": "C"]).env
        #expect(c["LANG"] == "en_US.UTF-8" && c["LC_ALL"] == nil && c["LC_CTYPE"] == nil)
        let latin = plan(env: ["LANG": "en_US.ISO8859-1"]).env
        #expect(latin["LANG"] == "en_US.UTF-8")
        // LC_ALL wins over a UTF-8 LANG.
        let override = plan(env: ["LC_ALL": "C", "LANG": "de_DE.UTF-8"]).env
        #expect(override["LANG"] == "en_US.UTF-8" && override["LC_ALL"] == nil)
    }

    @Test func utf8LocaleIsKept() {
        #expect(plan(env: ["LANG": "de_DE.UTF-8"]).env["LANG"] == "de_DE.UTF-8")
        #expect(plan(env: ["LANG": "de_DE.utf8"]).env["LANG"] == "de_DE.utf8")
        #expect(plan(env: ["LC_ALL": "en_GB.Utf-8", "LANG": "C"]).env["LC_ALL"] == "en_GB.Utf-8")
    }

    @Test func emptyLocaleForcesUTF8() {
        #expect(plan().env["LANG"] == "en_US.UTF-8")
        #expect(plan(env: ["LANG": ""]).env["LANG"] == "en_US.UTF-8")
    }

    @Test func cwdPrefersPaneCwdThenProjectRoot() {
        #expect(plan(pane: "/pane").cwd == "/pane")
        #expect(plan(pane: "/pane").notices.isEmpty)
        #expect(plan(pane: nil).cwd == "/proj")
        #expect(plan(pane: nil).notices.isEmpty)
    }

    @Test func missingCwdFallsBackToHomeWithNotice() {
        let both = plan(pane: "/gone", dirs: ["/home/u"])
        #expect(both.cwd == "/home/u")
        #expect(both.notices.count == 1 && both.notices[0].contains("/gone"))
        let toRoot = plan(pane: "/gone")
        #expect(toRoot.cwd == "/proj")
        #expect(toRoot.notices.count == 1)
    }
}

#endif
