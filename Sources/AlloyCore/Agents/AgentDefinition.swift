import Foundation

/// One plain (non-secret) environment variable of an agent.
public struct EnvVar: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }

    /// A name that looks like it holds a credential (KEY, TOKEN, SECRET, PASSWORD, CREDENTIAL, any case).
    public static func looksSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL"].contains { upper.contains($0) }
    }

    public static let secretRefusal = "Add this under Secrets; Alloy keeps it in your Keychain."
}

public struct AgentDefinitionError: Error, LocalizedError, Equatable {
    /// The refused variable.
    public var variable: String
    public var errorDescription: String? { EnvVar.secretRefusal }
}

/// An ACP agent Alloy can start: a preset or a custom one. Secrets are named here, their values live in the Keychain.
public struct AgentDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var command: String
    public var args: [String]
    /// Non-secret variables only (`validate()` refuses names that look like credentials).
    public var env: [EnvVar]
    /// Names of the variables whose values are kept in the Keychain.
    public var secretNames: [String]
    public var installHint: String?
    public var isPreset: Bool

    public init(id: String, name: String, command: String, args: [String] = [], env: [EnvVar] = [],
                secretNames: [String] = [], installHint: String? = nil, isPreset: Bool = false) {
        self.id = id; self.name = name; self.command = command; self.args = args; self.env = env
        self.secretNames = secretNames; self.installHint = installHint; self.isPreset = isPreset
    }

    /// Refuses a plain variable whose name looks like a credential.
    public func validate() throws {
        if let bad = env.first(where: { EnvVar.looksSecret($0.name) }) { throw AgentDefinitionError(variable: bad.name) }
    }

    /// The plain variables plus every secret `store` holds for this agent (found through `names(agent:)`, plus any older
    /// `secretNames`). A denied or unavailable Keychain, or a secret that was
    /// never set, never throws: the variable is left out and named in `missing`.
    public func resolveEnvironment(store: AgentSecretStore) -> (env: [String: String], missing: [String]) {
        var out: [String: String] = [:], missing: [String] = []
        for v in env where !EnvVar.looksSecret(v.name) { out[v.name] = v.value }
        // The store is the source of truth for names; `secretNames` (older custom definitions) is merged in.
        let stored = (try? store.names(agent: id)) ?? []
        for name in stored where !secretNames.contains(name) {
            if let value = (try? store.get(agent: id, variable: name)) ?? nil, !value.isEmpty { out[name] = value }
        }
        for name in secretNames {
            if let value = (try? store.get(agent: id, variable: name)) ?? nil, !value.isEmpty {
                out[name] = value
            } else {
                missing.append(name)
            }
        }
        return (out, missing)
    }

    /// Deletes every stored secret of this agent (call when the agent is removed).
    public func removeSecrets(from store: AgentSecretStore) throws { try store.deleteAll(agent: id) }
}
