import FirebaseAuth
import FirebaseFirestore
import Foundation

/// Firebase implementation of `ChatBackend`.
///
/// Data model (enforced by firebase/firestore.rules):
///   users/{uid}                     { fcmToken }                       self-only, write-only
///   codes/{code}                    { pairId, creator, expiresAt }     get-by-id only
///   pairs/{pairId}                  { members, createdAt, joinOpenUntil, bpm.{uid} }
///   pairs/{pairId}/messages/{id}    { sender, type, text | photoId | bpm, createdAt }
///   pairs/{pairId}/photos/{id}      { sender, image (bytes <= 900 KB), createdAt }
///
/// Spark plan: no Cloud Storage, so photos are JPEG bytes in their own
/// documents and are fetched only when shown.
///
/// Nothing here logs message text or image bytes.
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

    func signOut() throws { try auth.signOut() }

    // MARK: Pairing

    func createPair() async throws -> (code: String, pairID: String) {
        let me = try uid()
        let pair = db.collection("pairs").document()
        let until = Timestamp(date: Date().addingTimeInterval(Self.joinWindow))
        try await pair.setData([
            "members": [me],
            "createdAt": FieldValue.serverTimestamp(),
            "joinOpenUntil": until,
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

    func joinPair(code rawCode: String) async throws {
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
            try await db.collection("pairs").document(pairID).updateData([
                "members": FieldValue.arrayUnion([me]),
            ])
        } catch {
            throw BackendError.pairFull
        }
    }

    func currentPair() async throws -> PairInfo? {
        let me = try uid()
        let result = try await db.collection("pairs")
            .whereField("members", arrayContains: me)
            .limit(to: 5)
            .getDocuments()
        // Prefer a complete pair; an abandoned half-open pair is ignored.
        let pairs = result.documents.compactMap(Self.pair(from:))
        return pairs.first(where: \.isComplete) ?? pairs.first
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
            .addSnapshotListener(includeMetadataChanges: false) { snapshot, _ in
                guard let snapshot else { return }
                onChange(snapshot.documents.compactMap(Self.message(from:)).reversed())
            }
        return FirestoreListener(registration)
    }

    func sendText(_ text: String, pairID: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await post(pairID, ["type": "text", "text": String(trimmed.prefix(4000))])
    }

    func sendPhoto(_ jpeg: Data, pairID: String) async throws {
        guard jpeg.count <= Self.maxPhotoBytes else { throw BackendError.photoTooLarge }
        let me = try uid()
        let photo = db.collection("pairs").document(pairID).collection("photos").document()
        try await photo.setData([
            "sender": me,
            "image": jpeg,
            "createdAt": FieldValue.serverTimestamp(),
        ])
        try await post(pairID, ["type": "photo", "photoId": photo.documentID])
    }

    func loadPhoto(photoID: String, pairID: String) async throws -> Data {
        let snapshot = try await db.collection("pairs").document(pairID)
            .collection("photos").document(photoID).getDocument()
        guard let data = snapshot.data()?["image"] as? Data else { throw BackendError.noPair }
        return data
    }

    func sendHeartbeat(bpm: Int, pairID: String) async throws {
        try await post(pairID, ["type": "heartbeat", "bpm": min(max(bpm, 40), 180)])
    }

    // MARK: Heartbeat + push

    func saveMyBPM(_ bpm: Int, pairID: String) async throws {
        let me = try uid()
        try await db.collection("pairs").document(pairID).updateData(["bpm.\(me)": min(max(bpm, 40), 180)])
    }

    func registerPushToken(_ token: String) async throws {
        let me = try uid()
        try await db.collection("users").document(me).setData(["fcmToken": token])
    }

    // MARK: Helpers

    private func messages(_ pairID: String) -> CollectionReference {
        db.collection("pairs").document(pairID).collection("messages")
    }

    private func post(_ pairID: String, _ fields: [String: Any]) async throws {
        var data = fields
        data["sender"] = try uid()
        data["createdAt"] = FieldValue.serverTimestamp()
        try await messages(pairID).addDocument(data: data)
    }

    private nonisolated static func pair(from snapshot: DocumentSnapshot) -> PairInfo? {
        guard let data = snapshot.data(), let members = data["members"] as? [String] else { return nil }
        let bpm = (data["bpm"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
        return PairInfo(id: snapshot.documentID, memberIDs: members, bpm: bpm)
    }

    private nonisolated static func message(from snapshot: QueryDocumentSnapshot) -> BackendMessage? {
        let data = snapshot.data()
        guard let sender = data["sender"] as? String, let type = data["type"] as? String else { return nil }
        let kind: BackendMessageKind
        switch type {
        case "text":
            guard let text = data["text"] as? String else { return nil }
            kind = .text(text)
        case "photo":
            guard let photoID = data["photoId"] as? String else { return nil }
            kind = .photo(photoID: photoID)
        case "heartbeat":
            guard let bpm = (data["bpm"] as? NSNumber)?.intValue else { return nil }
            kind = .heartbeat(bpm: bpm)
        default:
            return nil
        }
        let created = (data["createdAt"] as? Timestamp)?.dateValue()
        return BackendMessage(id: snapshot.documentID, senderID: sender, kind: kind, createdAt: created)
    }
}

private final class FirestoreListener: ListenerToken {
    private var registration: (any ListenerRegistration)?
    init(_ registration: any ListenerRegistration) { self.registration = registration }
    func cancel() { registration?.remove(); registration = nil }
    deinit { registration?.remove() }
}
