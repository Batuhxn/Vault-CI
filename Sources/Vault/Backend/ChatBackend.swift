import Foundation

/// The only surface the app uses to reach the server. Firebase lives behind
/// it (`FirebaseChatBackend`); a self-hosted relay or the parked MLS engine can
/// replace it later without touching the UI.
///
/// Rule: no file outside `Sources/Vault/Backend/` imports Firebase.

enum BackendMessageKind: Equatable {
    case text(String)
    /// Photo bytes live in pairs/{pairId}/photos/{photoID}; load lazily with `loadPhoto`.
    case photo(photoID: String)
    case heartbeat(bpm: Int)
}

struct BackendMessage: Identifiable, Equatable {
    let id: String
    let senderID: String
    let kind: BackendMessageKind
    /// `nil` while the server timestamp is still pending (local echo).
    let createdAt: Date?
    /// True until the server has acknowledged the write.
    var pending: Bool = false
}

struct PairInfo: Equatable {
    let id: String
    let memberIDs: [String]
    /// Recorded heartbeat of each member, keyed by member id.
    let bpm: [String: Int]
    /// Display name each member chose, keyed by member id.
    var names: [String: String] = [:]
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

    // Pairing.
    /// Creates a pair with only this user and returns an 8-character join code (15 min).
    func createPair() async throws -> (code: String, pairID: String)
    func joinPair(code: String) async throws
    /// The pair this user belongs to, if any.
    func currentPair() async throws -> PairInfo?
    func observePair(_ pairID: String, onChange: @escaping (PairInfo) -> Void) -> ListenerToken

    // Messages.
    func observeMessages(pairID: String, limit: Int, onChange: @escaping ([BackendMessage]) -> Void) -> ListenerToken
    /// `id` is chosen by the caller (a UUID string) so a local echo and the
    /// server copy are the same message.
    func sendText(_ text: String, id: String, pairID: String) async throws
    /// `jpeg` must already be compressed by the caller (`PhotoCompressor`, <= 900 KB).
    func sendPhoto(_ jpeg: Data, id: String, pairID: String) async throws
    func loadPhoto(photoID: String, pairID: String) async throws -> Data
    func sendHeartbeat(bpm: Int, id: String, pairID: String) async throws

    // Profile, heartbeat, push.
    func saveMyName(_ name: String, pairID: String) async throws
    func saveMyBPM(_ bpm: Int, pairID: String) async throws
    func registerPushToken(_ token: String) async throws
}
