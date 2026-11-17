import AlloyCore
@testable import AlloyHighlight
import Foundation
import MetalUICodeBuffer
import SwiftTreeSitter
import Testing

private typealias Language = AlloyHighlight.Language

private func r(_ a: Int, _ b: Int) -> FoldRange { FoldRange(startLine: a, endLine: b) }

private func open(_ language: Language, _ text: String, engine: HighlightEngine = HighlightEngine()) async -> (HighlightEngine, UUID) {
    let id = UUID()
    await engine.open(id: id, language: language, text: text, version: 0)
    return (engine, id)
}

@Suite struct FoldRangesTests {
    @Test func swiftFoldsStartOnTheOpeningLine() async {
        let (engine, id) = await open(.swift, "struct A {\n  func f() {\n    let x = 1\n  }\n}\n")
        let ranges = await engine.foldRanges(documentID: id) ?? []
        #expect(ranges.contains(r(0, 3)))
        #expect(ranges.contains(r(1, 2)))
    }

    @Test func pythonFoldsDefAndIf() async {
        let (engine, id) = await open(.python, "def f(x):\n    if x:\n        return 1\n    return 2\n")
        let ranges = await engine.foldRanges(documentID: id) ?? []
        #expect(ranges.contains(r(0, 3)))
        #expect(ranges.contains(r(1, 2)))
    }

    @Test func jsonFoldsObjectsAndArrays() async {
        let (engine, id) = await open(.json, "{\n  \"a\": [\n    1,\n    2\n  ]\n}\n")
        let ranges = await engine.foldRanges(documentID: id) ?? []
        #expect(ranges.contains(r(0, 4)))
        #expect(ranges.contains(r(1, 3)))
    }

    @Test func windowedDocumentHasNone() async {
        let text = String(repeating: "struct A {\n  var x = 1\n}\n", count: 4)
        let (engine, id) = await open(.swift, text, engine: HighlightEngine(windowedThreshold: 16))
        #expect(await engine.foldRanges(documentID: id) == nil)
    }

    @Test func foldRangesWaitsForTheVersionAndNamesIt() async {
        let (engine, id) = await open(.swift, "struct A {\n  var x = 1\n}\n")
        let text = "// c\nstruct A {\n  var x = 1\n}\n"
        let pending = Task { await engine.foldRanges(documentID: id, minVersion: 1) }
        for _ in 0..<20 { await Task.yield() }
        await engine.edit(id: id, edits: [insertion(at: 0, "// c\n")], newText: text, version: 1)
        let answer = await pending.value
        #expect(answer?.version == 1)
        #expect(answer?.ranges.contains(r(1, 2)) == true)
        // An answer for a version already held comes at once and names it.
        #expect(await engine.foldRanges(documentID: id, minVersion: 0)?.version == 1)
    }

    @Test func foldRangesWithVersionIsNilForWindowed() async {
        let text = String(repeating: "struct A {\n  var x = 1\n}\n", count: 4)
        let (engine, id) = await open(.swift, text, engine: HighlightEngine(windowedThreshold: 16))
        #expect(await engine.foldRanges(documentID: id, minVersion: 0) == nil)
        #expect(await HighlightEngine().foldRanges(documentID: UUID(), minVersion: 0) == nil)
    }

    @Test func unknownDocumentIsNil() async {
        #expect(await HighlightEngine().foldRanges(documentID: UUID()) == nil)
    }

    @Test func languageWithoutQueryIsNil() async {
        let parser = Parser()
        try? parser.setLanguage(LanguageSupport.of(.swift).language)
        let bytes = Array("struct A {\n}\n".utf8)
        let tree = HighlightCore.parse(parser, old: nil, bytes: bytes)!
        #expect(FoldQueryRunner.ranges(tree: tree, query: nil, bytes: bytes) == nil)
    }

    @Test func cachedUntilTheTreeChanges() async {
        let (engine, id) = await open(.swift, "struct A {\n  var x = 1\n}\n")
        let first = await engine.foldRanges(documentID: id)
        let second = await engine.foldRanges(documentID: id)
        #expect(first == second)
        #expect(await engine.foldQueryRunCount(id: id) == 1)
        let text = "\nstruct A {\n  var x = 1\n}\n"
        await engine.edit(id: id, edits: [insertion(at: 0, "\n")], newText: text, version: 1)
        let third = await engine.foldRanges(documentID: id)
        #expect(await engine.foldQueryRunCount(id: id) == 2)
        #expect(third?.contains(r(1, 2)) == true)
    }

    @Test func editMovesRanges() async {
        let (engine, id) = await open(.swift, "struct A {\n  func f() {\n    let x = 1\n  }\n}\n")
        await engine.edit(id: id, edits: [insertion(at: 0, "// c\n")], newText: "// c\nstruct A {\n  func f() {\n    let x = 1\n  }\n}\n", version: 1)
        let ranges = await engine.foldRanges(documentID: id) ?? []
        #expect(ranges.contains(r(1, 4)))
        #expect(ranges.contains(r(2, 3)))
    }

    @Test func syntaxErrorsStillFold() async {
        let (engine, id) = await open(.swift, "func f() {\n  let x = (\n  if y {\n    z\n  }\n}\n")
        let ranges = await engine.foldRanges(documentID: id)
        #expect(ranges != nil)
        #expect(ranges?.contains(r(2, 3)) == true)
    }

    @Test func everyLanguageHasAFoldQuery() {
        for language in Language.allCases {
            #expect(language.foldQuerySource != nil, "\(language)")
            #expect(LanguageSupport.foldQuery(for: language) != nil, "\(language)")
        }
    }

    private func folds(_ language: Language, _ text: String) async -> [FoldRange] {
        let (engine, id) = await open(language, text)
        return await engine.foldRanges(documentID: id) ?? []
    }

    @Test func jsFoldsFunctionBodyAndObject() async {
        let ranges = await folds(.javascript, "function f() {\n  const o = {\n    a: 1,\n  };\n  return o;\n}\n")
        #expect(ranges.contains(r(0, 4)))
        #expect(ranges.contains(r(1, 2)))
    }

    @Test func typescriptFoldsInterface() async {
        let ranges = await folds(.typescript, "interface A {\n  x: number;\n  y: string;\n}\nclass B {\n  m() {\n    return 1;\n  }\n}\n")
        #expect(ranges.contains(r(0, 2)))
        #expect(ranges.contains(r(4, 7)))
        #expect(ranges.contains(r(5, 6)))
    }

    @Test func tsxFoldsJsxElement() async {
        let ranges = await folds(.tsx, "const a = (\n  <div>\n    <span>x</span>\n  </div>\n);\n")
        #expect(ranges.contains(r(1, 3)))
    }

    @Test func markdownFoldsHeadingSectionAndFence() async {
        let text = "# One\n\ntext\n\n## Sub\n\nmore\n\n# Two\n\n```swift\nlet a = 1\nlet b = 2\n```\n"
        let ranges = await folds(.markdown, text)
        #expect(ranges.contains { $0.startLine == 0 && $0.endLine >= 7 && $0.endLine < 8 })
        #expect(ranges.contains { $0.startLine == 4 && $0.endLine >= 6 && $0.endLine < 8 })
        #expect(ranges.contains { $0.startLine == 10 && $0.endLine >= 12 })
    }

    @Test func bashFoldsFunctionAndIf() async {
        let ranges = await folds(.bash, "f() {\n  if true; then\n    echo a\n  fi\n}\n")
        #expect(ranges.contains(r(0, 3)))
        #expect(ranges.contains { $0.startLine == 1 && $0.endLine >= 2 })
    }

    @Test func rustFoldsFnImplAndMatch() async {
        let ranges = await folds(.rust, "fn main() {\n    let x = 1;\n}\nimpl A {\n    fn f(&self) {\n        match 1 {\n            _ => {}\n        }\n    }\n}\n")
        #expect(ranges.contains(r(0, 1)))
        #expect(ranges.contains(r(3, 8)))
        #expect(ranges.contains(r(5, 6)))
    }

    @Test func goFoldsFuncAndStruct() async {
        let ranges = await folds(.go, "package p\n\ntype A struct {\n\tx int\n\ty int\n}\n\nfunc f() {\n\tx := 1\n}\n")
        #expect(ranges.contains(r(2, 4)))
        #expect(ranges.contains(r(7, 8)))
    }

    @Test func cFoldsFunctionAndEnum() async {
        let ranges = await folds(.c, "enum E {\n  A,\n  B\n};\nint main(void) {\n  return 0;\n}\n")
        #expect(ranges.contains(r(0, 2)))
        #expect(ranges.contains(r(4, 5)))
    }

    @Test func cppFoldsClassAndNamespace() async {
        let ranges = await folds(.cpp, "namespace n {\nclass A {\n  int x;\n  int y;\n};\n}\n")
        #expect(ranges.contains(r(0, 4)))
        #expect(ranges.contains(r(1, 3)))
    }

    @Test func yamlFoldsNestedMapping() async {
        let ranges = await folds(.yaml, "a:\n  b:\n    c: 1\n    d: 2\nlist:\n  - x: 1\n    y: 2\n")
        #expect(ranges.contains { $0.startLine == 0 && $0.endLine >= 3 })
        #expect(ranges.contains { $0.startLine == 1 && $0.endLine >= 3 })
        #expect(ranges.contains { $0.startLine == 5 && $0.endLine == 6 })
    }

    @Test func htmlFoldsMultilineElement() async {
        let ranges = await folds(.html, "<div>\n  <p>\n    hi\n  </p>\n</div>\n")
        #expect(ranges.contains { $0.startLine == 0 && $0.endLine >= 3 })
        #expect(ranges.contains { $0.startLine == 1 && $0.endLine >= 2 })
    }

    @Test func cssFoldsRule() async {
        let ranges = await folds(.css, "a {\n  color: red;\n}\n")
        #expect(ranges.contains(r(0, 1)))
    }

    @Test func everyCompiledFoldQueryCompiles() {
        for language in Language.allCases where language.foldQuerySource != nil {
            #expect(LanguageSupport.foldQuery(for: language) != nil, "\(language)")
        }
    }
}

private func insertion(at offset: Int, _ text: String) -> CodeEdit {
    CodeEdit(version: 1, transaction: CodeTransactionID(rawValue: 1), origin: .programmatic, range: offset..<offset,
             scalarRange: offset..<offset, startPoint: CodePoint(row: 0, column: 0), oldEndPoint: CodePoint(row: 0, column: 0),
             newEndPoint: CodePoint(row: 1, column: 0), newText: text)
}
