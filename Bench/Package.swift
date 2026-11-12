// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "alloy-bench",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "alloy-bench", targets: ["alloy-bench"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.5.0"),
    ],
    targets: [
        .target(name: "BenchCore"),
        .target(name: "BenchDrivers", dependencies: ["BenchCore"]),
        .target(name: "BenchScenarios", dependencies: ["BenchCore", "BenchDrivers"]),
        .executableTarget(
            name: "alloy-bench",
            dependencies: [
                "BenchCore", "BenchDrivers", "BenchScenarios",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(name: "BenchCoreTests",
                    dependencies: ["BenchCore", "BenchDrivers", "BenchScenarios"],
                    resources: [.copy("Fixtures")]),
    ]
)
