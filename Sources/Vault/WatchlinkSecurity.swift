import Foundation
import Observation

// Product states make permission to send explicit. Transport availability alone
// never grants it.
enum SecurityState: Equatable {
    case notPaired, pairing, establishingSecureSession, secure
    case identityChanged, unavailable, error

    var canSend: Bool { self == .secure }
    var root: RootState {
        switch self {
        case .notPaired: return .welcome
        case .pairing: return .pairing
        case .establishingSecureSession: return .establishing
        case .secure: return .chats
        case .identityChanged: return .identityReview
        case .unavailable, .error: return .unavailable
        }
    }
}

enum RootState: Equatable { case welcome, pairing, establishing, chats, identityReview, unavailable }
enum DeliveryState: Equatable { case pending, sending, sent, delivered, failed }

struct LocalMessage: Identifiable, Equatable {
    let id: UUID
    let text: String
    let isMine: Bool
    let timestamp: Date
    var delivery: DeliveryState

    init(id: UUID = UUID(), text: String, isMine: Bool, timestamp: Date = Date(), delivery: DeliveryState = .pending) {
        self.id = id; self.text = text; self.isMine = isMine
        self.timestamp = timestamp; self.delivery = delivery
    }
}

/// Format and contents belong to the eventual approved engine.
struct WireEnvelope: Equatable { let opaqueBytes: Data }
struct PairingPayload { let displayValue: String? }
struct IdentityDescriptor: Equatable { let displayName: String }

enum SecurityFailure: Error, Equatable { case unavailable, sessionNotSecure, emptyMessage, transportFailed }

protocol CryptoEngine {
    var isAvailable: Bool { get }
    var localIdentity: IdentityDescriptor? { get }
    func encryptOutgoing(_ text: String) throws -> WireEnvelope
    func decryptIncoming(_ envelope: WireEnvelope) throws -> String
}

struct UnavailableCryptoEngine: CryptoEngine {
    let isAvailable = false
    let localIdentity: IdentityDescriptor? = nil
    func encryptOutgoing(_ text: String) throws -> WireEnvelope { throw SecurityFailure.unavailable }
    func decryptIncoming(_ envelope: WireEnvelope) throws -> String { throw SecurityFailure.unavailable }
}

protocol IdentityStore { func localIdentity() -> IdentityDescriptor? }
protocol SecureMessageStore { func messages() -> [LocalMessage] }
protocol PairingCoordinator { func beginPairing() -> PairingPayload? }
protocol EnvelopeTransport { func send(_ envelope: WireEnvelope) throws }

/// No relay is created or started in this production path.
struct UnavailableEnvelopeTransport: EnvelopeTransport {
    func send(_ envelope: WireEnvelope) throws { throw SecurityFailure.unavailable }
}

@MainActor @Observable
final class WatchlinkStore {
    private(set) var securityState: SecurityState
    private(set) var messages: [LocalMessage]
    @ObservationIgnored private let engine: any CryptoEngine
    @ObservationIgnored private let transport: any EnvelopeTransport

    var rootState: RootState { securityState.root }
    var canSend: Bool { securityState.canSend && engine.isAvailable }

    init(securityState: SecurityState = .notPaired,
         messages: [LocalMessage] = [],
         engine: any CryptoEngine = UnavailableCryptoEngine(),
         transport: any EnvelopeTransport = UnavailableEnvelopeTransport()) {
        self.securityState = securityState == .secure && !engine.isAvailable ? .unavailable : securityState
        self.messages = messages
        self.engine = engine
        self.transport = transport
    }

    func beginPairing() { if securityState == .notPaired { securityState = .pairing } }
    func cancelPairing() { if securityState == .pairing { securityState = .notPaired } }
    func showUnavailable() { securityState = .unavailable }
    func transition(to state: SecurityState) {
        // Identity review is intentionally unresolved; no state change can approve it yet.
        if securityState == .identityChanged && state == .secure { return }
        securityState = state == .secure && !engine.isAvailable ? .unavailable : state
    }

    @discardableResult
    func send(_ rawText: String) -> Result<UUID, SecurityFailure> {
        guard canSend else { return .failure(.sessionNotSecure) }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.emptyMessage) }
        let envelope: WireEnvelope
        do { envelope = try engine.encryptOutgoing(text) }
        catch { return .failure(.unavailable) }
        let message = LocalMessage(text: text, isMine: true)
        messages.append(message)
        let index = messages.count - 1
        messages[index].delivery = .sending
        do {
            try transport.send(envelope)
            messages[index].delivery = .sent
            return .success(message.id)
        } catch {
            messages[index].delivery = .failed
            return .failure(.transportFailed)
        }
    }

    func markDelivered(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id && $0.delivery == .sent }) else { return }
        messages[index].delivery = .delivered
    }
}
