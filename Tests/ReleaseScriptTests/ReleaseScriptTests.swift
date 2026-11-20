import Foundation
import Testing

/// Runs `scripts/release-macos.sh` in a temp git repo (with a local bare `origin`) against stub
/// `xcrun`, `gh`, `hdiutil`, `codesign`, `spctl`, `cp` and `osascript` on PATH that record their argv.
/// Nothing external runs: no notarisation, no real signing, no release, no push.
@Suite(.serialized) struct ReleaseScriptTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Result { var status: Int32; var output: String; var calls: [String]; var tags: [String]; var artefacts: [Data?] }

    /// A temp repo plus stubs. `fail` selects which stubbed step misbehaves (see `stubBodies`).
    final class Fixture {
        let fm = FileManager.default
        let tmp: URL, repo: URL, stubs: URL, log: URL, volumes: URL
        var sparkleBin: URL { tmp.appendingPathComponent("sparkle-bin") }
        var feed: URL { repo.appendingPathComponent("Bench/site/appcast.xml") }
        init(withNotes: Bool = true, notes: String = "# Alloy 0.1.0\nNotes.\n", synced: Bool = true, fail: String = "", existingFeed: String? = nil) throws {
            tmp = fm.temporaryDirectory.appendingPathComponent("alloy-rel-\(UUID().uuidString)")
            repo = tmp.appendingPathComponent("repo"); stubs = tmp.appendingPathComponent("stubs")
            log = tmp.appendingPathComponent("calls.log"); volumes = tmp.appendingPathComponent("volumes")
            let origin = tmp.appendingPathComponent("origin.git")
            try fm.createDirectory(at: volumes, withIntermediateDirectories: true)
            try fm.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            try fm.copyItem(at: ReleaseScriptTests.root.appendingPathComponent("scripts/release-macos.sh"), to: repo.appendingPathComponent("scripts/release-macos.sh"))
            try fm.createDirectory(at: repo.appendingPathComponent("Packaging/macOS"), withIntermediateDirectories: true)
            try fm.copyItem(at: ReleaseScriptTests.root.appendingPathComponent("Packaging/macOS/dmg"), to: repo.appendingPathComponent("Packaging/macOS/dmg"))
            // Fake bundler: records its argv and makes build/Alloy.app.
            try write("#!/bin/sh\necho \"bundle $* identity=${ALLOY_SIGN_IDENTITY:-none}\" >> '\(log.path)'\nmkdir -p build/Alloy.app/Contents/Resources\ntouch build/Alloy.app/Contents/Resources/Alloy.icns\n",
                      to: repo.appendingPathComponent("scripts/bundle-macos.sh"), executable: true)
            if withNotes { try write(notes, to: repo.appendingPathComponent("docs/releases/0.1.0.md")) }
            if let existingFeed { try write(existingFeed, to: repo.appendingPathComponent("Bench/site/appcast.xml")) }
            try write("/build\n/.superpowers/\n", to: repo.appendingPathComponent(".gitignore"))
            try git(["init", "-q", "-b", "master"])
            try git(["add", "-A"]); try git(["commit", "-q", "-m", "init"])
            _ = try sh(["git", "init", "-q", "--bare", origin.path], in: tmp)
            try git(["remote", "add", "origin", origin.path])
            try git(["push", "-q", "origin", "master:main"])
            if synced {
                let (_, head) = try sh(["git", "rev-parse", "HEAD"], in: repo)
                try write(head, to: repo.appendingPathComponent(".superpowers/public-sync-state"))
            }
            try writeStubs(fail: fail)
        }
        deinit { try? fm.removeItem(at: tmp) }

        func git(_ a: [String]) throws {
            let (s, o) = try sh(["git", "-c", "user.name=T", "-c", "user.email=t@example.com"] + a, in: repo)
            #expect(s == 0, "git \(a): \(o)")
        }

        func write(_ text: String, to url: URL, executable: Bool = false) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }

        func sh(_ args: [String], in dir: URL, env: [String: String] = [:], stdin: String? = nil) throws -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = args
            p.currentDirectoryURL = dir
            var e = ProcessInfo.processInfo.environment
            for (k, v) in env { e[k] = v }
            p.environment = e
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            let inp = Pipe(); p.standardInput = inp
            try p.run()
            if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
            try inp.fileHandleForWriting.close()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return (p.terminationStatus, text)
        }

        /// `fail` names the misbehaving step: notaryExit1, notaryInvalid, staple, stapleValidate, spctl, verify,
        /// signDmg, hdiutilCreate, hdiutilAttach, hdiutilConvert, emptyMount, cpApp, gh, ghOnce.
        func writeStubs(fail: String) throws {
            let l = log.path
            func when(_ k: String, _ then: String) -> String { fail == k ? then : "" }
            let notary = fail == "notaryExit1" ? "exit 1"
                : fail == "notaryInvalid" ? "echo '{\"id\":\"abc\",\"status\":\"Invalid\"}'"
                : "echo '{\"id\":\"abc\",\"status\":\"Accepted\"}'"
            let bodies: [String: String] = [
                "xcrun": """
                    #!/bin/sh
                    echo "xcrun $*" >> '\(l)'
                    case "$1" in
                      notarytool) case "$2" in log) echo 'log text';; *) \(notary);; esac ;;
                      stapler) case "$2" in staple) \(when("staple", "exit 1"));; validate) \(when("stapleValidate", "exit 1"));; esac ;;
                    esac
                    exit 0
                    """,
                "gh": """
                    #!/bin/sh
                    echo "gh $*" >> '\(l)'
                    notfound() { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
                    case "$*" in
                      "api repos/"*"/releases/tags/"*) \(fail == "releaseExists" ? "echo '{}'; exit 0" : fail == "apiNetwork" ? "echo 'dial tcp: no such host' >&2; exit 1" : fail == "apiAuth" ? "echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1" : "notfound") ;;
                      "api repos/"*"/git/ref/tags/"*) \(fail == "tagExists" ? "echo '{}'; exit 0" : "notfound") ;;
                      "api --paginate repos/"*"/releases "*) \(fail == "draftExists" ? "echo v0.1.0" : fail == "draftLong" ? "echo v0.1.0; seq -f 'v0.0.%g' 1 40000" : "true") ;;
                      "release create"*) \(when("gh", "exit 1"))
                         \(when("ghInterrupt", "kill -INT $PPID; sleep 1; exit 0"))
                         if [ -f '\(stubs.path)/gh-fail-once' ]; then rm '\(stubs.path)/gh-fail-once'; exit 1; fi ;;
                    esac
                    exit 0
                    """,
                "codesign": """
                    #!/bin/sh
                    echo "codesign $*" >> '\(l)'
                    case "$*" in *--verify*) \(when("verify", "exit 1"));; *--sign*) \(when("signDmg", "exit 1"));; esac
                    exit 0
                    """,
                "spctl": "#!/bin/sh\necho \"spctl $*\" >> '\(l)'\n\(when("spctl", "exit 1"))\n",
                "osascript": "#!/bin/sh\necho \"osascript $*\" >> '\(l)'\nexit 1\n",  // layout failing must stay non-fatal
                "cp": "#!/bin/sh\n\(fail == "cpApp" ? "case \"$*\" in *Alloy.app*) echo 'cp failed' >&2; exit 1;; esac" : "")\nexec /bin/cp \"$@\"\n",
                // The stub emulates just enough of hdiutil: images are directories holding their contents.
                "hdiutil": """
                    #!/bin/sh
                    echo "hdiutil $*" >> '\(l)'
                    cmd=$1; shift
                    case "$cmd" in
                      create)
                        \(when("hdiutilCreate", "exit 1"))
                        src=""; last=""
                        while [ $# -gt 0 ]; do [ "$1" = "-srcfolder" ] && src=$2; last=$1; shift; done
                        mkdir -p "$last.d"; /bin/cp -R "$src/." "$last.d/"; echo rw > "$last" ;;
                      attach)
                        \(when("hdiutilAttach", "exit 1"))
                        img=$1; mnt=""
                        while [ $# -gt 0 ]; do [ "$1" = "-mountpoint" ] && mnt=$2; shift; done
                        mkdir -p "$mnt"
                        \(fail == "emptyMount" ? "true" : "[ -d \"$img.d\" ] && /bin/cp -R \"$img.d/.\" \"$mnt/\"") ;;
                      detach)
                        \(fail == "detachBusy" ? """
                        n=$(cat '\(stubs.path)/detach-count' 2>/dev/null || echo 0); n=$((n+1)); echo $n > '\(stubs.path)/detach-count'
                        if [ $n -le 2 ]; then echo 'hdiutil: Resource busy' >&2; exit 16; fi
                        """ : "")
                        \(fail == "detachForce" ? """
                        case "$*" in *-force*) ;; *) echo 'Resource busy' >&2; exit 16;; esac
                        """ : "")
                        rm -rf "$1" ;;
                      convert)
                        \(when("hdiutilConvert", "exit 1"))
                        in=$1
                        while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out=$2; shift; done
                        mkdir -p "$out.d"; /bin/cp -R "$in.d/." "$out.d/"; echo "dmg-bytes" > "$out" ;;
                    esac
                    exit 0
                    """,
            ]
            for (name, body) in bodies { try write(body + "\n", to: stubs.appendingPathComponent(name), executable: true) }
            // Stub generate_appcast: logs argv and the archive directory, then writes -o with the previous
            // feed (if any) plus one item per DMG, like the real tool's "re-use and update" behaviour.
            try write("""
                #!/bin/sh
                echo "generate_appcast $*" >> '\(l)'
                if [ -f '\(stubs.path)/appcast-fail-once' ]; then rm '\(stubs.path)/appcast-fail-once'; exit 1; fi
                \(when("appcast", "exit 1"))
                out=""; dir=""
                while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out=$2; dir=$1; shift; done
                echo "archives: $(ls "$dir" | tr '\\n' ' ')" >> '\(l)'
                cp "$dir/Alloy-0.1.0.md" '\(stubs.path)/notes.md'
                { [ -f "$out" ] && cat "$out"; for d in "$dir"/*.dmg; do echo "<item>$(basename "$d")</item>"; done; } > "$out.new"
                mv "$out.new" "$out"
                """ + "\n", to: sparkleBin.appendingPathComponent("generate_appcast"), executable: true)
            // Stub generate_keys -p: prints the keychain public key, or fails when there is none.
            try write("#!/bin/sh\necho \"generate_keys $*\" >> '\(l)'\n"
                + (fail == "noKeychainKey" ? "exit 1\n" : "echo \(fail == "keyMismatch" ? "other-public-key" : "test-public-key")\n"),
                to: sparkleBin.appendingPathComponent("generate_keys"), executable: true)
            if fail == "appcastOnce" { try write("", to: stubs.appendingPathComponent("appcast-fail-once")) }
            if fail == "ghOnce" { try write("", to: stubs.appendingPathComponent("gh-fail-once")) }
        }

        func run(args: [String] = ["0.1.0"], answer: String? = "y\n",
                 env: [String: String] = ["ALLOY_SIGN_IDENTITY": "Test Identity", "ALLOY_NOTARY_PROFILE": "test-profile"]) throws -> Result {
            try? fm.removeItem(at: log)
            var e = env
            e["PATH"] = stubs.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            e["ALLOY_VOLUMES_DIR"] = volumes.path
            e["ALLOY_DETACH_DELAY"] = "0"
            if e["ALLOY_SPARKLE_BIN"] == nil { e["ALLOY_SPARKLE_BIN"] = sparkleBin.path }
            if e["ALLOY_SPARKLE_PUBLIC_KEY"] == nil { e["ALLOY_SPARKLE_PUBLIC_KEY"] = "test-public-key" }
            for k in ["ALLOY_SIGN_IDENTITY", "ALLOY_NOTARY_PROFILE"] where env[k] == nil { e[k] = "" }
            let (status, output) = try sh(["bash", "scripts/release-macos.sh"] + args, in: repo, env: e, stdin: answer)
            let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            let (_, tagOut) = try sh(["git", "tag", "--list"], in: repo)
            let artefacts = ["Alloy.dmg", "Alloy-0.1.0.dmg"].map { try? Data(contentsOf: repo.appendingPathComponent("build/release/0.1.0/\($0)")) }
            return Result(status: status, output: output, calls: calls, tags: tagOut.split(separator: "\n").map(String.init), artefacts: artefacts)
        }
    }

    // MARK: required behaviours

    @Test func dryRunNeverPublishes() throws {
        let fx = try Fixture()
        let r = try fx.run(args: ["0.1.0", "--dry-run"], env: ["ALLOY_SIGN_IDENTITY": "Test Identity"])
        #expect(r.status == 0, "\(r.output)")
        #expect(r.tags.isEmpty)
        #expect(!r.calls.contains { $0.hasPrefix("gh ") })
        #expect(!r.calls.contains { $0.contains("notarytool") || $0.contains("stapler") })
        #expect(r.calls.contains { $0.hasPrefix("bundle --version 0.1.0 --build 1 identity=none") }, "\(r.calls)")
        #expect(r.calls.filter { $0.hasPrefix("codesign") && $0.contains("--sign") }.allSatisfy { $0.contains("--sign -") })
    }

    @Test func dmgStagesARetinaBackgroundAndVolumeIcon() throws {
        let fx = try Fixture()
        let r = try fx.run(args: ["0.1.0", "--dry-run"], env: ["ALLOY_SIGN_IDENTITY": "Test Identity"])
        #expect(r.status == 0, "\(r.output)")
        // The stub keeps the finished image's contents next to it as a directory.
        let img = fx.repo.appendingPathComponent("build/release/0.1.0/Alloy.dmg.d")
        #expect(fx.fm.fileExists(atPath: img.appendingPathComponent(".background/background.tiff").path), "background.tiff staged")
        #expect(fx.fm.fileExists(atPath: img.appendingPathComponent(".VolumeIcon.icns").path), ".VolumeIcon.icns staged")
        let script = try String(contentsOf: ReleaseScriptTests.root.appendingPathComponent("Packaging/macOS/dmg/layout.applescript"), encoding: .utf8)
        #expect(script.contains(".background:background.tiff"))
    }

    @Test func backgroundTiffHasBothRepresentations() throws {
        let fx = try Fixture()
        let dir = ReleaseScriptTests.root.appendingPathComponent("Packaging/macOS/dmg")
        let (s, info) = try fx.sh(["tiffutil", "-info", dir.appendingPathComponent("background.tiff").path], in: fx.tmp)
        #expect(s == 0, "\(info)")
        #expect(info.contains("2 directories") || info.components(separatedBy: "Image Width:").count == 3, "two images: \(info)")
        #expect(info.contains("Image Width: 600 Image Length: 400"), "1x representation")
        #expect(info.contains("Image Width: 1200 Image Length: 800"), "2x representation")
        let (_, dpi) = try fx.sh(["sips", "-g", "dpiWidth", dir.appendingPathComponent("background@2x.png").path], in: fx.tmp)
        #expect(dpi.contains("144"), "2x png dpi: \(dpi)")
    }

    @Test func dryRunAllowsPlaceholderNotes() throws {
        let fx = try Fixture(notes: "<!-- PLACEHOLDER -->\n")
        #expect(try fx.run(args: ["0.1.0", "--dry-run"]).status == 0)
    }

    @Test func missingEnvFailsClearly() throws {
        let fx = try Fixture()
        let noIdentity = try fx.run(env: ["ALLOY_NOTARY_PROFILE": "p"])
        #expect(noIdentity.status != 0)
        #expect(noIdentity.output.contains("ALLOY_SIGN_IDENTITY"), "\(noIdentity.output)")
        let noProfile = try fx.run(env: ["ALLOY_SIGN_IDENTITY": "id"])
        #expect(noProfile.status != 0)
        #expect(noProfile.output.contains("ALLOY_NOTARY_PROFILE"), "\(noProfile.output)")
        #expect(noIdentity.calls.isEmpty && noProfile.calls.isEmpty)
    }

    @Test func missingNotesStopsBeforeAnythingExternal() throws {
        let r = try Fixture(withNotes: false).run()
        #expect(r.status != 0)
        #expect(r.output.contains("docs/releases/0.1.0.md"), "\(r.output)")
        #expect(r.calls.isEmpty && r.tags.isEmpty)
    }

    @Test func placeholderNotesRefusePublishing() throws {
        let r = try Fixture(notes: "# x\n<!-- PLACEHOLDER -->\n").run()
        #expect(r.status != 0)
        #expect(r.output.contains("PLACEHOLDER"), "\(r.output)")
        #expect(r.calls.isEmpty)
    }

    @Test func unsyncedPublicRepoStopsRelease() throws {
        let r = try Fixture(synced: false).run()
        #expect(r.status != 0)
        #expect(r.output.contains("publish-public.sh"), "\(r.output)")
        #expect(r.output.contains("already up to date"), "message explains the stale-marker case: \(r.output)")
        #expect(r.calls.isEmpty && r.tags.isEmpty)
    }

    @Test func answerNoPublishesNothing() throws {
        let r = try Fixture().run(answer: "n\n")
        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("Publish v0.1.0? [y/N]"))
        #expect(r.tags.isEmpty)
        #expect(!r.calls.contains { $0.hasPrefix("gh release create") })
    }

    @Test func publishUploadsStableAndVersionedDMG() throws {
        let r = try Fixture().run()
        #expect(r.status == 0, "\(r.output)")
        #expect(r.tags.isEmpty, "no local private tag: gh creates it on the public repo")
        let gh = try #require(r.calls.first { $0.hasPrefix("gh release create") }, "\(r.calls)")
        #expect(gh.contains("v0.1.0 -R mburger89/Alloy --target main"))
        #expect(gh.contains("--notes-file docs/releases/0.1.0.md"))
        #expect(gh.contains("build/release/0.1.0/Alloy.dmg"))
        #expect(gh.contains("build/release/0.1.0/Alloy-0.1.0.dmg"))
        let notarised = r.calls.filter { $0.contains("notarytool submit") }
        #expect(notarised.count == 2 && notarised.allSatisfy { $0.contains("--keychain-profile test-profile --wait --output-format json") })
        #expect(r.calls.filter { $0.contains("stapler staple") }.count == 2)
        #expect(r.calls.contains { $0.hasPrefix("spctl -a -t open --context context:primary-signature -vv") })
        #expect(r.calls.contains { $0.hasPrefix("spctl -a -t exec -vv") }, "app inside the finished DMG is assessed")
        #expect(r.calls.contains { $0.contains("stapler validate") })
        #expect(r.calls.contains { $0.contains("hdiutil attach") && $0.contains("-readonly") })
        #expect(r.calls.filter { $0.hasPrefix("codesign --verify --deep --strict") }.count >= 2)
        let ghIndex = try #require(r.calls.firstIndex { $0.hasPrefix("gh release create") })
        #expect(r.calls.lastIndex { $0.contains("stapler") }! < ghIndex)
        // Layout needs the volume visible to Finder.
        let attachRW = try #require(r.calls.first { $0.hasPrefix("hdiutil attach") && !$0.contains("-readonly") })
        #expect(!attachRW.contains("-nobrowse"), "\(attachRW)")
        #expect(r.artefacts.count == 2 && r.artefacts[0] != nil && r.artefacts[0] == r.artefacts[1])
    }

    // MARK: appcast (Task 3)

    @Test func appcastStepWritesSiteFeed() throws {
        let fx = try Fixture(notes: "# Alloy 0.1.0\n\n- Fast <start> & **bold**\n", existingFeed: "<old/>\n")
        let r = try fx.run()
        #expect(r.status == 0, "\(r.output)")
        let gh = try #require(r.calls.firstIndex { $0.hasPrefix("gh release create") })
        let gen = try #require(r.calls.firstIndex { $0.hasPrefix("generate_appcast") }, "\(r.calls)")
        #expect(gh < gen, "the appcast is generated only after the release is public")
        let argv = r.calls[gen]
        #expect(argv.contains("--download-url-prefix https://github.com/mburger89/Alloy/releases/download/v0.1.0/"), "\(argv)")
        #expect(argv.contains("-o "), "\(argv)")
        // Only this version's DMG (stable name excluded) and its notes go to the tool, never the key.
        let archives = try #require(r.calls.first { $0.hasPrefix("archives:") })
        #expect(archives.contains("Alloy-0.1.0.dmg") && archives.contains("Alloy-0.1.0.md") && archives.contains("appcast.xml"), "\(archives)")
        #expect(!archives.contains("Alloy.dmg"), "\(archives)")
        for forbidden in ["--ed-key-file", " -s ", "-f ", "PRIVATE"] { #expect(!argv.contains(forbidden), "\(argv)") }
        let feed = try String(contentsOf: fx.feed, encoding: .utf8)
        #expect(feed.contains("<old/>") && feed.contains("<item>Alloy-0.1.0.dmg</item>"), "earlier entries kept: \(feed)")
        #expect(argv.contains("--embed-release-notes"), "\(argv)")
        let notes = try String(contentsOf: fx.stubs.appendingPathComponent("notes.md"), encoding: .utf8)
        #expect(notes == "# Alloy 0.1.0\n\n- Fast <start> & **bold**\n", "\(notes)")
    }

    @Test func missingGenerateAppcastStopsBeforePublishing() throws {
        let fx = try Fixture()
        let r = try fx.run(env: ["ALLOY_SIGN_IDENTITY": "i", "ALLOY_NOTARY_PROFILE": "p", "ALLOY_SPARKLE_BIN": fx.tmp.appendingPathComponent("nope").path])
        #expect(r.status != 0)
        #expect(r.output.contains("generate_appcast not found") && r.output.contains("ALLOY_SPARKLE_BIN"), "\(r.output)")
        #expect(r.calls.isEmpty)
    }

    @Test func missingSparklePublicKeyStopsBeforePublishing() throws {
        let fx = try Fixture()
        let r = try fx.run(env: ["ALLOY_SIGN_IDENTITY": "i", "ALLOY_NOTARY_PROFILE": "p", "ALLOY_SPARKLE_PUBLIC_KEY": ""])
        #expect(r.status != 0)
        #expect(r.output.contains("ALLOY_SPARKLE_PUBLIC_KEY"), "\(r.output)")
        #expect(r.calls.isEmpty)
    }

    @Test(arguments: [
        ("keyMismatch", "does not match"), ("noKeychainKey", "no Sparkle EdDSA key"),
    ])
    func sparkleKeyMismatchOrMissingStopsBeforeAnythingExternal(fail: String, message: String) throws {
        let r = try Fixture(fail: fail).run()
        #expect(r.status != 0)
        #expect(r.output.contains(message), "\(r.output)")
        #expect(!r.calls.contains { $0.hasPrefix("gh release") || $0.hasPrefix("bundle") || $0.contains("notarytool") }, "\(r.calls)")
    }

    @Test func matchingSparkleKeyIsCheckedViaGenerateKeys() throws {
        let r = try Fixture().run()
        #expect(r.status == 0, "\(r.output)")
        let keys = try #require(r.calls.firstIndex { $0 == "generate_keys -p" }, "\(r.calls)")
        #expect(keys < (try #require(r.calls.firstIndex { $0.hasPrefix("bundle") })))
    }

    @Test func failedAppcastAfterPublishCanBeRerunWithAppcastOnly() throws {
        let fx = try Fixture(fail: "appcastOnce")
        let first = try fx.run()
        #expect(first.status != 0)
        #expect(first.output.contains("PUBLIC") && first.output.contains("--appcast-only"), "\(first.output)")
        #expect(!first.calls.contains { $0.hasPrefix("gh release delete") }, "a public release is never removed: \(first.calls)")
        #expect(!FileManager.default.fileExists(atPath: fx.feed.path), "failed run leaves no feed")
        let again = try fx.run(args: ["0.1.0", "--appcast-only"], answer: nil)
        #expect(again.status == 0, "\(again.output)")
        // Only the appcast ran: nothing was bundled, notarised or published.
        #expect(again.calls.allSatisfy { $0.hasPrefix("generate_appcast") || $0.hasPrefix("archives:") || $0 == "generate_keys -p" }, "\(again.calls)")
        #expect(try String(contentsOf: fx.feed, encoding: .utf8).contains("Alloy-0.1.0.dmg"))
        // Repeating is safe: the feed is regenerated from the previous one.
        let third = try fx.run(args: ["0.1.0", "--appcast-only"], answer: nil)
        #expect(third.status == 0, "\(third.output)")
    }

    @Test func appcastOnlyWithoutArtefactsFails() throws {
        let r = try Fixture().run(args: ["0.1.0", "--appcast-only"], answer: nil)
        #expect(r.status != 0)
        #expect(r.output.contains("appcast"), "\(r.output)")
    }

    @Test func uppercaseYPublishes() throws {
        let r = try Fixture().run(answer: "Y")
        #expect(r.calls.contains { $0.hasPrefix("gh release create") }, "\(r.output)")
    }

    // MARK: failures stop before publishing and name the step

    @Test(arguments: [
        ("notaryExit1", "notarise app"), ("notaryInvalid", "notarise app"), ("staple", "staple app"),
        ("hdiutilCreate", "build dmg"), ("hdiutilAttach", "build dmg"), ("hdiutilConvert", "build dmg"),
        ("cpApp", "build dmg"), ("emptyMount", "build dmg"), ("signDmg", "sign dmg"),
        ("spctl", "verify dmg (spctl)"), ("verify", "verify dmg signature"), ("stapleValidate", "verify app inside dmg"),
        ("gh", "gh release create"),
    ])
    func failureStopsBeforePublishing(fail: String, step: String) throws {
        let fx = try Fixture(fail: fail)
        let r = try fx.run()
        #expect(r.status != 0, "\(fail): \(r.output)")
        #expect(r.output.contains(step), "\(fail) should name '\(step)': \(r.output)")
        #expect(r.tags.isEmpty)
        if fail != "gh" { #expect(!r.calls.contains { $0.hasPrefix("gh release create") }, "\(fail): \(r.calls)") }
    }

    @Test func invalidNotarisationPrintsNotaryLog() throws {
        let r = try Fixture(fail: "notaryInvalid").run()
        #expect(r.calls.contains { $0.contains("notarytool log abc --keychain-profile test-profile") }, "\(r.calls)")
        #expect(r.output.contains("Invalid"), "\(r.output)")
        #expect(!r.calls.contains { $0.contains("stapler") })
    }

    @Test func failedUploadIsRetryable() throws {
        let fx = try Fixture(fail: "ghOnce")
        let first = try fx.run()
        #expect(first.status != 0)
        #expect(first.tags.isEmpty)
        #expect(first.calls.contains { $0.hasPrefix("gh release delete v0.1.0 -R mburger89/Alloy --cleanup-tag") }, "partial release removed: \(first.calls)")
        let second = try fx.run()
        #expect(second.status == 0, "\(second.output)")
        #expect(second.calls.contains { $0.hasPrefix("gh release create") })
        #expect(second.tags.isEmpty)
    }

    @Test(arguments: [
        ("releaseExists", "already exists"), ("tagExists", "tag v0.1.0 already exists"),
        ("draftExists", "(draft) release"), ("apiNetwork", "not a 404"), ("apiAuth", "not a 404"),
    ])
    func uncertainOrExistingRemoteStateStopsBeforeAnythingExternal(fail: String, message: String) throws {
        let r = try Fixture(fail: fail).run()
        #expect(r.status != 0, "\(fail): \(r.output)")
        #expect(r.output.contains(message), "\(fail): \(r.output)")
        #expect(!r.calls.contains { $0.hasPrefix("gh release") || $0.hasPrefix("bundle") || $0.contains("notarytool") }, "\(fail): \(r.calls)")
    }

    // MARK: detach retry, draft check, interrupted upload

    @Test func busyDetachIsRetriedThenSucceeds() throws {
        let fx = try Fixture(fail: "detachBusy")
        let r = try fx.run(args: ["0.1.0", "--dry-run"])
        #expect(r.status == 0, "\(r.output)")
        let mnt = fx.volumes.appendingPathComponent("Alloy").path
        let detaches = r.calls.filter { $0.hasPrefix("hdiutil detach \(mnt)") }
        #expect(detaches.count == 3, "two busy failures, then success: \(detaches)")
        #expect(!detaches.contains { $0.contains("-force") }, "\(detaches)")
        #expect(r.calls.contains { $0.hasPrefix("hdiutil convert") })
    }

    @Test func detachThatStaysBusyIsForcedAsLastResort() throws {
        let fx = try Fixture(fail: "detachForce")
        let r = try fx.run(args: ["0.1.0", "--dry-run"])
        #expect(r.status == 0, "\(r.output)")
        let mnt = fx.volumes.appendingPathComponent("Alloy").path
        let detaches = r.calls.filter { $0.hasPrefix("hdiutil detach \(mnt)") }
        #expect(detaches.count == 6, "\(detaches)")
        #expect(detaches.dropLast().allSatisfy { !$0.contains("-force") } && detaches.last?.contains("-force") == true, "\(detaches)")
    }

    @Test func draftCheckSurvivesALongListing() throws {
        let r = try Fixture(fail: "draftLong").run()
        #expect(r.status != 0, "\(r.output)")
        #expect(r.output.contains("(draft) release"), "\(r.output)")
        #expect(!r.calls.contains { $0.hasPrefix("gh release create") || $0.hasPrefix("bundle") })
    }

    @Test func interruptedUploadNamesTheCleanupCommandAndDeletesNothing() throws {
        let fx = try Fixture(fail: "ghInterrupt")
        let r = try fx.run()
        #expect(r.status == 130, "\(r.status) \(r.output)")
        let hint = "gh release delete v0.1.0 -R mburger89/Alloy --cleanup-tag"
        #expect(r.output.contains(hint), "\(r.output)")
        #expect(!r.calls.contains { $0.hasPrefix("gh release delete") }, "the script must not delete on an interrupt: \(r.calls)")
        #expect(!r.calls.contains { $0.hasPrefix("generate_appcast") })
    }

    @Test(arguments: ["releaseExists", "draftExists"])
    func existingReleaseMessageNamesTheCleanupCommand(fail: String) throws {
        let r = try Fixture(fail: fail).run()
        #expect(r.status != 0)
        #expect(r.output.contains("gh release delete v0.1.0 -R mburger89/Alloy --cleanup-tag"), "\(r.output)")
    }

    // MARK: cleanup

    @Test func failureAfterAttachDetachesImageAndRemovesScratch() throws {
        let fx = try Fixture(fail: "emptyMount")
        let r = try fx.run()
        #expect(r.status != 0)
        let mnt = fx.volumes.appendingPathComponent("Alloy").path
        let attach = try #require(r.calls.firstIndex { $0.hasPrefix("hdiutil attach") && $0.contains("-mountpoint \(mnt)") }, "\(r.calls) \(r.output)")
        let detach = try #require(r.calls.firstIndex { $0.hasPrefix("hdiutil detach \(mnt)") }, "image must be detached on failure: \(r.calls)")
        #expect(attach < detach)
        #expect(!r.calls.contains { $0.contains("notarytool submit") && $0.contains("Alloy.dmg") })
    }
}
