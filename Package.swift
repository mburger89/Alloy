// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Alloy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Alloy", targets: ["Alloy"]),
        .library(name: "AlloyKit", targets: ["AlloyKit"]),
        .library(name: "AlloyCore", targets: ["AlloyCore"]),
        .library(name: "AlloyHighlight", targets: ["AlloyHighlight"]),
    ],
    dependencies: [
        .package(name: "MetalUI", path: "../MetalUI"),
        // Tree-sitter runtime and grammars, each pinned to an exact version or revision. Python, JavaScript, CSS
        // and YAML are held to the last tags whose manifest lists `src/scanner.c` statically: the newer tags test
        // `FileManager.fileExists("src/scanner.c")` against the build's cwd, which skips the scanner and fails to link.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        // Sparkle 2 updater (binary xcframework). Linked into AlloyKit; Task 4 adds the driver. Exact pin.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        // Swift's repo keeps the generated parser.c only on the `-with-generated-files` tags; pin that tag's revision.
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift",
                 revision: "82bb3a533e0801fd2bbaa11dc49676e10bf41948"),   // 0.7.4-with-generated-files
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.25.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", exact: "0.23.4"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.23.2"),
    ],
    targets: [
        // UI-free logic: wire protocol, sessions, edit ledger.
        .target(name: "AlloyCore", dependencies: [.product(name: "MetalUICodeBuffer", package: "MetalUI")]),
        // Language Server Protocol client: framing, JSON-RPC, sessions. UI-free.
        .target(
            name: "AlloyLSP",
            dependencies: [
                "AlloyCore",
                "AlloyHighlight",
                .product(name: "MetalUICodeBuffer", package: "MetalUI"),
            ]
        ),
        // Agent Client Protocol client: framing, JSON-RPC connection, v1 models, agent process. UI-free.
        .target(name: "AlloyACP", dependencies: ["AlloyCore"]),
        // Test-only scriptable ACP agent (no dependencies; scripted through FAKE_ACP_SCRIPT).
        .executableTarget(name: "AlloyFakeACP"),
        // Test-only scriptable language server. Not a product: the test targets depend on it, so SwiftPM always builds it.
        .executableTarget(name: "AlloyFakeLSP", dependencies: ["AlloyCore", "AlloyLSP"]),
        // Shared helpers of the tests that run the fake server (its path, polling, launch and result collectors).
        .target(name: "AlloyLSPTestSupport", dependencies: ["AlloyLSP"]),
        // Test doubles shared by the test targets.
        .target(
            name: "AlloyTestSupport",
            dependencies: ["AlloyCore", "AlloyTerminal", .product(name: "MetalUITerminal", package: "MetalUI")]
        ),
        // Real shells behind the terminal panel: the pty seam, sessions, manager. UI-free.
        .target(name: "AlloyTerminal", dependencies: ["AlloyCore", .product(name: "MetalUITerminal", package: "MetalUI")]),
        // Tree-sitter highlighting for CodeView and chat code fences.
        .target(
            name: "AlloyHighlight",
            dependencies: [
                "AlloyCore",
                .product(name: "MetalUI", package: "MetalUI"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
            ]
        ),
        // Everything but the entry point, so a test imports it plainly.
        .target(
            name: "AlloyKit",
            dependencies: [
                "AlloyCore",
                "AlloyHighlight",
                "AlloyLSP",
                "AlloyTerminal",
                .product(name: "MetalUI", package: "MetalUI"),
                .product(name: "MetalUIMarkdown", package: "MetalUI"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MetalUITerminalUI", package: "MetalUI"),
            ]
        ),
        .executableTarget(
            name: "Alloy",
            dependencies: [
                "AlloyKit",
                "AlloyACP",
                .product(name: "MetalUI", package: "MetalUI"),
            ],
            // Sparkle.framework lives in Alloy.app/Contents/Frameworks (scripts/bundle-macos.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "AlloyCoreTests",
            dependencies: ["AlloyCore", "AlloyTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AlloyACPTests",
            dependencies: ["AlloyACP", "AlloyCore", "AlloyFakeACP", "AlloyTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AlloyLSPTests",
            dependencies: ["AlloyLSP", "AlloyCore", "AlloyLSPTestSupport", "AlloyFakeLSP",
                           .product(name: "MetalUICodeBuffer", package: "MetalUI")]
        ),
        .testTarget(
            name: "AlloyHighlightTests",
            dependencies: [
                "AlloyHighlight",
                "AlloyCore",
                .product(name: "MetalUICodeBuffer", package: "MetalUI"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "MetalUI", package: "MetalUI"),
                .product(name: "MetalUITesting", package: "MetalUI"),
            ]
        ),
        .testTarget(
            name: "AlloyTerminalTests",
            dependencies: ["AlloyTerminal", "AlloyCore", "AlloyTestSupport",
                           .product(name: "MetalUITerminal", package: "MetalUI")]
        ),
        .testTarget(
            name: "AlloyKitTests",
            dependencies: [
                "AlloyKit",
                "AlloyTerminal",
                "AlloyLSP",
                "AlloyTestSupport",
                "AlloyLSPTestSupport",
                "AlloyFakeLSP",
                .product(name: "MetalUI", package: "MetalUI"),
                .product(name: "MetalUITesting", package: "MetalUI"),
                .product(name: "MetalUITestingSnapshot", package: "MetalUI"),
                .product(name: "MetalUITerminalUI", package: "MetalUI"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "ReleaseScriptTests"),
    ],
    swiftLanguageModes: [.v6]
)
