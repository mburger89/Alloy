import AlloyCore
import Foundation
import MetalUICodeBuffer

/// A byte range inside a signature's label.
public struct ParameterLabel: Sendable, Equatable {
    /// UTF-8 offsets into `Signature.label`; an empty range when the server's label could not be located.
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct Signature: Sendable, Equatable {
    public var label: String
    public var parameters: [ParameterLabel]
    /// Markdown.
    public var documentation: String?

    public init(label: String, parameters: [ParameterLabel] = [], documentation: String? = nil) {
        self.label = label
        self.parameters = parameters
        self.documentation = documentation
    }
}

public struct SignatureInfo: Sendable, Equatable {
    public var signatures: [Signature]
    public var activeSignature: Int
    /// The active signature's own `activeParameter` when it has one, else the top-level one.
    public var activeParameter: Int?

    public init(signatures: [Signature], activeSignature: Int = 0, activeParameter: Int? = nil) {
        self.signatures = signatures
        self.activeSignature = activeSignature
        self.activeParameter = activeParameter
    }
}

public enum SignatureTrigger: Sendable, Equatable {
    case invoked
    case character(String)
    /// The popup was already open: after a retrigger character, or (nil) after the content changed.
    case retrigger(String?)
}

public enum SignatureHelpParsing {
    /// Reads a `SignatureHelp` answer. `null` and an empty `signatures` array give nil; nil also for a wrong shape is not
    /// distinguished, a signature without a label is skipped.
    public static func parse(_ result: JSONValue) -> SignatureInfo? {
        guard case .object = result, let raw = result["signatures"]?.arrayValue else { return nil }
        var signatures: [Signature] = []
        var ownActive: [Int?] = []
        var sourceIndex: [Int] = []
        for (index, item) in raw.enumerated() {
            guard case .object = item, let label = item["label"]?.stringValue else { continue }
            let parameters = (item["parameters"]?.arrayValue ?? []).map { parameter($0, in: label) }
            signatures.append(Signature(label: label, parameters: parameters, documentation: CompletionParsing.markdown(item["documentation"])))
            ownActive.append(item["activeParameter"]?.intValue)
            sourceIndex.append(index)
        }
        guard !signatures.isEmpty else { return nil }
        var active = 0
        if let wanted = result["activeSignature"]?.intValue, let mapped = sourceIndex.firstIndex(of: wanted) { active = mapped }
        let parameter = ownActive[active] ?? result["activeParameter"]?.intValue
        return SignatureInfo(signatures: signatures, activeSignature: active, activeParameter: parameter)
    }

    static func parameter(_ raw: JSONValue, in label: String) -> ParameterLabel {
        let empty = ParameterLabel(start: 0, end: 0)
        guard let value = raw["label"] else { return empty }
        if let text = value.stringValue {
            guard !text.isEmpty, let found = label.range(of: text) else { return empty }
            return ParameterLabel(start: label.utf8.distance(from: label.utf8.startIndex, to: found.lowerBound.samePosition(in: label.utf8) ?? label.utf8.startIndex),
                                  end: label.utf8.distance(from: label.utf8.startIndex, to: found.upperBound.samePosition(in: label.utf8) ?? label.utf8.startIndex))
        }
        guard let pair = value.arrayValue, pair.count == 2, let s = pair[0].intValue, let e = pair[1].intValue,
              s >= 0, e >= s else { return empty }
        let units = Array(label.utf16)
        guard e <= units.count else { return empty }
        // An offset inside a surrogate pair belongs to no character.
        func splits(_ offset: Int) -> Bool {
            offset > 0 && offset < units.count && UTF16.isTrailSurrogate(units[offset]) && UTF16.isLeadSurrogate(units[offset - 1])
        }
        guard !splits(s), !splits(e) else { return empty }
        func utf8(_ offset: Int) -> Int { String(decoding: units[0..<offset], as: UTF16.self).utf8.count }
        return ParameterLabel(start: utf8(s), end: utf8(e))
    }
}

extension LSPManager {
    /// Asks the server of `path` for the signature at `utf8Offset` of `snapshot`. A server with nothing to show answers
    /// `.answered(nil)`. Times out after 2 s.
    public func signatureHelp(path: String, utf8Offset: Int, snapshot: CodeSnapshot,
                              trigger: SignatureTrigger) async -> LSPOutcome<SignatureInfo?> {
        await send(.signatureHelp, path: path, snapshot: snapshot, timeout: .seconds(2), params: { uri, encoding in
            var body = Self.textDocumentPosition(uri: uri, offset: utf8Offset, snapshot: snapshot, encoding: encoding)
            var context: [String: JSONValue]
            switch trigger {
            case .invoked: context = ["triggerKind": .number(1), "isRetrigger": .bool(false)]
            case .character(let c): context = ["triggerKind": .number(2), "triggerCharacter": .string(c), "isRetrigger": .bool(false)]
            case .retrigger(let c):
                if let c { context = ["triggerKind": .number(2), "triggerCharacter": .string(c), "isRetrigger": .bool(true)] }
                else { context = ["triggerKind": .number(3), "isRetrigger": .bool(true)] }
            }
            if case .object(var object) = body { object["context"] = .object(context); body = .object(object) }
            return body
        }, parse: { answer, _, _ -> SignatureInfo?? in .some(SignatureHelpParsing.parse(answer)) })
    }
}
