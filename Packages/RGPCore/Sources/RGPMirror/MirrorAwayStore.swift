import Foundation
import Network
import Security

/// What a phone needs to reach a paired computer from away: the long away key (Keychain) and
/// the home's internet address (not a secret, kept in settings).
enum MirrorAwayStore {
    private static let service = "coastplay.mirror.away"

    static func save(key: String, for consoleID: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: consoleID]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func key(for consoleID: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: consoleID,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func homeAddress(for consoleID: String) -> String? { UserDefaults.standard.string(forKey: "homeInternetAddress.\(consoleID)") }

    /// During a home-network session, note the home's public internet address. One request to a
    /// public "what is my address" service (api.ipify.org); nothing about the person or the
    /// computer is sent. Same approach as the PlayStation away route.
    static func learnHomeAddress(for consoleID: String) async {
        guard await onWiFiOrWired(), let url = URL(string: "https://api.ipify.org?format=text"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.split(separator: ".").count == 4, text.allSatisfy({ $0.isNumber || $0 == "." }) else { return }
        UserDefaults.standard.set(text, forKey: "homeInternetAddress.\(consoleID)")
    }

    /// True when this device is on Wi-Fi or a cable rather than mobile data.
    static func onWiFiOrWired() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            var answered = false
            let queue = DispatchQueue(label: "rgp.mirror.path")
            monitor.pathUpdateHandler = { path in
                guard !answered else { return }
                answered = true
                monitor.cancel()
                continuation.resume(returning: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1) {
                guard !answered else { return }
                answered = true
                monitor.cancel()
                continuation.resume(returning: true)
            }
        }
    }
}
