import AlloyCore
import Foundation

/// The scriptable fake plugin (`AlloyFakePlugin`), which the test targets depend on so that SwiftPM always builds it next
/// to the test bundle. A missing binary is a build error, never a skipped suite.
public let fakePluginPath: String = {
    let beside = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }
        .map { $0.bundleURL.deletingLastPathComponent().appendingPathComponent("AlloyFakePlugin").path }
    if let beside, FileManager.default.isExecutableFile(atPath: beside) { return beside }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return root.appendingPathComponent(".build/debug/AlloyFakePlugin").path
}()

/// The folder holding `AlloyFakePlugin`; tests put it on the host's `PATH` and in the manifest loader's `pathDirs`.
public var fakePluginDirectory: String { URL(fileURLWithPath: fakePluginPath).deletingLastPathComponent().path }

/// Writes `<plugins>/<id>/alloy-plugin.json` for a scripted plugin run by the fake, with `script.json` beside it. The fake
/// logs every message it receives to `<folder>/log.jsonl`. Returns the plugin folder.
@discardableResult
public func writeFakePlugin(id: String, in plugins: URL, permissions: [String] = [], activation: [String] = [],
                            contributes: JSONValue = .object([:]), script: JSONValue = .object([:]),
                            apiVersion: Int = 1) throws -> URL {
    let folder = plugins.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let manifest: JSONValue = .object([
        "id": .string(id),
        "name": .string(id),
        "version": .string("1.0.0"),
        "apiVersion": .number(Double(apiVersion)),
        "main": .object(["command": .string("AlloyFakePlugin"),
                         "args": .array([.string("--script"), .string("script.json"),
                                         .string("--log"), .string(folder.appendingPathComponent("log.jsonl").path)])]),
        "permissions": .array(permissions.map { .string($0) }),
        "activationEvents": .array(activation.map { .string($0) }),
        "contributes": contributes,
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    try encoder.encode(manifest).write(to: folder.appendingPathComponent("alloy-plugin.json"))
    try encoder.encode(script).write(to: folder.appendingPathComponent("script.json"))
    return folder
}
