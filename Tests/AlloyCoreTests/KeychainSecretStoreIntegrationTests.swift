import AlloyCore
import Foundation
import Security
import Testing

/// Opt-in (`ALLOY_KEYCHAIN_TEST=1`): runs against a throwaway keychain file, never the login keychain.
@Suite struct KeychainSecretStoreIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ALLOY_KEYCHAIN_TEST"] == "1"))
    func roundTripInThrowawayKeychain() throws {
        let path = NSTemporaryDirectory() + "alloy-test-\(UUID().uuidString).keychain-db"
        var kc: SecKeychain?
        let pw = "pw"
        #expect(SecKeychainCreate(path, UInt32(pw.utf8.count), pw, false, nil, &kc) == errSecSuccess)
        defer { if let kc { SecKeychainDelete(kc) }; try? FileManager.default.removeItem(atPath: path) }
        let store = KeychainSecretStore(keychain: kc)
        try store.set("v1", agent: "t", variable: "T_KEY")
        #expect(try store.get(agent: "t", variable: "T_KEY") == "v1")
        try store.set("v2", agent: "t", variable: "T_KEY")
        #expect(try store.get(agent: "t", variable: "T_KEY") == "v2")
        try store.set("o", agent: "u", variable: "U_KEY")
        try store.deleteAll(agent: "t")
        #expect(try store.get(agent: "t", variable: "T_KEY") == nil)
        #expect(try store.get(agent: "u", variable: "U_KEY") == "o")
    }
}
