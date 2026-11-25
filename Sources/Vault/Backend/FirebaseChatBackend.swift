import FirebaseAuth
import FirebaseFirestore
import Foundation

/// Firebase implementation of `ChatBackend`.
///
/// Data model (enforced by firebase/firestore.rules):
///   users/{uid}                     { fcmToken }                          self-only, write-only
///   codes/{code}                    { pairId, creator, expiresAt }        get-by-id only
///   pairs/{pairId}                  { members, createdAt, joinOpenUntil,
///                                     pubkeys.{uid}: bytes(32), sealed.{uid}: bytes }
///   pairs/{pairId}/messages/{id}    { sender, type: "e2e", ct: bytes, createdAt }
///   pairs/{pairId}/photos/{id}      { sender, image: bytes (sealed JPEG), createdAt }
///
/// Spark plan: no Cloud Storage, so sealed photos are bytes in their own
/// documents, fetched only when shown. Google sees routing metadata only.
@MainActor
final class FirebaseChatBackend: ChatBackend {
    private let db = Firestore.firestore()
    private let auth = Auth.auth()

    static let codeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static let joinWindow: TimeInterval = 14 * 60 // rules allow < 15 min
    static let maxPhotoBytes = 900 * 1024

    var currentUserID: String? { auth.currentUser?.uid }

    private func uid() throws -> String {
        guard let id = auth.currentUser?.uid else { throw BackendError.notSignedIn }
        return id
    }

    // MARK: Sign-in

    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?) async throws {
        let credential = OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: rawNonce, fullName: fullName)
        _ = try await auth.signIn(with: credential)
    }

    func signInForTesting() async throws {
        _ = try await auth.signInAnonymously()
    }

    func signOut() throws { try auth.signOut() }

    // MARK: Pairing

    func createPair(publicKey: Data) async throws -> (code: String, pairID: String) {
        let me = try uid()
        let pair = db.collection("pairs").document()
        let until = Timestamp(date: Date().addingTimeInterval(Self.joinWindow))
        try await pair.setData([
            "members": [me],
            "createdAt": FieldValue.serverTimestamp(),
            "joinOpenUntil": until,
            "pubkeys": [me: publicKey],
        ])
        // A collision only fails the create (rules forbid update), so retry a few times.
        for _ in 0..<5 {
            let code = String((0..<8).map { _ in Self.codeAlphabet.randomElement()! })
            do {
                try await db.collection("codes").document(code).setData([
                    "pairId": pair.documentID,
                    "creator": me,
                    "expiresAt": until,
                ])
                return (code, pair.documentID)
            } catch { continue }
        }
        throw BackendError.invalidCode
    }

    func joinPair(code rawCode: String, publicKey: Data) async throws {
        let me = try uid()
        let code = rawCode.uppercased().filter { Self.codeAlphabet.contains($0) }
        guard code.count == 8 else { throw BackendError.invalidCode }
        let snapshot: DocumentSnapshot
        do {
            snapshot = try await db.collection("codes").document(code).getDocument()
        } catch {
            throw BackendError.codeExpired // rules deny reads of expired codes
        }
        guard let pairID = snapshot.data()?["pairId"] as? String else { throw BackendError.invalidCode }
        do {
            // Membership and key arrive together, so a pair is never complete without both keys.
            try await db.collection("pairs").document(pairID).updateData([
                "members": FieldValue.arrayUnion([me]),
                "pubkeys.\(me)": publicKey,
            ])
        } catch {
            throw BackendError.pairFull
        }
    }

    func currentPairs() async throws -> [PairInfo] {
        let me = try uid()
        let result = try await db.collection("pairs")
            .whereField("members", arrayContains: me)
            .limit(to: 10)
            .getDocuments()
        return result.documents
            .sorted { ($0.get("createdAt") as? Timestamp)?.dateValue() ?? .distantPast
                    > ($1.get("createdAt") as? Timestamp)?.dateValue() ?? .distantPast }
            .compactMap(Self.pair(from:))
            .filter(\.isComplete)
    }

    func observePair(_ pairID: String, onChange: @escaping (PairInfo) -> Void) -> ListenerToken {
        let registration = db.collection("pairs").document(pairID).addSnapshotListener { snapshot, _ in
            guard let snapshot, let pair = Self.pair(from: snapshot) else { return }
            onChange(pair)
        }
        return FirestoreListener(registration)
    }

    // MARK: Messages

    func observeMessages(pairID: String, limit: Int, onChange: @escaping ([BackendMessage]) -> Void) -> ListenerToken {
        let registration = messages(pairID)
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
            .addSnapshotListener(includeMetadataChanges: true) { snapshot, _ in
                guard let snapshot else { return }
                onChange(snapshot.documents.compactMap(Self.message(from:)).reversed())
            }
        return FirestoreListener(registration)
    }

    func sendSealed(_ sealed: Data, id: String, pairID: String) async throws {
        try await messages(pairID).document(id).setData([
            "sender": try uid(),
            "type": "e2e",
            "ct": sealed,
            "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    func uploadSealedPhoto(_ sealed: Data, id: String, pairID: String) async throws {
        guard sealed.count <= Self.maxPhotoBytes else { throw BackendError.photoTooLarge }
        try await db.collection("pairs").document(pairID).collection("photos").document(id).setData([
            "sender": try uid(),
            "image": sealed,
            "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    func loadSealedPhoto(id: String, pairID: String) async throws -> Data {
        let snapshot = try await db.collection("pairs").document(pairID)
            .collection("photos").document(id).getDocument()
        guard let data = snapshot.data()?["image"] as? Data else { throw BackendError.noPair }
        return data
    }

    // MARK: Profile + push proof

    func saveSealedProfile(_ sealed: Data, pairID: String) async throws {
        let me = try uid()
        try await db.collection("pairs").document(pairID).updateData(["sealed.\(me)": sealed])
    }

    func idToken() async throws -> String {
        guard let user = auth.currentUser else { throw BackendError.notSignedIn }
        return try await user.getIDToken()
    }

    // MARK: Helpers

    private func messages(_ pairID: String) -> CollectionReference {
        db.collection("pairs").document(pairID).collection("messages")
    }

    private nonisolated static func pair(from snapshot: DocumentSnapshot) -> PairInfo? {
        guard let data = snapshot.data(), let members = data["members"] as? [String] else { return nil }
        let keys = (data["pubkeys"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Data }
        let sealed = (data["sealed"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Data }
        return PairInfo(id: snapshot.documentID, memberIDs: members, publicKeys: keys, sealedProfiles: sealed)
    }

    private nonisolated static func message(from snapshot: QueryDocumentSnapshot) -> BackendMessage? {
        let data = snapshot.data()
        // Only sealed messages exist from here on; older plaintext test messages are skipped.
        guard data["type"] as? String == "e2e",
              let sender = data["sender"] as? String,
              let sealed = data["ct"] as? Data else { return nil }
        // Pending server timestamps read as nil; estimate them so local echoes sort last.
        let created = (snapshot.get("createdAt", serverTimestampBehavior: .estimate) as? Timestamp)?.dateValue()
        return BackendMessage(id: snapshot.documentID, senderID: sender, sealed: sealed, createdAt: created,
                              pending: snapshot.metadata.hasPendingWrites)
    }
}

private final class FirestoreListener: ListenerToken {
    private var registration: (any ListenerRegistration)?
    init(_ registration: any ListenerRegistration) { self.registration = registration }
    func cancel() { registration?.remove(); registration = nil }
    deinit { registration?.remove() }
}
