import Foundation
import Testing

/// Reads the packaging files and runs `scripts/bundle-macos.sh` in a temp copy with a stub `swift`
/// (no build, no network), so only the bundling and signing steps are exercised.
@Suite(.serialized) struct PackagingTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func plist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func bundleIdentifierIsUnicornLabs() throws {
        let info = try plist(Self.root.appendingPathComponent("Packaging/macOS/Info.plist"))
        #expect(info["CFBundleIdentifier"] as? String == "com.unicornlabs.Alloy")
    }

    @Test func entitlementsAreMinimal() throws {
        let ent = try plist(Self.root.appendingPathComponent("Packaging/macOS/Alloy.entitlements"))
        // Not sandboxed, loads only its own (and later Sparkle's, same-identity) code, no JIT.
        #expect(ent.isEmpty, "unexpected entitlements: \(ent.keys.sorted())")
        #expect(ent["com.apple.security.cs.disable-library-validation"] == nil)
        #expect(ent["com.apple.security.app-sandbox"] == nil)
    }

    @Test func bundleScriptAcceptsVersion() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("alloy-pkg-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let repo = tmp.appendingPathComponent("repo")
        try fm.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("Packaging"), withIntermediateDirectories: true)
        try fm.copyItem(at: Self.root.appendingPathComponent("scripts/bundle-macos.sh"),
                        to: repo.appendingPathComponent("scripts/bundle-macos.sh"))
        try fm.copyItem(at: Self.root.appendingPathComponent("Packaging/macOS"),
                        to: repo.appendingPathComponent("Packaging/macOS"))

        // Stub toolchain: `swift build ... --show-bin-path` prints a dir holding a signed-able Mach-O.
        let bin = tmp.appendingPathComponent("bin-out")
        try fm.createDirectory(at: bin.appendingPathComponent("MetalUI_MetalUIRender.bundle"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bin.appendingPathComponent("TreeSitterRust_TreeSitterRust.bundle/Contents/Resources/queries"), withIntermediateDirectories: true)
        try Data().write(to: bin.appendingPathComponent("TreeSitterRust_TreeSitterRust.bundle/Contents/Resources/queries/highlights.scm"))
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: bin.appendingPathComponent("Alloy"))
        let stubs = tmp.appendingPathComponent("stubs")
        try fm.createDirectory(at: stubs, withIntermediateDirectories: true)
        let stub = stubs.appendingPathComponent("swift")
        try "#!/bin/sh\ncase \"$*\" in *--show-bin-path*) echo '\(bin.path)';; esac\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["scripts/bundle-macos.sh", "--version", "0.2.3", "--build", "7"]
        p.currentDirectoryURL = repo
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = stubs.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["ALLOY_SIGN_IDENTITY"] = nil
        env["CODESIGN_IDENTITY"] = nil
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let log = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(log)")

        let app = repo.appendingPathComponent("build/Alloy.app")
        let info = try plist(app.appendingPathComponent("Contents/Info.plist"))
        #expect(info["CFBundleShortVersionString"] as? String == "0.2.3")
        #expect(info["CFBundleVersion"] as? String == "7")
        #expect(info["CFBundleIdentifier"] as? String == "com.unicornlabs.Alloy")

        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", app.path]
        try verify.run()
        verify.waitUntilExit()
        #expect(verify.terminationStatus == 0)
    }

    /// A temp repo with the bundle script, a stub `swift` and a fake framework (main binary, helper, nested XPC service
    /// and a symlinked Updater.app), plus a stub `codesign` that logs its argv and fails on the call numbers in `failOn`.
    private struct SigningFixture {
        let fm = FileManager.default
        let tmp: URL, repo: URL, log: URL, stubs: URL
        init(failOnSign: Int? = nil) throws {
            tmp = fm.temporaryDirectory.appendingPathComponent("alloy-pkg-\(UUID().uuidString)")
            repo = tmp.appendingPathComponent("repo")
            try fm.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            try fm.createDirectory(at: repo.appendingPathComponent("Packaging"), withIntermediateDirectories: true)
            try fm.copyItem(at: PackagingTests.root.appendingPathComponent("scripts/bundle-macos.sh"),
                            to: repo.appendingPathComponent("scripts/bundle-macos.sh"))
            try fm.copyItem(at: PackagingTests.root.appendingPathComponent("Packaging/macOS"),
                            to: repo.appendingPathComponent("Packaging/macOS"))

            let bin = tmp.appendingPathComponent("bin-out")
            try fm.createDirectory(at: bin.appendingPathComponent("MetalUI_MetalUIRender.bundle"), withIntermediateDirectories: true)
            try fm.createDirectory(at: bin.appendingPathComponent("TreeSitterRust_TreeSitterRust.bundle/Contents/Resources/queries"), withIntermediateDirectories: true)
            try Data().write(to: bin.appendingPathComponent("TreeSitterRust_TreeSitterRust.bundle/Contents/Resources/queries/highlights.scm"))
            try "x".write(to: bin.appendingPathComponent("Alloy"), atomically: true, encoding: .utf8)
            // Fake framework: main binary, helper, nested XPC service.
            let ver = bin.appendingPathComponent("Fake.framework/Versions/A")
            let xpcExe = ver.appendingPathComponent("XPCServices/Svc.xpc/Contents/MacOS")
            try fm.createDirectory(at: xpcExe, withIntermediateDirectories: true)
            // An .app helper reachable twice, like Sparkle's Updater.app: real dir plus a top-level symlink.
            let helperExe = ver.appendingPathComponent("Updater.app/Contents/MacOS")
            try fm.createDirectory(at: helperExe, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: bin.appendingPathComponent("Fake.framework/Updater.app"), withDestinationURL: URL(fileURLWithPath: "Versions/A/Updater.app"))
            for f in [ver.appendingPathComponent("Fake"), ver.appendingPathComponent("Helper"), xpcExe.appendingPathComponent("Svc"), helperExe.appendingPathComponent("Up")] {
                try "x".write(to: f, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
            }

            stubs = tmp.appendingPathComponent("stubs")
            log = tmp.appendingPathComponent("codesign.log")
            try fm.createDirectory(at: stubs, withIntermediateDirectories: true)
            let count = tmp.appendingPathComponent("sign-count")
            // With `failOnSign: n` the n-th signing call fails (verification calls never do).
            let failure = failOnSign.map { "case \"$*\" in *--sign*) n=$(cat '\(count.path)' 2>/dev/null || echo 0); n=$((n+1)); echo $n > '\(count.path)'; if [ $n -eq \($0) ]; then echo 'codesign stub: failing' >&2; exit 1; fi;; esac\nexit 0\n" } ?? ""
            let scripts = [
                "swift": "#!/bin/sh\ncase \"$*\" in *--show-bin-path*) echo '\(bin.path)';; esac\n",
                "codesign": "#!/bin/sh\necho \"$*\" >> '\(log.path)'\n" + failure,
            ]
            for (name, body) in scripts {
                let u = stubs.appendingPathComponent(name)
                try body.write(to: u, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
            }
        }

        func run() throws -> (status: Int32, output: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["scripts/bundle-macos.sh", "--version", "0.2.3", "--build", "7"]
            p.currentDirectoryURL = repo
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = stubs.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            env["ALLOY_SIGN_IDENTITY"] = "Test Identity"
            env["ALLOY_SPARKLE_PUBLIC_KEY"] = "test-public-key"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return (p.terminationStatus, output)
        }
    }

    @Test func nestedSignFailureFailsTheScript() throws {
        // Sign order: two nested bundles, two executables, the framework, the app. Fail the second nested one.
        let fx = try SigningFixture(failOnSign: 2)
        defer { try? fx.fm.removeItem(at: fx.tmp) }
        let r = try fx.run()
        #expect(r.status != 0, "a failing nested codesign must fail the bundler: \(r.output)")
        #expect(r.output.contains("codesign failed for"), "\(r.output)")
        let calls = try String(contentsOf: fx.log, encoding: .utf8).split(separator: "\n")
        #expect(calls.filter { $0.contains("--sign") }.count == 2, "nothing is signed after the failure: \(calls)")
    }

    @Test func nestedExecutableSignFailureFailsTheScript() throws {
        let fx = try SigningFixture(failOnSign: 3)
        defer { try? fx.fm.removeItem(at: fx.tmp) }
        let r = try fx.run()
        #expect(r.status != 0, "\(r.output)")
        #expect(r.output.contains("codesign failed for"), "\(r.output)")
    }

    @Test func identitySigningUsesHardenedRuntimeInsideOut() throws {
        let fx = try SigningFixture()
        defer { try? fx.fm.removeItem(at: fx.tmp) }
        let repo = fx.repo, log = fx.log
        let r = try fx.run()
        #expect(r.status == 0, "\(r.output)")
        let info = try plist(repo.appendingPathComponent("build/Alloy.app/Contents/Info.plist"))
        #expect(info["AlloyReleaseBuild"] as? Bool == true, "identity-signed builds are marked as release builds")

        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        let signs = calls.filter { $0.contains("--sign") }
        #expect(signs.count == 6, "\(signs)")
        #expect(signs.filter { $0.hasSuffix("Updater.app") }.count == 1, "symlinked .app is signed once, by its real path: \(signs)")
        #expect(signs.filter { $0.hasSuffix("Updater.app") }.first?.contains("Versions/A/Updater.app") == true, "\(signs)")
        for c in signs {
            #expect(c.contains("--force --sign Test Identity --options runtime --timestamp"), "\(c)")
            #expect(!c.contains("--deep"), "\(c)")
        }
        // The nested bundles (XPC, Updater.app) come first in either order, then the executables
        // (Fake, Helper) in either order, then the framework, then the app.
        func index(_ s: String) -> Int? { signs.firstIndex { $0.hasSuffix(s) } }
        let nested = try ["Svc.xpc", "Versions/A/Updater.app"].map { try #require(index($0), "missing \($0) in \(signs)") }
        let exes = try ["Versions/A/Fake", "Versions/A/Helper"].map { try #require(index($0), "missing \($0) in \(signs)") }
        #expect(Set(nested) == [0, 1] && Set(exes) == [2, 3], "\(signs)")
        #expect(index("Fake.framework") == 4 && index("Alloy.app") == 5)
        for (i, c) in signs.enumerated() {
            #expect(c.contains("--entitlements Packaging/macOS/Alloy.entitlements") == (i == 5), "\(c)")
        }
        #expect(calls.contains { $0.contains("--verify") })
    }

    // MARK: Sparkle (Task 3)

    @Test func infoPlistHasSparkleKeys() throws {
        let info = try plist(Self.root.appendingPathComponent("Packaging/macOS/Info.plist"))
        #expect(info["SUFeedURL"] as? String == "https://mburger89.github.io/Alloy/appcast.xml")
        #expect(info["SUEnableSystemProfiling"] as? Bool == false)
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUScheduledCheckInterval"] as? Int == 86400)
        #expect(info["SUPublicEDKey"] as? String == "REPLACE_AT_BUNDLE_TIME")
    }

    /// A temp repo with the bundle script, a stub `swift` and a bin dir holding a stub executable
    /// (plus the real Sparkle.framework from SwiftPM's artifacts when `withSparkle`).
    private struct BundleFixture {
        let fm = FileManager.default
        let tmp: URL, repo: URL, bin: URL, stubs: URL
        init(withSparkle: Bool) throws {
            tmp = fm.temporaryDirectory.appendingPathComponent("alloy-pkg-\(UUID().uuidString)")
            repo = tmp.appendingPathComponent("repo"); bin = tmp.appendingPathComponent("bin-out"); stubs = tmp.appendingPathComponent("stubs")
            try fm.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            try fm.createDirectory(at: repo.appendingPathComponent("Packaging"), withIntermediateDirectories: true)
            try fm.copyItem(at: PackagingTests.root.appendingPathComponent("scripts/bundle-macos.sh"), to: repo.appendingPathComponent("scripts/bundle-macos.sh"))
            try fm.copyItem(at: PackagingTests.root.appendingPathComponent("Packaging/macOS"), to: repo.appendingPathComponent("Packaging/macOS"))
            try fm.createDirectory(at: bin.appendingPathComponent("MetalUI_MetalUIRender.bundle"), withIntermediateDirectories: true)
            try fm.createDirectory(at: bin.appendingPathComponent("TreeSitterRust_TreeSitterRust.bundle/Contents/Resources/queries"), withIntermediateDirectories: true)
            try Data().write(to: bin.appendingPathComponent("TreeSitterRust_TreeSitterRust.bundle/Contents/Resources/queries/highlights.scm"))
            try fm.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: bin.appendingPathComponent("Alloy"))
            if withSparkle { try fm.copyItem(at: PackagingTests.sparkleFramework!, to: bin.appendingPathComponent("Sparkle.framework")) }
            try fm.createDirectory(at: stubs, withIntermediateDirectories: true)
            let stub = stubs.appendingPathComponent("swift")
            try "#!/bin/sh\ncase \"$*\" in *--show-bin-path*) echo '\(bin.path)';; esac\n".write(to: stub, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
        func run(env extra: [String: String?]) throws -> (status: Int32, output: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["scripts/bundle-macos.sh", "--version", "0.2.3", "--build", "7"]
            p.currentDirectoryURL = repo
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = stubs.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            env["ALLOY_SIGN_IDENTITY"] = nil; env["CODESIGN_IDENTITY"] = nil; env["ALLOY_SPARKLE_PUBLIC_KEY"] = nil
            for (k, v) in extra { env[k] = v }
            p.environment = env
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            try p.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return (p.terminationStatus, text)
        }
    }

    /// The Sparkle.framework SwiftPM extracted from the pinned binary package (present after any build).
    private static let sparkleFramework: URL? = {
        let url = root.appendingPathComponent(".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    @Test func adHocBundleWithoutPublicKeyDropsPlaceholder() throws {
        let fx = try BundleFixture(withSparkle: false)
        defer { try? fx.fm.removeItem(at: fx.tmp) }
        let r = try fx.run(env: [:])
        #expect(r.status == 0, "\(r.output)")
        let info = try plist(fx.repo.appendingPathComponent("build/Alloy.app/Contents/Info.plist"))
        #expect(info["SUPublicEDKey"] == nil, "invalid placeholder key must not ship")
        #expect(info["AlloyReleaseBuild"] == nil, "ad hoc builds are not release builds")
        #expect(info["SUFeedURL"] != nil)
    }

    @Test func releaseBundleRequiresPublicKey() throws {
        let fx = try BundleFixture(withSparkle: false)
        defer { try? fx.fm.removeItem(at: fx.tmp) }
        let r = try fx.run(env: ["ALLOY_SIGN_IDENTITY": "Test Identity"])
        #expect(r.status != 0)
        #expect(r.output.contains("ALLOY_SPARKLE_PUBLIC_KEY"), "\(r.output)")
        #expect(!fx.fm.fileExists(atPath: fx.repo.appendingPathComponent("build/Alloy.app").path))
    }

    @Test(.enabled(if: PackagingTests.sparkleFramework != nil, "run `swift build` once to fetch Sparkle"))
    func bundleEmbedsSignedSparkle() throws {
        let fx = try BundleFixture(withSparkle: true)
        defer { try? fx.fm.removeItem(at: fx.tmp) }
        let r = try fx.run(env: ["ALLOY_SPARKLE_PUBLIC_KEY": "test-public-key"])
        #expect(r.status == 0, "\(r.output)")
        let app = fx.repo.appendingPathComponent("build/Alloy.app")
        let framework = app.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
        #expect(fx.fm.fileExists(atPath: framework.path))
        // The public key placeholder was replaced.
        let info = try plist(app.appendingPathComponent("Contents/Info.plist"))
        #expect(info["SUPublicEDKey"] as? String == "test-public-key")
        for target in [framework, app] {
            let verify = Process()
            verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            verify.arguments = ["--verify", "--deep", "--strict", target.path]
            let err = Pipe(); verify.standardError = err
            try verify.run()
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            verify.waitUntilExit()
            #expect(verify.terminationStatus == 0, "\(target.lastPathComponent): \(msg)")
        }
    }
}
