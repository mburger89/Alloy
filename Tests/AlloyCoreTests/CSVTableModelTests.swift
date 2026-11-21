@testable import AlloyCore
import MetalUICodeBuffer
import Testing

@MainActor
private func makeDoc(_ text: String, language: String? = "csv") -> EditorDocument {
    EditorDocument(path: "t.\(language ?? "csv")", buffer: CodeBuffer(utf8: Array(text.utf8)), language: language,
                   state: .editable, diskStamp: FileStamp(modified: nil, size: text.utf8.count))
}

private func rows(_ n: Int) -> String {
    var s = "id,name,city\n"
    for i in 0..<n { s += "\(i),name\(i),city\(i)\n" }
    return s
}

@MainActor
private func model(_ text: String, language: String? = "csv") async -> (CSVTableModel, EditorDocument) {
    let d = makeDoc(text, language: language)
    let m = CSVTableModel(document: d)
    await m.buildFinished()
    return (m, d)
}

@MainActor
@Suite struct CSVTableModelTests {
    @Test func opensWithRowsScannedSoFar() async {
        let d = makeDoc(rows(50_000))
        let m = CSVTableModel(document: d)
        #expect(m.rowCount <= 50_000)
        await m.buildFinished()
        #expect(m.rowCount == 50_000)
        #expect(!m.isBuilding)
        #expect(m.cells(forDataRow: 49_999).values == ["49999", "name49999", "city49999"])
    }

    @Test func cellsComeFromTheWindowCacheAndAreBounded() async {
        let (m, _) = await model(rows(5_000))
        for i in stride(from: 0, to: 5_000, by: 10) {
            _ = m.cells(forDataRow: i)
            #expect(m.cachedRowCount <= 512)
        }
        #expect(m.cells(forDataRow: 4_990).values[0] == "4990")
    }

    @Test func headerToggleReindexesRowNumbers() async {
        let (m, _) = await model("id,name\n1,a\n2,b\n")
        #expect(m.rowCount == 2)
        #expect(m.headerTitles() == ["id", "name"])
        let rev = m.revision
        m.hasHeader = false
        #expect(m.revision != rev)
        #expect(m.rowCount == 3)
        #expect(m.headerTitles() == ["A", "B"])
        #expect(m.cells(forDataRow: 0).values == ["id", "name"])
        #expect(m.fileRow(forDataRow: 0) == 0)
        #expect(m.dataRow(forFileRow: 0) == 0)
        m.hasHeader = true
        #expect(m.dataRow(forFileRow: 0) == nil)
        #expect(m.dataRow(forFileRow: 1) == 0)
        #expect(m.dataRow(forFileRow: 3) == nil)
    }

    @Test func agentRewriteUpdatesInPlace() async throws {
        let (m, d) = await model(rows(100))
        _ = m.cells(forDataRow: 5)
        _ = m.cells(forDataRow: 90)
        let rev = m.revision
        let text = String(decoding: d.buffer.snapshot().utf8(in: 0..<d.buffer.snapshot().utf8Count), as: UTF8.self)
        let r = text.range(of: "50,name50,city50")!
        let at = text.utf8.distance(from: text.startIndex, to: r.lowerBound)
        try d.buffer.applyExternalEdits([CodeTextEdit(range: at..<(at + 2), text: "XX")])
        m.sync()
        #expect(m.cells(forDataRow: 50).values == ["XX", "name50", "city50"])
        #expect(m.revision != rev)
        #expect(m.cells(forDataRow: 5).values[0] == "5")
        #expect(m.cells(forDataRow: 90).values[0] == "90")
        #expect(m.rowCount == 100)
    }

    @Test func deletingEveryRowLeavesZeroRowsAndNoStaleReads() async throws {
        let (m, d) = await model(rows(50))
        _ = m.cells(forDataRow: 10)
        let n = d.buffer.snapshot().utf8Count
        try d.buffer.applyExternalEdits([CodeTextEdit(range: 0..<n, text: "")])
        m.sync()
        await m.buildFinished()
        #expect(m.rowCount == 0)
        #expect(m.cells(forDataRow: 10).values.allSatisfy { $0.isEmpty })
        #expect(m.headerTitles() == [] || m.headerTitles().allSatisfy { !$0.isEmpty })
    }

    @Test func delimiterChangeRebuilds() async throws {
        let (m, d) = await model("a,b\n1,2\n3,4\n")
        let new = "x;y;z\n5;6;7\n8;9;0\n"
        let n = d.buffer.snapshot().utf8Count
        try d.buffer.applyExternalEdits([CodeTextEdit(range: 0..<n, text: new)])
        m.sync()
        await m.buildFinished()
        let (fresh, _) = await model(new)
        #expect(m.indexDialect == fresh.indexDialect)
        #expect(m.indexDialect == .semicolon)
        #expect(m.rowCount == fresh.rowCount)
        #expect(m.headerTitles() == fresh.headerTitles())
        for i in 0..<m.rowCount { #expect(m.cells(forDataRow: i).values == fresh.cells(forDataRow: i).values) }
    }

    @Test func raggedRowShowsEmptyCells() async {
        let (m, _) = await model("a,b,c\n1\n1,2,3,4\n")
        _ = m.cells(forDataRow: 1)
        #expect(m.cells(forDataRow: 0).values == ["1", "", "", ""])
        #expect(m.cells(forDataRow: 1).values == ["1", "2", "3", "4"])
        #expect(m.columnCount == 4)
        #expect(m.headerTitles().count == 4)
    }

    @Test func tsvUsesTabs() async {
        let (m, _) = await model("a\tb\n1\t2\n", language: "tsv")
        #expect(m.cells(forDataRow: 0).values == ["1", "2"])
    }

    @Test func readOnlyReasonFollowsState() async {
        let (m, d) = await model("a\n")
        #expect(m.readOnlyReason == nil)
        d.state = .readOnly(reason: "too large")
        #expect(m.readOnlyReason == "too large")
    }

    @Test func editDuringBuildStillConverges() async throws {
        let d = makeDoc(rows(20_000))
        let m = CSVTableModel(document: d)
        _ = d.buffer.replace(0..<0, with: "zz,zz,zz\n")
        m.sync()
        await m.buildFinished()
        #expect(m.rowCount == 20_001)   // new first row becomes the header
        #expect(m.headerTitles() == ["zz", "zz", "zz"])
    }

    @Test func widthsAreClamped() async {
        let long = String(repeating: "x", count: 400)
        let (m, _) = await model("a,b\n\(long),1\n")
        let w = m.columnWidths()
        #expect(w.count == 2)
        #expect(w[0] == 320)
        #expect(w[1] == 60)
    }

    @Test func noStoredCopyOfTheFile() async {
        let pad = String(repeating: "x", count: 70)
        let text = "id,name,city\n" + (0..<160_000).map { "\($0),name\($0),\(pad)\n" }.joined()   // about 16 MB
        let (m, _) = await model(text)
        for i in stride(from: 0, to: 160_000, by: 1_600) { _ = m.cells(forDataRow: i) }
        #expect(text.utf8.count > 14_000_000)
        #expect(m.retainedByteEstimate * 20 < text.utf8.count)
    }
}
