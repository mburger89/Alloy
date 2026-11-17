@testable import AlloyCore
import Testing

@Suite struct GitExecutableTests {
    private func resolve(gitPath: String? = nil, path: String = "/opt/bin:/usr/bin", developerDir: Bool = false,
                         executable: Set<String>, xcode: Bool = true, version: String = "git version 2.39.3 (Apple Git-146)") -> GitExecutable.Resolution {
        var env = ["PATH": path]
        if developerDir { env["DEVELOPER_DIR"] = "/x" }
        return GitExecutable.resolve(gitPath: gitPath, environment: env, isExecutable: { executable.contains($0) },
                                     xcodeSelectOK: { xcode }, versionOf: { _ in version })
    }

    @Test func configuredPathWins() {
        let r = resolve(gitPath: "/custom/git", executable: ["/custom/git", "/opt/bin/git"])
        #expect(r == .usable(path: "/custom/git", version: [2, 39, 3]))
    }

    @Test func firstOnPathIsUsed() {
        let r = resolve(executable: ["/opt/bin/git", "/usr/bin/git"])
        #expect(r == .usable(path: "/opt/bin/git", version: [2, 39, 3]))
    }

    @Test func shimNeedsXcodeSelect() {
        #expect(resolve(executable: ["/usr/bin/git"], xcode: false) == .shimWithoutTools)
        #expect(resolve(developerDir: true, executable: ["/usr/bin/git"], xcode: false) == .usable(path: "/usr/bin/git", version: [2, 39, 3]))
    }

    @Test func olderThan2_23IsTooOld() {
        #expect(resolve(executable: ["/opt/bin/git"], version: "git version 2.22.0") == .tooOld("2.22.0"))
        #expect(resolve(executable: ["/opt/bin/git"], version: "git version 2.23.0") == .usable(path: "/opt/bin/git", version: [2, 23, 0]))
    }

    @Test func notFound() {
        #expect(resolve(executable: []) == .notFound)
    }
}
