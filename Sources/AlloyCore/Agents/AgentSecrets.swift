import Foundation
import Security

/// Where agent secrets live. Real storage is the Keychain only; nothing here ever writes a file.
public protocol AgentSecretStore: Sendable {
    func set(_ value: String, agent: String, variable: String) throws
    func get(agent: String, variable: String) throws -> String?
    func delete(agent: String, variable: String) throws
    func deleteAll(agent: String) throws
    /// False when this store cannot hold secrets here (no Keychain); Settings then hides the Secrets list.
    var isAvailable: Bool { get }
    /// The variable names stored for `agent`, never the values.
    func names(agent: String) throws -> [String]
}

public extension AgentSecretStore {
    var isAvailable: Bool { true }
    func names(agent: String) throws -> [String] { [] }
}

public struct SecretStoreError: Error, LocalizedError, Equatable {
    public var status: Int32
    public init(status: Int32) { self.status = status }
    /// The status code only, never a value.
    public var errorDescription: String? { "The Keychain refused the request (status \(status))." }
}

/// Generic-password items, service `dev.alloy.agent-secret`, account `<agent id>/<VARIABLE_NAME>`, readable only
/// while the Mac is unlocked and never copied to another device.
public final class KeychainSecretStore: AgentSecretStore, @unchecked Sendable {
    public static let service = "dev.alloy.agent-secret"
    /// A keychain other than the default (tests use a throwaway file); nil means the user's default keychain.
    private let keychain: SecKeychain?

    public init(keychain: SecKeychain? = nil) { self.keychain = keychain }

    private func account(_ agent: String, _ variable: String) -> String { "\(agent)/\(variable)" }

    private func base(account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service]
        if let account { q[kSecAttrAccount as String] = account }
        if let keychain { q[kSecMatchSearchList as String] = [keychain] }
        return q
    }

    public func set(_ value: String, agent: String, variable: String) throws {
        let acct = account(agent, variable)
        let data = Data(value.utf8)
        let update = SecItemUpdate(base(account: acct) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError(status: update) }
        var add = base(account: acct)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        if let keychain { add[kSecUseKeychain as String] = keychain }
        add[kSecMatchSearchList as String] = nil
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }

    public func get(agent: String, variable: String) throws -> String? {
        var q = base(account: account(agent, variable))
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw SecretStoreError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func delete(agent: String, variable: String) throws {
        let status = SecItemDelete(base(account: account(agent, variable)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
    }

    public func names(agent: String) throws -> [String] {
        var q = base()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
        let prefix = agent + "/"
        return ((out as? [[String: Any]]) ?? []).compactMap { item in
            guard let acct = item[kSecAttrAccount as String] as? String, acct.hasPrefix(prefix) else { return nil }
            return String(acct.dropFirst(prefix.count))
        }.sorted()
    }

    public func deleteAll(agent: String) throws {
        var q = base()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
        for item in (out as? [[String: Any]]) ?? [] {
            guard let acct = item[kSecAttrAccount as String] as? String, acct.hasPrefix(agent + "/") else { continue }
            let s = SecItemDelete(base(account: acct) as CFDictionary)
            guard s == errSecSuccess || s == errSecItemNotFound else { throw SecretStoreError(status: s) }
        }
    }
}

/// Memory only: the fake store for tests (and a stand-in while the Keychain is unavailable).
public final class InMemorySecretStore: AgentSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    public init() {}

    public func set(_ value: String, agent: String, variable: String) throws {
        lock.lock(); defer { lock.unlock() }
        items["\(agent)/\(variable)"] = value
    }
    public func get(agent: String, variable: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return items["\(agent)/\(variable)"]
    }
    public func delete(agent: String, variable: String) throws {
        lock.lock(); defer { lock.unlock() }
        items["\(agent)/\(variable)"] = nil
    }
    public func names(agent: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let prefix = agent + "/"
        return items.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
    }
    public func deleteAll(agent: String) throws {
        lock.lock(); defer { lock.unlock() }
        for k in items.keys where k.hasPrefix(agent + "/") { items[k] = nil }
    }
}
