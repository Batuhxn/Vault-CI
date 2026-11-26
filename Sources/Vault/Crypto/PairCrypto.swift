import CryptoKit
import Foundation
import Security

/// End-to-end encryption for one pair, built only on Apple's CryptoKit.
///
/// - Each member keeps an X25519 identity key in iCloud Keychain (end-to-end
///   encrypted by Apple; never uploaded to our server). Only the 32-byte public
///   key is published, inside the pair document, at pairing time.
/// - Both phones derive the same 256-bit key: X25519 shared secret ->
///   HKDF-SHA256 (salt: pair id, info: version + both public keys).
/// - Everything the server stores for the pair (message payloads, photos,
///   names, heartbeat rhythm) is sealed with ChaCha20-Poly1305. The
///   authenticated data binds each blob to its pair, sender and id, so the
///   server can't move a blob to another message or another sender.
/// - A short safety code (SHA-256 of both public keys) lets the two people
///   check, side by side, that nobody swapped a key in between.
///
/// Limits (MVP): one long-term key per pair, no forward secrecy. With iCloud
/// Keychain on, reinstalling or moving to a new iPhone keeps the key; with it
/// off, deleting the app deletes the key and the pair has to link again.
enum PairCrypto {
    static let version = "wl1"

    enum Failure: Error { case keychain(OSStatus), badPublicKey, missingKey, unreadable }

    // MARK: Identity (Keychain)

    /// This device's identity for `userID`, created on first use.
    static func identity(for userID: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        if let existing = try storedIdentity(for: userID) { return existing }
        try store(Curve25519.KeyAgreement.PrivateKey(), for: userID)
        // Read back: if iCloud delivered a key in the meantime, that one wins.
        guard let key = try storedIdentity(for: userID) else { throw Failure.missingKey }
        return key
    }

    #if DEBUG
    /// Demo mode (UI tour on the simulator) keeps its identity in memory, off the Keychain.
    nonisolated(unsafe) static var demoIdentities: [String: Curve25519.KeyAgreement.PrivateKey] = [:]
    #endif

    /// The identity lives in iCloud Keychain (end-to-end encrypted by Apple),
    /// so a reinstall or a new iPhone signed in to the same Apple Account gets
    /// the same key back and the conversation history stays readable. With
    /// iCloud Keychain off it simply stays on this device.
    static func storedIdentity(for userID: String) throws -> Curve25519.KeyAgreement.PrivateKey? {
        #if DEBUG
        if let demo = demoIdentities[userID] { return demo }
        #endif
        if let data = try? read(userID, synced: true) {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        // Builds before 0.1.2 kept a device-only copy: move it into iCloud Keychain.
        guard let legacy = try read(userID, synced: false) else { return nil }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: legacy)
        // Delete the device-only copy only once iCloud Keychain really holds the key.
        if (try? store(key, for: userID)) == true {
            SecItemDelete(baseQuery(userID, synced: false) as CFDictionary)
        }
        return key
    }

    private static func read(_ userID: String, synced: Bool) throws -> Data? {
        var query = baseQuery(userID, synced: synced)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure.keychain(status) }
        return data
    }

    /// True when stored in iCloud Keychain, false when it fell back to this device only.
    @discardableResult
    private static func store(_ key: Curve25519.KeyAgreement.PrivateKey, for userID: String) throws -> Bool {
        var query = baseQuery(userID, synced: true)
        query[kSecValueData as String] = key.rawRepresentation
        // Synced items can't be "this device only"; still unreadable until first unlock.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem { return true }
        // No iCloud Keychain available to this build (e.g. unusual device state): keep it on the device.
        var local = baseQuery(userID, synced: false)
        local[kSecValueData as String] = key.rawRepresentation
        local[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let fallback = SecItemAdd(local as CFDictionary, nil)
        guard fallback == errSecSuccess || fallback == errSecDuplicateItem else { throw Failure.keychain(status) }
        return false
    }

    private static func baseQuery(_ userID: String, synced: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.batuhxn.watchlink.identity",
         kSecAttrAccount as String: userID,
         kSecAttrSynchronizable as String: synced]
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
        func voiceAAD(id: String, sender: String) -> String { "\(PairCrypto.version)|voice|\(pairID)|\(sender)|\(id)" }
        func profileAAD(of member: String) -> String { "\(PairCrypto.version)|profile|\(pairID)|\(member)" }
        func presenceAAD(of member: String) -> String { "\(PairCrypto.version)|presence|\(pairID)|\(member)" }
        func agendaAAD(of member: String) -> String { "\(PairCrypto.version)|agenda|\(pairID)|\(member)" }
        func timetableAAD(of member: String) -> String { "\(PairCrypto.version)|timetable|\(pairID)|\(member)" }

        /// The raw pair key, handed to the notification extension through the
        /// shared Keychain group (this device only) so it can open pushes.
        var keyData: Data { key.withUnsafeBytes { Data($0) } }
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

    /// The notification extension rebuilds a session from the shared pair key.
    static func session(pairID: String, myID: String, keyData: Data) -> Session {
        Session(pairID: pairID, myID: myID, key: SymmetricKey(data: keyData), safetyCode: "")
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
    /// "text" | "photo" | "heartbeat" | "voice" | "reaction" | "private"
    /// (Özel Alan: pushes never show what it is).
    var kind: String
    var text: String?
    var photoID: String?
    var bpm: Int?
    /// Voice: the sealed audio blob's id, its length, and 40 waveform bars (0...255).
    var voiceID: String?
    var seconds: Double?
    var wave: [UInt8]?
    /// Reaction: the message it sits on and the emoji ("" takes it back).
    var target: String?
    var emoji: String?
    /// Reply: the message this one answers (the quote is drawn on the phone).
    var replyTo: String?
}

/// A member's live state, sealed: typing, has the chat open, has read up to a message.
/// The server only sees that the small presence document changed, and when.
struct SealedPresence: Codable, Equatable {
    var typing = false
    var here = false
    var read: String?
}

/// A member's sealed profile: the name they chose, their recorded rhythm and
/// the push address of their device (hex APNs token). Only the partner's phone
/// can read it, so nobody else learns where to send notifications.
struct SealedProfile: Codable, Equatable {
    var name: String?
    var bpm: Int?
    var push: String?
}
