import Testing
@testable import AlloyPlugins

@Suite struct PluginLogRedactorTests {
    @Test func redactsEachPattern() {
        let lines = [
            "Authorization: Bearer abc.def-123",
            "key sk-abc_123-XYZ here",
            "token ghp_AbC123xyz",
            "pat github_pat_11AAA_bbb",
            "slack xoxb-123-456-abc",
            "aws AKIAABCDEFGHIJKLMNOP",
            "blob \(String(repeating: "A1b2", count: 8))",
        ]
        for line in lines {
            let out = PluginLogRedactor.redact(line)
            #expect(out.contains(PluginLogRedactor.marker), "\(line) -> \(out)")
        }
        #expect(!PluginLogRedactor.redact("key sk-abc_123-XYZ here").contains("sk-abc"))
        #expect(!PluginLogRedactor.redact("Authorization: Bearer abc.def-123").contains("abc.def"))
        #expect(!PluginLogRedactor.redact("aws AKIAABCDEFGHIJKLMNOP").contains("AKIA"))
    }

    @Test func keepsOrdinaryText() {
        let text = "error: file not found at line 12"
        #expect(PluginLogRedactor.redact(text) == text)
    }

    @Test func redactsKnownSecretValues() {
        let out = PluginLogRedactor.redact("password is hunter2 and again hunter2", secrets: ["hunter2"])
        #expect(!out.contains("hunter2"))
        #expect(out.components(separatedBy: PluginLogRedactor.marker).count == 3)
        #expect(PluginLogRedactor.redact("nothing here", secrets: [""]) == "nothing here")
    }
}
