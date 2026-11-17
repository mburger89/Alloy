import AlloyCore
import Foundation
import Testing
@testable import AlloyLSP

private func json(_ text: String) -> JSONValue { JSONValue.parse(Data(text.utf8))! }
private func caps(_ body: String) -> ServerCapabilities {
    ServerCapabilities(json: json(#"{"capabilities":"# + body + "}"))
}

@Suite struct CapabilitiesTests {
    @Test func parsesCompletionProvider() {
        let c = caps(#"{"completionProvider":{"triggerCharacters":[".",":"],"resolveProvider":true,"allCommitCharacters":[";"]}}"#)
        #expect(c.completion)
        #expect(c.completionTriggerCharacters == [".", ":"])
        #expect(c.completionResolve)
        #expect(c.completionCommitCharacters == [";"])
        #expect(Feature.completion.supported(c))
        #expect(Feature.completionResolve.supported(c))
        #expect(FeatureSet(c).completion)
    }

    @Test func parsesSignatureHelpProvider() {
        let c = caps(#"{"signatureHelpProvider":{"triggerCharacters":["(",","],"retriggerCharacters":[")"]}}"#)
        #expect(c.signatureHelp)
        #expect(c.signatureTriggerCharacters == ["(", ","])
        #expect(c.signatureRetriggerCharacters == [")"])
        #expect(FeatureSet(c).signatureHelp)
    }

    @Test func parsesCodeActionProviderObjectAndBool() {
        let plain = caps(#"{"codeActionProvider":true}"#)
        #expect(plain.codeAction && !plain.codeActionResolve && plain.codeActionKinds.isEmpty)
        let rich = caps(#"{"codeActionProvider":{"resolveProvider":true,"codeActionKinds":["quickfix","refactor"]}}"#)
        #expect(rich.codeAction && rich.codeActionResolve)
        #expect(rich.codeActionKinds == ["quickfix", "refactor"])
        #expect(Feature.codeAction.supported(rich) && Feature.codeActionResolve.supported(rich))
        #expect(!Feature.codeActionResolve.supported(plain))
        #expect(FeatureSet(rich).codeAction)
    }

    @Test func parsesExecuteCommandProvider() {
        let c = caps(#"{"executeCommandProvider":{"commands":["a.fix","b.fix"]}}"#)
        #expect(c.executeCommands == ["a.fix", "b.fix"])
        #expect(Feature.executeCommand.supported(c))
        #expect(!Feature.executeCommand.supported(caps("{}")))
    }

    @Test func missingProvidersAreOff() {
        let c = caps("{}")
        #expect(!c.completion && !c.completionResolve && c.completionTriggerCharacters.isEmpty
            && c.completionCommitCharacters.isEmpty)
        #expect(!c.signatureHelp && c.signatureTriggerCharacters.isEmpty && c.signatureRetriggerCharacters.isEmpty)
        #expect(!c.codeAction && !c.codeActionResolve && c.executeCommands.isEmpty)
        #expect(FeatureSet(c) == FeatureSet())
    }

    @Test func featureMethods() {
        #expect(Feature.completion.method == "textDocument/completion")
        #expect(Feature.completionResolve.method == "completionItem/resolve")
        #expect(Feature.signatureHelp.method == "textDocument/signatureHelp")
        #expect(Feature.codeAction.method == "textDocument/codeAction")
        #expect(Feature.codeActionResolve.method == "codeAction/resolve")
        #expect(Feature.executeCommand.method == "workspace/executeCommand")
    }

    @Test func featureSetUnionOrsNewFields() {
        var a = FeatureSet(completion: true)
        a.formUnion(FeatureSet(signatureHelp: true))
        a.formUnion(FeatureSet(codeAction: true))
        #expect(a.completion && a.signatureHelp && a.codeAction)
        #expect(!a.hover)
    }

    @Test func clientCapabilitiesAdvertiseWave2() {
        let td = LanguageServer.clientCapabilities["textDocument"]
        let item = td?["completion"]?["completionItem"]
        #expect(item?["snippetSupport"]?.boolValue == true)
        #expect(item?["insertReplaceSupport"]?.boolValue == true)
        let props = item?["resolveSupport"]?["properties"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(Set(["documentation", "detail", "additionalTextEdits"]).isSubset(of: Set(props)))
        let formats = item?["documentationFormat"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(formats.contains("markdown"))
        #expect(td?["signatureHelp"]?["signatureInformation"]?["parameterInformation"]?["labelOffsetSupport"]?.boolValue == true)
        let action = td?["codeAction"]
        #expect(action?["codeActionLiteralSupport"] != nil)
        #expect(action?["isPreferredSupport"]?.boolValue == true)
        #expect(action?["dataSupport"]?.boolValue == true)
        #expect(action?["resolveSupport"]?["properties"]?.arrayValue?.compactMap(\.stringValue) == ["edit"])
        #expect(LanguageServer.clientCapabilities["workspace"]?["executeCommand"] != nil)
    }
}
