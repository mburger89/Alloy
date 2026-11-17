import Testing
@testable import AlloyLSP

struct SnippetTextTests {
    @Test func tabStopsAndPlaceholders() {
        let r = SnippetText.plain("foo($1, ${2:bar})$0")
        #expect(r.text == "foo(, bar)")
        #expect(r.caret == 10)
    }

    @Test func choiceKeepsFirst() {
        #expect(SnippetText.plain("${1|a,b|}").text == "a")
    }

    @Test func escapes() {
        #expect(SnippetText.plain("\\$1 \\} \\\\").text == "$1 } \\")
    }

    @Test func variables() {
        #expect(SnippetText.plain("${TM_FILENAME:x}").text == "x")
        #expect(SnippetText.plain("$TM_FILENAME").text == "")
    }

    @Test func nestedPlaceholders() {
        #expect(SnippetText.plain("${1:a${2:b}}").text == "ab")
    }

    @Test func noFinalTabStopMeansNoCaret() {
        #expect(SnippetText.plain("foo($1)").caret == nil)
    }

    @Test func caretIsUTF8() {
        let r = SnippetText.plain("é$0")
        #expect(r.text == "é")
        #expect(r.caret == 2)
    }

    @Test func plainTextAndStrayDollarsSurvive() {
        #expect(SnippetText.plain("a $ b").text == "a $ b")
        #expect(SnippetText.plain("x${").text == "x${")
        #expect(SnippetText.plain("").caret == nil)
    }
}
