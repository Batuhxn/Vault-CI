import Foundation

/// The only surface the app uses to reach the server. Firebase lives behind
/// it (`FirebaseChatBackend`); a self-hosted relay or the parked MLS engine can
/// replace it later without touching the UI.
///
/// End-to-end encrypted: everything that crosses this boundary about a pair's
/// content is already sealed by `PairCrypto` (messages, photos, profiles). The
/// backend only moves opaque bytes plus routing metadata (pair, sender, time).
///
/// Rule: no file outside `Sources/Vault/Backend/` imports Firebase.

struct BackendMessage: Identifiable, Equatable {
    let id: String
    let senderID: String
    /// ChaCha20-Poly1305 combined box (nonce + ciphertext + tag) of a `SealedPayload`.
    let sealed: Data
    /// `nil` while the server timestamp is still pending (local echo).
    let createdAt: Date?
    /// True until the server has acknowledged the write.
    var pending: Bool = false
}

struct PairInfo: Equatable {
    let id: String
    let memberIDs: [String]
    /// Each member's X25519 public key (32 bytes), published at pairing.
    var publicKeys: [String: Data] = [:]
    /// Each member's sealed `SealedProfile` (name, rhythm).
    var sealedProfiles: [String: Data] = [:]
    var isComplete: Bool { memberIDs.count == 2 }
}

enum BackendError: Error, Equatable {
    case notSignedIn, noPair, invalidCode, codeExpired, pairFull, photoTooLarge
}

/// Cancels a live listener when released or cancelled.
protocol ListenerToken: AnyObject { func cancel() }

@MainActor
protocol ChatBackend: AnyObject {
    var currentUserID: String? { get }

    // Sign-in (Sign in with Apple; the view layer runs ASAuthorization).
    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?) async throws
    /// Test devices only (hidden on the welcome screen): a second account on a
    /// device that shares the owner's Apple Account, e.g. an iPad.
    func signInForTesting() async throws
    func signOut() throws

    // Pairing. Each side publishes its public key with the create / join.
    /// Creates a pair with only this user and returns an 8-character join code (15 min).
    func createPair(publicKey: Data) async throws -> (code: String, pairID: String)
    func joinPair(code: String, publicKey: Data) async throws
    /// Complete pairs this user belongs to, newest first.
    func currentPairs() async throws -> [PairInfo]
    func observePair(_ pairID: String, onChange: @escaping (PairInfo) -> Void) -> ListenerToken

    // Messages (sealed).
    func observeMessages(pairID: String, limit: Int, onChange: @escaping ([BackendMessage]) -> Void) -> ListenerToken
    /// `id` is chosen by the caller (a UUID string) and is part of the sealed
    /// box's authenticated data, so the server can't move the box.
    func sendSealed(_ sealed: Data, id: String, pairID: String) async throws
    /// Stores a sealed photo under a caller-chosen id (also bound into the box).
    func uploadSealedPhoto(_ sealed: Data, id: String, pairID: String) async throws
    func loadSealedPhoto(id: String, pairID: String) async throws -> Data

    // Profile (sealed name + rhythm), push.
    func saveSealedProfile(_ sealed: Data, pairID: String) async throws
    func registerPushToken(_ token: String) async throws
}
