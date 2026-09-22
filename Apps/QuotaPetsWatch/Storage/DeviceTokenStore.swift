import Foundation
import Security

/// Where the watch keeps its device token.
///
/// The token no longer comes from the build. It used to: `Secrets.xcconfig` carried
/// `QUOTAPETS_API_TOKEN`, which meant the server's admin credential was compiled into the
/// app bundle and rotating it meant rebuilding. Now the watch earns its own token through
/// QR pairing and stores it here.
///
/// Two deliberate choices in the query:
///
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — *AfterFirstUnlock* rather than
///   *WhenUnlocked* because complication refresh and background fetch run while the
///   wrist is down; *ThisDeviceOnly* because a device token is scoped to this watch and
///   has no business appearing in a backup or on another device.
/// - No access group. The widget extension reads the cached snapshot from the shared App
///   Group container and never talks to the server, so it needs no credential and the
///   token stays in the app's own keychain.
enum DeviceTokenStore {
    private static let service = "com.quotapets.watch"
    private static let account = "device-token"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    /// Replaces any existing token. Written as delete-then-add rather than `SecItemUpdate`
    /// so a half-written or wrongly-attributed leftover cannot survive a re-pair.
    @discardableResult
    static func save(_ token: String) -> Bool {
        clear()
        var insert = query
        insert[kSecValueData as String] = Data(token.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
