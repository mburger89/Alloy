import Foundation
import Testing
@testable import AlloyCore

/// The CLI reports hook paths with symlinks resolved (`/private/var/...`), while the project may be opened by its
/// symlinked name (`/var/...`). Found by the live coordination check; Foundation's `resolvingSymlinksInPath` strips
/// the `/private` prefix again, so it cannot be the resolver.
struct HookRootFormsTests {
    @Test func rootIncludesTheRealPathTheCLIReports() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hook-root-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { Issue.record("realpath failed"); return }
        let real = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let forms = Workspace.hookRootForms(of: dir)
        #expect(forms.contains(real), "forms=\(forms) real=\(real)")
        #expect(forms.contains(Workspace.lexicalPath(dir.path)))
    }
}
