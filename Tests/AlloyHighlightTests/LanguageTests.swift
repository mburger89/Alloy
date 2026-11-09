import AlloyHighlight
import Testing

@Suite struct LanguageTests {
    @Test func detectsLanguages() {
        #expect(Language.detect(path: "/a/b/main.swift") == .swift)
        #expect(Language.detect(path: "tool.py") == .python)
        #expect(Language.detect(path: "App.tsx") == .tsx)
        #expect(Language.detect(path: "Makefile") == nil)
        #expect(Language.detect(path: "run", firstLine: "#!/usr/bin/env python3") == .python)
        #expect(Language.detect(path: "Makefile", firstLine: "all:") == nil)
    }

    @Test func fenceNames() {
        #expect(Language.named("js") == .javascript)
        #expect(Language.named("TS") == .typescript)
        #expect(Language.named("py") == .python)
        #expect(Language.named("zsh") == .bash)
        #expect(Language.named("yml") == .yaml)
        #expect(Language.named("md") == .markdown)
        #expect(Language.named("c++") == .cpp)
        #expect(Language.named("objc") == nil)
        #expect(Language.named("") == nil)
    }
}
