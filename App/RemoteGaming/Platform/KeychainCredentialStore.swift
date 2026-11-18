import Foundation
import Security
import RGPCore

/// Pairing material lives only in the iOS Keychain, device-only (not synced to iCloud,
/// not included in backups restored to another device). Nothing here logs the secret.
final class KeychainCredentialStore: CredentialStore {
    private let service = "rgp.console-pairing"

    private func query(_ consoleID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: consoleID]
    }

    func save(_ secret: PairingSecret, for consoleID: String) throws {
        SecItemDelete(query(consoleID) as CFDictionary)
        var item = query(consoleID)
        item[kSecValueData as String] = secret.data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func load(for consoleID: String) throws -> PairingSecret? {
        var q = query(consoleID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return PairingSecret(data: data)
    }

    func delete(for consoleID: String) throws {
        let status = SecItemDelete(query(consoleID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    struct KeychainError: Error { let status: OSStatus }
}
