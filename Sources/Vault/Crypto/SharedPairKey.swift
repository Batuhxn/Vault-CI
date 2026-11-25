import Foundation
import Security

/// What the notification extension needs to open a push on its own: the pair's
/// derived key, which member this device is, and the partner's name for the
/// notification title.
///
/// Kept in the Keychain under the app group, so only Watchlink and its
/// extension can read it, on this device only (never synced, never backed up
/// to another phone), and available after the first unlock so pushes open
/// while the phone is locked. The X25519 identity key stays app-only.
struct SharedPairKey: Codable, Equatable {
    static let accessGroup = "group.com.batuhxn.watchlink"
    private static let service = "com.batuhxn.watchlink.pairkey"

    let pairID: String
    let myID: String
    let key: Data
    var partnerName: String

    /// Best effort: an unsigned or simulator build has no app group and simply skips this.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let query = Self.query(pairID)
        let update = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load(pairID: String) -> SharedPairKey? {
        var query = query(pairID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SharedPairKey.self, from: data)
    }

    /// Signing out removes every pair key this device shared with the extension.
    static func removeAll() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccessGroup as String: accessGroup]
        SecItemDelete(query as CFDictionary)
    }

    private static func query(_ pairID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: pairID,
         kSecAttrAccessGroup as String: accessGroup,
         kSecAttrSynchronizable as String: false]
    }
}
