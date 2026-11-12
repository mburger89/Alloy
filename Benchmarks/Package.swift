// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AlloyBenchmarks",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ordo-one/package-benchmark", exact: "1.38.1"),
        .package(name: "Alloy", path: ".."),
        // The code buffer is MetalUI's; AlloyCore does not re-export it, so the benchmark names the product.
        .package(name: "MetalUI", path: "../../MetalUI"),
    ],
    targets: [
        .executableTarget(
            name: "AlloyHotPaths",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "AlloyCore", package: "Alloy"),
                .product(name: "AlloyHighlight", package: "Alloy"),
                .product(name: "MetalUICodeBuffer", package: "MetalUI"),
            ],
            path: "Benchmarks/AlloyHotPaths",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
