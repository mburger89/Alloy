import AlloyCore
@testable import AlloyPlugins
import Foundation
import Testing

@Suite struct PluginPanelTreeTests {
    private func json(_ text: String) -> JSONValue { JSONValue.parse(Data(text.utf8)) ?? .null }

    @Test func parsesEveryWidget() throws {
        let tree = try PluginPanelTree.parse(json("""
        {"type":"vstack","key":"root","children":[
          {"type":"text","key":"t","text":"Hello","role":"warning"},
          {"type":"button","key":"b","title":"Go"},
          {"type":"toggle","key":"g","title":"On","isOn":true},
          {"type":"textField","key":"f","placeholder":"Name","text":"abc"},
          {"type":"picker","key":"p","title":"Mode","options":[{"value":"a","title":"A"},{"value":"b","title":"B"}],"selection":"b"},
          {"type":"divider","key":"d"},
          {"type":"hstack","key":"h","children":[{"type":"text","key":"h1","text":"x"}]},
          {"type":"list","key":"l","rows":[{"type":"text","key":"r1","text":"one"},{"type":"button","key":"r2","title":"two"}]}
        ]}
        """), maxElements: 300).get()
        guard case .vstack("root", let children) = tree.root else { Issue.record("root"); return }
        #expect(children.count == 8)
        #expect(children[0] == .text(key: "t", text: "Hello", role: .warning))
        #expect(children[1] == .button(key: "b", title: "Go"))
        #expect(children[2] == .toggle(key: "g", title: "On", isOn: true))
        #expect(children[3] == .textField(key: "f", placeholder: "Name", text: "abc"))
        #expect(children[4] == .picker(key: "p", title: "Mode", options: [.init(value: "a", title: "A"), .init(value: "b", title: "B")], selection: "b"))
        #expect(children[5] == .divider(key: "d"))
        #expect(children[6] == .hstack(key: "h", children: [.text(key: "h1", text: "x", role: nil)]))
        #expect(children[7] == .list(key: "l", rows: [.text(key: "r1", text: "one", role: nil), .button(key: "r2", title: "two")]))
    }

    @Test func duplicateKeyRejectsWholeTree() {
        let result = PluginPanelTree.parse(json("""
        {"type":"vstack","key":"root","children":[{"type":"text","key":"a","text":"1"},{"type":"button","key":"a","title":"2"}]}
        """), maxElements: 300)
        #expect(result == .failure(.duplicateKey("a")))
    }

    @Test func over300ElementsRejected() {
        func tree(_ n: Int) -> JSONValue {
            let kids = (0..<n).map { #"{"type":"text","key":"k\#($0)","text":"x"}"# }.joined(separator: ",")
            return json(#"{"type":"vstack","key":"root","children":[\#(kids)]}"#)
        }
        #expect(PluginPanelTree.parse(tree(299), maxElements: 300) != .failure(.tooManyElements), "root plus 299 is 300 elements")
        #expect(PluginPanelTree.parse(tree(300), maxElements: 300) == .failure(.tooManyElements))
    }

    @Test func deeperThan16Rejected() {
        func nest(_ depth: Int) -> String {
            depth == 1 ? #"{"type":"text","key":"leaf","text":"x"}"# : #"{"type":"vstack","key":"n\#(depth)","children":[\#(nest(depth - 1))]}"#
        }
        #expect((try? PluginPanelTree.parse(json(nest(16)), maxElements: 300).get()) != nil, "16 levels are fine")
        #expect(PluginPanelTree.parse(json(nest(17)), maxElements: 300) == .failure(.tooDeep))
    }

    @Test func badNodesAreRefused() {
        #expect(PluginPanelTree.parse(json(#"{"type":"slider","key":"s"}"#), maxElements: 300) == .failure(.badNode("unknown widget \"slider\"")))
        guard case .failure(.badNode) = PluginPanelTree.parse(json(#"{"type":"text","text":"no key"}"#), maxElements: 300) else {
            Issue.record("a node without a key is refused"); return
        }
        guard case .failure(.badNode) = PluginPanelTree.parse(json(#"{"type":"text","key":"t","text":"x","role":"purple"}"#), maxElements: 300) else {
            Issue.record("an unknown role is refused"); return
        }
    }
}
