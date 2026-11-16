import AlloyCore
import Foundation
import SwiftTreeSitter

extension Language {
    /// The tree-sitter query whose `@fold` captures mark foldable nodes; `nil` for a language without one. The
    /// text is a string literal, so nothing is looked up or compiled before the first fold request.
    var foldQuerySource: String? {
        switch self {
        case .swift:
            return """
            (class_body) @fold
            (function_body) @fold
            (enum_class_body) @fold
            (protocol_body) @fold
            (computed_property) @fold
            (lambda_literal) @fold
            (switch_statement) @fold
            (if_statement) @fold
            (guard_statement) @fold
            (for_statement) @fold
            (while_statement) @fold
            (do_statement) @fold
            """
        case .python:
            return """
            (function_definition) @fold
            (class_definition) @fold
            (if_statement) @fold
            (for_statement) @fold
            (while_statement) @fold
            (try_statement) @fold
            (with_statement) @fold
            (match_statement) @fold
            """
        case .json:
            return """
            (object) @fold
            (array) @fold
            """
        case .javascript:
            return """
            (statement_block) @fold
            (class_body) @fold
            (object) @fold
            (array) @fold
            (switch_body) @fold
            (arguments) @fold
            (jsx_element) @fold
            """
        case .typescript:
            return """
            (statement_block) @fold
            (class_body) @fold
            (object) @fold
            (array) @fold
            (switch_body) @fold
            (arguments) @fold
            (interface_body) @fold
            (enum_body) @fold
            (object_type) @fold
            """
        case .tsx:
            return """
            (statement_block) @fold
            (class_body) @fold
            (object) @fold
            (array) @fold
            (switch_body) @fold
            (arguments) @fold
            (interface_body) @fold
            (enum_body) @fold
            (object_type) @fold
            (jsx_element) @fold
            """
        case .markdown:
            return """
            (section) @fold
            (fenced_code_block) @fold
            (list) @fold
            """
        case .bash:
            return """
            (function_definition) @fold
            (compound_statement) @fold
            (if_statement) @fold
            (for_statement) @fold
            (while_statement) @fold
            (case_statement) @fold
            (do_group) @fold
            """
        case .rust:
            return """
            (block) @fold
            (declaration_list) @fold
            (field_declaration_list) @fold
            (enum_variant_list) @fold
            (match_block) @fold
            (use_list) @fold
            """
        case .go:
            return """
            (block) @fold
            (field_declaration_list) @fold
            (interface_type) @fold
            (literal_value) @fold
            (import_spec_list) @fold
            """
        case .c:
            return """
            (compound_statement) @fold
            (field_declaration_list) @fold
            (enumerator_list) @fold
            (initializer_list) @fold
            """
        case .cpp:
            return """
            (compound_statement) @fold
            (field_declaration_list) @fold
            (enumerator_list) @fold
            (initializer_list) @fold
            (declaration_list) @fold
            """
        case .html:
            return """
            (element) @fold
            (script_element) @fold
            (style_element) @fold
            """
        case .css:
            return """
            (block) @fold
            """
        case .yaml:
            return """
            (block_mapping_pair value: (block_node)) @fold
            (block_sequence_item (block_node)) @fold
            """
        }
    }
}

/// Turns the `@fold` captures of a tree into line ranges.
enum FoldQueryRunner {
    /// The normalized fold ranges of `tree` (the whole-file tree of `bytes`); `nil` when there is no query.
    static func ranges(tree: MutableTree, query: Query?, bytes: [UInt8]) -> [FoldRange]? {
        guard let query else { return nil }
        guard let root = tree.rootNode else { return [] }
        var raw: [FoldRange] = []
        let cursor = query.execute(node: root, in: tree)
        while let match = cursor.next() {
            for capture in match.captures where capture.nameComponents == ["fold"] {
                let range = capture.node.pointRange
                let start = Int(range.lowerBound.row)
                var end = Int(range.upperBound.row)
                // A node ending at column 0 stops on the previous row.
                if range.upperBound.column == 0, end > start { end -= 1 }
                else if startsWithCloser(bytes, endByte: Int(capture.node.byteRange.upperBound)) { end -= 1 }
                raw.append(FoldRange(startLine: start, endLine: end))
            }
        }
        var lineCount = 1
        for b in bytes where b == UInt8(ascii: "\n") { lineCount += 1 }
        return FoldMerge.normalized(raw, lineCount: lineCount)
    }

    /// Whether the line holding the byte before `endByte` has `}`, `)` or `]` as its first non-space byte.
    private static func startsWithCloser(_ bytes: [UInt8], endByte: Int) -> Bool {
        var i = min(endByte, bytes.count) - 1
        guard i >= 0 else { return false }
        while i > 0, bytes[i - 1] != UInt8(ascii: "\n") { i -= 1 }
        while i < bytes.count, bytes[i] == UInt8(ascii: " ") || bytes[i] == UInt8(ascii: "\t") { i += 1 }
        guard i < bytes.count else { return false }
        return bytes[i] == UInt8(ascii: "}") || bytes[i] == UInt8(ascii: ")") || bytes[i] == UInt8(ascii: "]")
    }
}
