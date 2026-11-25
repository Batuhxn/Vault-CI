import CryptoKit
import Foundation
import Security

/// End-to-end encryption for one pair, built only on Apple's CryptoKit.
///
/// - Each device keeps an X25519 identity key in its Keychain (this device only,
///   never synced, never uploaded). Only the 32-byte public key is published,
///   inside the pair document, at pairing time.
/// - Both phones derive the same 256-bit key: X25519 shared secret ->
///   HKDF-SHA256 (salt: pair id, info: version + both public keys).
/// - Everything the server stores for the pair (message payloads, photos,
///   names, heartbeat rhythm) is sealed with ChaCha20-Poly1305. The
///   authenticated data binds each blob to its pair, sender and id, so the
///   server can't move a blob to another message or another sender.
/// - A short safety code (SHA-256 of both public keys) lets the two people
///   check, side by side, that nobody swapped a key in between.
///
/// Limits (MVP): one long-term key per pair, no forward secrecy. Deleting the
/// app deletes the key; the pair then has to link again.
enum PairCrypto {
    static let version = "wl1"

    enum Failure: Error { case keychain(OSStatus), badPublicKey, missingKey, unreadable }

    // MARK: Identity (Keychain)

    /// This device's identity for `userID`, created on first use.
    static func identity(for userID: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        if let existing = try storedIdentity(for: userID) { return existing }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try store(key, for: userID)
        return key
    }

    static func storedIdentity(for userID: String) throws -> Curve25519.KeyAgreement.PrivateKey? {
        var query = baseQuery(userID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure.keychain(status) }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    private static func store(_ key: Curve25519.KeyAgreement.PrivateKey, for userID: String) throws {
        var query = baseQuery(userID)
        query[kSecValueData as String] = key.rawRepresentation
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    private static func baseQuery(_ userID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.batuhxn.watchlink.identity",
         kSecAttrAccount as String: userID,
         kSecAttrSynchronizable as String: false]
    }

    // MARK: Session

    /// The pair's shared key, ready to seal and open.
    struct Session {
        let pairID: String
        let myID: String
        fileprivate let key: SymmetricKey
        let safetyCode: String

        /// `aad` names what the blob is (message, photo, profile) and who wrote it.
        func seal(_ plaintext: Data, aad: String) throws -> Data {
            // ChaChaPoly's combined form: 12-byte nonce + ciphertext + 16-byte tag.
            try ChaChaPoly.seal(plaintext, using: key, authenticating: Data(aad.utf8)).combined
        }

        func open(_ sealed: Data, aad: String) throws -> Data {
            do {
                return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key, authenticating: Data(aad.utf8))
            } catch {
                throw Failure.unreadable
            }
        }

        // Authenticated-data labels, one per kind of blob.
        func messageAAD(id: String, sender: String) -> String { "\(PairCrypto.version)|msg|\(pairID)|\(sender)|\(id)" }
        func photoAAD(id: String, sender: String) -> String { "\(PairCrypto.version)|photo|\(pairID)|\(sender)|\(id)" }
        func profileAAD(of member: String) -> String { "\(PairCrypto.version)|profile|\(pairID)|\(member)" }
    }

    /// Derives the session when both public keys are present and this device
    /// holds the private key matching its published one.
    static func session(pairID: String, myID: String, partnerID: String,
                        publicKeys: [String: Data]) throws -> Session {
        guard let mine = publicKeys[myID], let theirs = publicKeys[partnerID] else { throw Failure.missingKey }
        guard let identity = try storedIdentity(for: myID), identity.publicKey.rawRepresentation == mine else {
            throw Failure.missingKey
        }
        let partnerKey: Curve25519.KeyAgreement.PublicKey
        do { partnerKey = try .init(rawRepresentation: theirs) } catch { throw Failure.badPublicKey }

        let ordered = [mine, theirs].sorted { $0.lexicographicallyPrecedes($1) }
        let shared = try identity.sharedSecretFromKeyAgreement(with: partnerKey)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(pairID.utf8),
            sharedInfo: Data("\(version)|pair-key".utf8) + ordered[0] + ordered[1],
            outputByteCount: 32)
        return Session(pairID: pairID, myID: myID, key: key, safetyCode: safetyCode(ordered[0], ordered[1]))
    }

    /// Six digits both phones show; equal codes mean nobody swapped a key.
    static func safetyCode(_ first: Data, _ second: Data) -> String {
        let digest = Array(SHA256.hash(data: Data("\(version)|safety".utf8) + first + second))
        let number = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        let text = String(format: "%06u", number)
        return "\(text.prefix(3)) \(text.suffix(3))"
    }
}

/// What a sealed message says. The server sees none of it, not even the kind.
struct SealedPayload: Codable, Equatable {
    var kind: String            // "text" | "photo" | "heartbeat"
    var text: String?
    var photoID: String?
    var bpm: Int?
}

/// A member's sealed profile: the name they chose and their recorded rhythm.
struct SealedProfile: Codable, Equatable {
    var name: String?
    var bpm: Int?
}
