import Foundation
import Network
import Observation
import SwiftUI
import UIKit

// MARK: - Types the Stage 2 screens were designed against
//
// Stage 2 (RelationshipShell, HomeView, ChatScreen, UsView) was written over the
// MLS-era `WatchlinkStore`. The MVP keeps that surface — messages, send,
// canSend, connectionAvailable, securityState — and backs it with
// `ChatBackend` (Firebase). The MLS store is parked on park/mls-e2ee.

enum SecurityState: Equatable {
    case notPaired, pairing, establishingSecureSession, secure
    case sessionUpdatePending
    case identityChanged, unavailable, error

    var canSend: Bool { self == .secure }
}

enum DeliveryState: Equatable { case pending, sending, sent, delivered, failed }

enum SecurityFailure: Error, Equatable { case unavailable, sessionNotSecure, emptyMessage, messageTooLarge, transportFailed, rejected }

struct LocalMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case text
        case photo(photoID: String)
        case heartbeat(bpm: Int)
        case voice(voiceID: String, seconds: Double, wave: [UInt8])
    }

    /// Who wrote the quoted message and a one-line preview of it.
    struct Quote: Equatable {
        let mine: Bool
        let snippet: String
    }

    struct Reaction: Equatable {
        let emoji: String
        let mine: Bool
    }

    let id: UUID
    let text: String
    let isMine: Bool
    let timestamp: Date
    var delivery: DeliveryState
    var kind: Kind = .text
    /// The message this one answers, and its quote as drawn on this phone.
    var replyTo: UUID?
    var quote: Quote?
    /// At most one per person (two people, two reactions).
    var reactions: [Reaction] = []
    /// Mine only: the latest of my messages the partner has had on screen.
    var seen = false

    /// One line for quotes and previews.
    var snippet: String {
        switch kind {
        case .text: return String(text.prefix(120))
        case .photo: return "📷 Fotoğraf"
        case .heartbeat(let bpm): return "💓 Kalp atışı · \(bpm) BPM"
        case .voice(_, let seconds, _):
            let total = Int(seconds.rounded())
            return "🎤 Sesli mesaj · \(total / 60):\(String(format: "%02d", total % 60))"
        }
    }

    init(id: UUID = UUID(), text: String, isMine: Bool, timestamp: Date = Date(),
         delivery: DeliveryState = .pending, kind: Kind = .text) {
        self.id = id; self.text = text; self.isMine = isMine
        self.timestamp = timestamp; self.delivery = delivery; self.kind = kind
    }
}

/// Connection wording (encryption is stated by EncryptionLabel, not here).
struct SecurityStatusView: View {
    let state: SecurityState
    var connected = true
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state == .secure && connected ? WatchlinkStyle.online : WatchlinkStyle.away)
                .frame(width: 6, height: 6)
            Text(Self.label(state, connected: connected)).font(.system(size: 12))
        }.foregroundStyle(WatchlinkStyle.secondary)
        .accessibilityElement(children: .combine)
    }

    static func label(_ state: SecurityState, connected: Bool) -> String {
        switch state {
        case .secure: return connected ? "Bağlı" : "Çevrimdışı"
        case .identityChanged: return "Hesap değişti"
        case .sessionUpdatePending: return "Güncelleniyor"
        case .pairing: return "Partner bekleniyor"
        case .establishingSecureSession: return "Bağlanıyor"
        case .notPaired: return "Eşleşmedi"
        case .unavailable: return "Kullanılamıyor"
        case .error: return "Bir şeyler ters gitti"
        }
    }
}

// MARK: - The store

/// One pair's conversation, as the Stage 2 screens expect it.
///
/// End-to-end encrypted: every payload is sealed with the pair's
/// `PairCrypto.Session` before it reaches the backend and opened here after.
///
/// Sends are optimistic: `send` appends the message at once (inside the
/// caller's animation, so it rises out of the composer) with a client-chosen
/// id, and the server copy replaces it when it arrives. Firestore queues
/// writes while offline, so sending is always allowed once paired.
@MainActor @Observable
final class WatchlinkStore {
    static let maxMessageBytes = 4000

    private(set) var messages: [LocalMessage] = []
    private(set) var connectionAvailable = true
    private(set) var pair: PairInfo
    /// A heartbeat the partner sent while the app was open; the shell plays it, then clears it.
    var incomingHeartbeat: Int?
    /// The partner is writing right now / has the conversation open.
    private(set) var partnerTyping = false
    private(set) var partnerHere = false

    var securityState: SecurityState { pair.isComplete ? .secure : .pairing }
    var canSend: Bool { securityState.canSend }
    /// Six digits that must match on both phones (see Us → Neredesiniz).
    var safetyCode: String { session.safetyCode }

    let myID: String
    var partnerID: String? { pair.memberIDs.first { $0 != myID } }
    var myName: String { profile(of: myID).name ?? "" }
    var partnerName: String { partnerID.map { profile(of: $0).name ?? "" } ?? "" }
    var myBPM: Int { profile(of: myID).bpm ?? 72 }
    var partnerBPM: Int { partnerID.flatMap { profile(of: $0).bpm } ?? 72 }

    /// Both calendars' next two weeks (opt-in, sealed).
    let agenda: SharedAgenda

    @ObservationIgnored private let backend: any ChatBackend
    @ObservationIgnored private let session: PairCrypto.Session
    @ObservationIgnored private var listener: (any ListenerToken)?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var server: [BackendMessage] = []
    @ObservationIgnored private var outbox: [UUID: LocalMessage] = [:]
    @ObservationIgnored private var opened: [String: SealedPayload?] = [:]
    @ObservationIgnored private var photoSenders: [String: String] = [:]
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var firstSnapshot = true
    @ObservationIgnored private let photoCache = NSCache<NSString, UIImage>()
    @ObservationIgnored private var voiceCache: [String: Data] = [:]
    /// My reactions sent but not yet back from the server: target id -> (reaction message id, emoji).
    @ObservationIgnored private var pendingReactions: [String: (id: String, emoji: String)] = [:]
    // Presence (mine is written, the partner's is observed).
    @ObservationIgnored private var presenceListener: (any ListenerToken)?
    @ObservationIgnored private var myPresence = SealedPresence()
    @ObservationIgnored private var lastPresenceWrite = Date.distantPast
    @ObservationIgnored private var viewing = false
    @ObservationIgnored private var partnerRead: String?
    @ObservationIgnored private var typingIdle: Task<Void, Never>?
    @ObservationIgnored private var hereBeat: Task<Void, Never>?
    @ObservationIgnored private var partnerTypingExpiry: Task<Void, Never>?
    @ObservationIgnored private var partnerHereExpiry: Task<Void, Never>?

    init(backend: any ChatBackend, pair: PairInfo, myID: String, session: PairCrypto.Session) {
        self.backend = backend
        self.pair = pair
        self.myID = myID
        self.session = session
        agenda = SharedAgenda(backend: backend, pairID: pair.id, myID: myID,
                              partnerID: pair.memberIDs.first { $0 != myID }, session: session)
        shareKeyWithExtension()
        agenda.partnerName = { [weak self] in self?.partnerName ?? "" }
    }

    func start() {
        guard listener == nil else { return }
        listener = backend.observeMessages(pairID: pair.id, limit: 300) { [weak self] messages in
            Task { @MainActor in self?.receive(messages) }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.connectionAvailable = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "watchlink.path"))
        self.monitor = monitor
        agenda.start()
        if let partnerID {
            presenceListener = backend.observePresence(pairID: pair.id, member: partnerID) { [weak self] sealed, at in
                Task { @MainActor in self?.receivePresence(sealed, at: at) }
            }
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        presenceListener?.cancel(); presenceListener = nil
        agenda.stop()
        for task in [typingIdle, hereBeat, partnerTypingExpiry, partnerHereExpiry] { task?.cancel() }
        monitor?.cancel(); monitor = nil
    }

    func update(pair: PairInfo) {
        self.pair = pair
        shareKeyWithExtension()
    }

    /// Lets the notification extension open this pair's pushes (and title them
    /// with the partner's name). Rewritten only when something changed.
    @ObservationIgnored private var sharedKey: SharedPairKey?
    private func shareKeyWithExtension() {
        let shared = SharedPairKey(pairID: pair.id, myID: myID, key: session.keyData, partnerName: partnerName)
        guard shared != sharedKey else { return }
        shared.save()
        sharedKey = shared
    }

    // MARK: Profile

    private func profile(of member: String) -> SealedProfile {
        guard let sealed = pair.sealedProfiles[member],
              let data = try? session.open(sealed, aad: session.profileAAD(of: member)),
              let profile = try? JSONDecoder().decode(SealedProfile.self, from: data) else { return SealedProfile() }
        return profile
    }

    /// Seals this member's name, rhythm and push address into the pair document.
    func saveProfile(name: String? = nil, bpm: Int? = nil, push: String? = nil) async {
        let current = profile(of: myID)
        var profile = current
        if let name { profile.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)) }
        if let bpm { profile.bpm = min(max(bpm, 40), 180) }
        if let push { profile.push = String(push.prefix(200)) }
        guard profile != current else { return }
        guard let data = try? JSONEncoder().encode(profile),
              let sealed = try? session.seal(data, aad: session.profileAAD(of: myID)) else { return }
        try? await backend.saveSealedProfile(sealed, pairID: pair.id)
    }

    func saveMyBPM(_ bpm: Int) async { await saveProfile(bpm: bpm) }

    /// This device's APNs token; only the partner's phone can read it.
    func savePushToken(_ token: String) async { await saveProfile(push: token) }

    // MARK: Presence

    /// The chat is on screen (and the app active): say so, keep it fresh, and mark what's read.
    func setViewing(_ isViewing: Bool) {
        guard isViewing != viewing else { return }
        viewing = isViewing
        myPresence.here = isViewing
        if !isViewing { myPresence.typing = false }
        if isViewing, let latest = latestReadable { myPresence.read = latest }
        writePresence()
        hereBeat?.cancel()
        guard isViewing else { return }
        // "Here" fades on the other phone after two minutes of silence; refresh well before.
        hereBeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self, self.viewing else { return }
                self.writePresence()
            }
        }
    }

    /// Called as the draft changes. Refreshed every few seconds while typing; clears
    /// itself after a pause, so a half-written draft doesn't say "typing" forever.
    func setTyping(_ typing: Bool) {
        typingIdle?.cancel()
        if typing {
            typingIdle = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.myPresence.typing else { return }
                self.myPresence.typing = false
                self.writePresence()
            }
        }
        let refresh = typing && Date().timeIntervalSince(lastPresenceWrite) > 4
        guard typing != myPresence.typing || refresh else { return }
        myPresence.typing = typing
        writePresence()
    }

    /// The newest message on the server: what "read up to" points at.
    private var latestReadable: String? { server.last(where: { !$0.pending })?.id }

    private func markReadIfViewing() {
        guard viewing, let latest = latestReadable, latest != myPresence.read else { return }
        myPresence.read = latest
        writePresence()
    }

    private func writePresence() {
        guard let data = try? JSONEncoder().encode(myPresence),
              let sealed = try? session.seal(data, aad: session.presenceAAD(of: myID)) else { return }
        lastPresenceWrite = Date()
        let backend = self.backend, pairID = pair.id
        Task { try? await backend.setPresence(sealed, pairID: pairID) }
    }

    private func receivePresence(_ sealed: Data?, at: Date?) {
        guard let sealed, let partnerID,
              let data = try? session.open(sealed, aad: session.presenceAAD(of: partnerID)),
              let presence = try? JSONDecoder().decode(SealedPresence.self, from: data) else { return }
        // Server time guards against a stale document (e.g. the app was killed mid-typing).
        let age = at.map { Date().timeIntervalSince($0) } ?? 0
        partnerTyping = presence.typing && age < 30
        partnerHere = presence.here && age < 120
        partnerTypingExpiry?.cancel()
        if partnerTyping {
            partnerTypingExpiry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(7))
                if !Task.isCancelled { self?.partnerTyping = false }
            }
        }
        partnerHereExpiry?.cancel()
        if partnerHere {
            partnerHereExpiry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(120))
                if !Task.isCancelled { self?.partnerHere = false }
            }
        }
        if partnerRead != presence.read {
            partnerRead = presence.read
            rebuild()
        }
    }

    // MARK: Sending

    /// Synchronous by design (Stage 2's composer clears the draft on success).
    func send(_ text: String, replyTo: UUID? = nil) -> Result<UUID, SecurityFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return .failure(.sessionNotSecure) }
        guard !trimmed.isEmpty else { return .failure(.emptyMessage) }
        guard trimmed.utf8.count <= Self.maxMessageBytes else { return .failure(.messageTooLarge) }
        var message = LocalMessage(text: trimmed, isMine: true, delivery: .sending)
        message.replyTo = replyTo
        enqueue(message, SealedPayload(kind: "text", text: trimmed, replyTo: replyTo?.uuidString))
        return .success(message.id)
    }

    /// Puts my reaction on a message, or takes it back when it's the same emoji.
    /// Sent as its own sealed message; it never shows as a bubble.
    func react(to target: UUID, emoji: String) {
        guard canSend else { return }
        let targetID = target.uuidString
        let current = messages.first { $0.id == target }?.reactions.first { $0.mine }?.emoji
        let chosen = current == emoji ? "" : emoji
        let id = UUID().uuidString
        let payload = SealedPayload(kind: "reaction", target: targetID, emoji: chosen)
        guard let data = try? JSONEncoder().encode(payload),
              let sealed = try? session.seal(data, aad: session.messageAAD(id: id, sender: myID)) else { return }
        pendingReactions[targetID] = (id, chosen)
        rebuild()
        let backend = self.backend, pairID = pair.id
        Task { @MainActor [weak self] in
            do {
                try await backend.sendSealed(sealed, id: id, pairID: pairID)
                // A reaction is worth a nudge; taking one back is not.
                if !chosen.isEmpty { await self?.notifyPartner(messageID: id) }
            } catch {
                if self?.pendingReactions[targetID]?.id == id { self?.pendingReactions[targetID] = nil }
                self?.rebuild()
            }
        }
    }

    func sendPhoto(_ data: Data) async -> Bool {
        // Leave room for the sealed box's 28 bytes of nonce + tag.
        guard canSend, let image = UIImage(data: data),
              let jpeg = PhotoCompressor.jpeg(from: image, maxBytes: PhotoCompressor.maxBytes - 64) else { return false }
        let photoID = UUID().uuidString
        guard let sealed = try? session.seal(jpeg, aad: session.photoAAD(id: photoID, sender: myID)) else { return false }
        photoCache.setObject(image, forKey: photoID as NSString)
        photoSenders[photoID] = myID
        let message = LocalMessage(text: "Fotoğraf", isMine: true, delivery: .sending, kind: .photo(photoID: photoID))
        enqueue(message, SealedPayload(kind: "photo", photoID: photoID)) { backend, pairID in
            try await backend.uploadSealedPhoto(sealed, id: photoID, pairID: pairID)
        }
        return true
    }

    func sendHeartbeat() {
        guard canSend else { return }
        let bpm = myBPM
        let message = LocalMessage(text: "Kalp atışı", isMine: true, delivery: .sending, kind: .heartbeat(bpm: bpm))
        enqueue(message, SealedPayload(kind: "heartbeat", bpm: bpm))
    }

    /// Seals and sends a voice message; the audio travels like a photo (its own
    /// sealed blob, bound to its id and sender), the message carries its length
    /// and waveform so the bubble draws at once.
    func sendVoice(_ recording: VoiceRecorder.Recording) -> Bool {
        guard canSend else { return false }
        let voiceID = UUID().uuidString
        guard let sealed = try? session.seal(recording.data, aad: session.voiceAAD(id: voiceID, sender: myID)),
              sealed.count <= PhotoCompressor.maxBytes else { return false }
        voiceCache[voiceID] = recording.data
        photoSenders[voiceID] = myID
        let message = LocalMessage(text: "Sesli mesaj", isMine: true, delivery: .sending,
                                   kind: .voice(voiceID: voiceID, seconds: recording.seconds, wave: recording.wave))
        enqueue(message, SealedPayload(kind: "voice", voiceID: voiceID, seconds: recording.seconds, wave: recording.wave)) { backend, pairID in
            try await backend.uploadSealedPhoto(sealed, id: voiceID, pairID: pairID)
        }
        return true
    }

    /// The opened audio of a voice message (downloaded once, then kept for the session).
    func voice(for voiceID: String) async -> Data? {
        if let cached = voiceCache[voiceID] { return cached }
        guard let sender = photoSenders[voiceID],
              let sealed = try? await backend.loadSealedPhoto(id: voiceID, pairID: pair.id),
              let data = try? session.open(sealed, aad: session.voiceAAD(id: voiceID, sender: sender)) else { return nil }
        voiceCache[voiceID] = data
        return data
    }

    // MARK: Photos

    func image(for photoID: String) async -> UIImage? {
        guard !photoID.isEmpty else { return nil }
        if let cached = photoCache.object(forKey: photoID as NSString) { return cached }
        guard let sender = photoSenders[photoID],
              let sealed = try? await backend.loadSealedPhoto(id: photoID, pairID: pair.id),
              let data = try? session.open(sealed, aad: session.photoAAD(id: photoID, sender: sender)),
              let image = UIImage(data: data) else { return nil }
        photoCache.setObject(image, forKey: photoID as NSString)
        return image
    }

    // MARK: Internals

    /// Seals `payload` under the message id and sends it; `before` runs first (photo upload).
    private func enqueue(_ message: LocalMessage, _ payload: SealedPayload,
                         before: ((any ChatBackend, String) async throws -> Void)? = nil) {
        outbox[message.id] = message
        rebuild()
        let id = message.id.uuidString
        let sealed = (try? JSONEncoder().encode(payload)).flatMap { try? session.seal($0, aad: session.messageAAD(id: id, sender: myID)) }
        let backend = self.backend, pairID = pair.id, localID = message.id
        Task { @MainActor [weak self] in
            do {
                guard let sealed else { throw PairCrypto.Failure.unreadable }
                try await before?(backend, pairID)
                try await backend.sendSealed(sealed, id: id, pairID: pairID)
                await self?.notifyPartner(messageID: id)
            } catch {
                self?.outbox[localID]?.delivery = .failed
                self?.rebuild()
            }
        }
    }

    /// Asks the push Worker to wake the partner's phone for this message. Best
    /// effort: if it fails, the message is still delivered and shows on open.
    private func notifyPartner(messageID: String) async {
        guard let endpoint = PushConfig.endpoint, let partnerID,
              let address = profile(of: partnerID).push, !address.isEmpty,
              let proof = try? await backend.idToken() else { return }
        var request = URLRequest(url: endpoint.appendingPathComponent("notify"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(proof)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(["pair": pair.id, "msg": messageID, "to": address])
        _ = try? await URLSession.shared.data(for: request)
    }

    private func open(_ message: BackendMessage) -> SealedPayload? {
        if let cached = opened[message.id] { return cached }
        let payload = (try? session.open(message.sealed, aad: session.messageAAD(id: message.id, sender: message.senderID)))
            .flatMap { try? JSONDecoder().decode(SealedPayload.self, from: $0) }
        opened[message.id] = payload
        if let photoID = payload?.photoID { photoSenders[photoID] = message.senderID }
        if let voiceID = payload?.voiceID { photoSenders[voiceID] = message.senderID }
        return payload
    }

    private func receive(_ incoming: [BackendMessage]) {
        if !firstSnapshot {
            for message in incoming where !seen.contains(message.id) && message.senderID != myID {
                let payload = open(message)
                if let payload, payload.kind == "heartbeat", let bpm = payload.bpm { incomingHeartbeat = bpm }
                // Their message arrived: whatever they were typing is sent.
                if payload?.kind != "reaction" { partnerTyping = false }
            }
        }
        firstSnapshot = false
        seen.formUnion(incoming.map(\.id))
        server = incoming
        // The server copy now stands in for the local echo.
        for message in incoming { if let id = UUID(uuidString: message.id) { outbox[id] = nil } }
        rebuild()
        markReadIfViewing()
    }

    private func rebuild() {
        // Reactions first: they decorate messages and are never shown on their own.
        var reactions: [String: [String: String]] = [:]   // target -> member -> emoji (latest wins)
        var visible: [BackendMessage] = []
        for message in server {
            if let payload = open(message), payload.kind == "reaction" {
                if let target = payload.target { reactions[target, default: [:]][message.senderID] = payload.emoji ?? "" }
            } else {
                visible.append(message)
            }
        }
        let arrived = Set(server.map(\.id))
        for (target, pending) in pendingReactions {
            if arrived.contains(pending.id) { pendingReactions[target] = nil } else { reactions[target, default: [:]][myID] = pending.emoji }
        }

        let fromServer = visible.map { message -> LocalMessage in
            let kind: LocalMessage.Kind
            let text: String
            let payload = open(message)
            switch payload {
            case let payload? where payload.kind == "text":
                kind = .text; text = payload.text ?? ""
            case let payload? where payload.kind == "photo":
                kind = .photo(photoID: payload.photoID ?? ""); text = "Fotoğraf"
            case let payload? where payload.kind == "heartbeat":
                kind = .heartbeat(bpm: payload.bpm ?? 72); text = "Kalp atışı"
            case let payload? where payload.kind == "voice" && payload.voiceID != nil:
                kind = .voice(voiceID: payload.voiceID ?? "", seconds: payload.seconds ?? 0,
                              wave: payload.wave ?? VoiceRecorder.wave([], bars: 40))
                text = "Sesli mesaj"
            default:
                kind = .text; text = "🔒 Bu mesaj bu telefonda açılamadı."
            }
            var local = LocalMessage(id: Self.uuid(for: message.id), text: text, isMine: message.senderID == myID,
                                     timestamp: message.createdAt ?? Date(),
                                     delivery: message.pending ? .sending : .sent, kind: kind)
            local.replyTo = payload?.replyTo.flatMap(UUID.init(uuidString:))
            return local
        }
        var all = (fromServer + outbox.values).sorted { $0.timestamp < $1.timestamp }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in all.indices {
            let id = all[index].id.uuidString
            all[index].reactions = (reactions[id] ?? [:])
                .filter { !$0.value.isEmpty }
                .sorted { $0.key < $1.key }
                .map { LocalMessage.Reaction(emoji: $0.value, mine: $0.key == myID) }
            if let replyTo = all[index].replyTo {
                all[index].quote = byID[replyTo].map { LocalMessage.Quote(mine: $0.isMine, snippet: $0.snippet) }
                    ?? LocalMessage.Quote(mine: false, snippet: "Eski bir mesaj")
            }
        }
        // "Seen": the newest of my sent messages at or before what the partner has read.
        if let read = partnerRead, let readAt = server.first(where: { $0.id == read })?.createdAt,
           let index = all.lastIndex(where: { $0.isMine && $0.delivery == .sent && $0.timestamp <= readAt }) {
            all[index].seen = true
        }
        messages = all
    }

    /// Our ids are UUID strings; anything else maps to a stable UUID from its bytes.
    private static func uuid(for id: String) -> UUID {
        if let uuid = UUID(uuidString: id) { return uuid }
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in id.utf8.enumerated() { bytes[index % 16] ^= byte &+ UInt8(truncatingIfNeeded: index) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
