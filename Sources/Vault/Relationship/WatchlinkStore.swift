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
    }

    let id: UUID
    let text: String
    let isMine: Bool
    let timestamp: Date
    var delivery: DeliveryState
    var kind: Kind = .text

    init(id: UUID = UUID(), text: String, isMine: Bool, timestamp: Date = Date(),
         delivery: DeliveryState = .pending, kind: Kind = .text) {
        self.id = id; self.text = text; self.isMine = isMine
        self.timestamp = timestamp; self.delivery = delivery; self.kind = kind
    }
}

/// Connection wording. The MVP has no end-to-end encryption, so nothing here
/// may claim it: the pair is private by access rules, not by cryptography.
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
        case .secure: return connected ? "Connected" : "Offline"
        case .identityChanged: return "Account changed"
        case .sessionUpdatePending: return "Updating"
        case .pairing: return "Waiting for partner"
        case .establishingSecureSession: return "Connecting"
        case .notPaired: return "Not paired"
        case .unavailable: return "Unavailable"
        case .error: return "Something went wrong"
        }
    }
}

// MARK: - The store

/// One pair's conversation, as the Stage 2 screens expect it.
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

    var securityState: SecurityState { pair.isComplete ? .secure : .pairing }
    var canSend: Bool { securityState.canSend }

    let myID: String
    var partnerID: String? { pair.memberIDs.first { $0 != myID } }
    var myName: String { pair.names[myID] ?? "" }
    var partnerName: String { partnerID.flatMap { pair.names[$0] } ?? "" }
    var myBPM: Int { pair.bpm[myID] ?? 72 }
    var partnerBPM: Int { partnerID.flatMap { pair.bpm[$0] } ?? 72 }

    @ObservationIgnored private let backend: any ChatBackend
    @ObservationIgnored private var listener: (any ListenerToken)?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var server: [BackendMessage] = []
    @ObservationIgnored private var outbox: [UUID: LocalMessage] = [:]
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var firstSnapshot = true
    @ObservationIgnored private let photoCache = NSCache<NSString, UIImage>()

    init(backend: any ChatBackend, pair: PairInfo, myID: String) {
        self.backend = backend
        self.pair = pair
        self.myID = myID
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
    }

    func stop() {
        listener?.cancel(); listener = nil
        monitor?.cancel(); monitor = nil
    }

    func update(pair: PairInfo) { self.pair = pair }

    // MARK: Sending

    /// Synchronous by design (Stage 2's composer clears the draft on success).
    func send(_ text: String) -> Result<UUID, SecurityFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return .failure(.sessionNotSecure) }
        guard !trimmed.isEmpty else { return .failure(.emptyMessage) }
        guard trimmed.utf8.count <= Self.maxMessageBytes else { return .failure(.messageTooLarge) }
        let message = LocalMessage(text: trimmed, isMine: true, delivery: .sending)
        enqueue(message) { backend, id, pairID in try await backend.sendText(trimmed, id: id, pairID: pairID) }
        return .success(message.id)
    }

    func sendPhoto(_ data: Data) async -> Bool {
        guard canSend, let image = UIImage(data: data), let jpeg = PhotoCompressor.jpeg(from: image) else { return false }
        let message = LocalMessage(text: "Photo", isMine: true, delivery: .sending, kind: .photo(photoID: ""))
        enqueue(message) { backend, id, pairID in try await backend.sendPhoto(jpeg, id: id, pairID: pairID) }
        return true
    }

    func sendHeartbeat() {
        guard canSend else { return }
        let bpm = myBPM
        let message = LocalMessage(text: "Heartbeat", isMine: true, delivery: .sending, kind: .heartbeat(bpm: bpm))
        enqueue(message) { backend, id, pairID in try await backend.sendHeartbeat(bpm: bpm, id: id, pairID: pairID) }
    }

    func saveMyBPM(_ bpm: Int) async {
        try? await backend.saveMyBPM(bpm, pairID: pair.id)
    }

    // MARK: Photos

    func image(for photoID: String) async -> UIImage? {
        guard !photoID.isEmpty else { return nil }
        if let cached = photoCache.object(forKey: photoID as NSString) { return cached }
        guard let data = try? await backend.loadPhoto(photoID: photoID, pairID: pair.id),
              let image = UIImage(data: data) else { return nil }
        photoCache.setObject(image, forKey: photoID as NSString)
        return image
    }

    // MARK: Internals

    private func enqueue(_ message: LocalMessage,
                         _ write: @escaping (any ChatBackend, String, String) async throws -> Void) {
        outbox[message.id] = message
        rebuild()
        let backend = self.backend, pairID = pair.id, id = message.id
        Task { @MainActor [weak self] in
            do {
                try await write(backend, id.uuidString, pairID)
            } catch {
                self?.outbox[id]?.delivery = .failed
                self?.rebuild()
            }
        }
    }

    private func receive(_ incoming: [BackendMessage]) {
        if !firstSnapshot {
            for message in incoming where !seen.contains(message.id) && message.senderID != myID {
                if case .heartbeat(let bpm) = message.kind { incomingHeartbeat = bpm }
            }
        }
        firstSnapshot = false
        seen.formUnion(incoming.map(\.id))
        server = incoming
        // The server copy now stands in for the local echo.
        for message in incoming { if let id = UUID(uuidString: message.id) { outbox[id] = nil } }
        rebuild()
    }

    private func rebuild() {
        let fromServer = server.map { message -> LocalMessage in
            let kind: LocalMessage.Kind
            let text: String
            switch message.kind {
            case .text(let body): kind = .text; text = body
            case .photo(let photoID): kind = .photo(photoID: photoID); text = "Photo"
            case .heartbeat(let bpm): kind = .heartbeat(bpm: bpm); text = "Heartbeat"
            }
            return LocalMessage(id: Self.uuid(for: message.id), text: text, isMine: message.senderID == myID,
                                timestamp: message.createdAt ?? Date(),
                                delivery: message.pending ? .sending : .sent, kind: kind)
        }
        messages = (fromServer + outbox.values).sorted { $0.timestamp < $1.timestamp }
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
