import Foundation
import Observation
import WatchlinkMLS

// Product states make permission to send explicit. Transport availability alone
// never grants it.
enum SecurityState: Equatable {
    case notPaired, pairing, establishingSecureSession, secure
    /// Established, but an unresolved commit blocks application messages.
    case sessionUpdatePending
    /// `error` means local state cannot be restored: explicit reset required.
    case identityChanged, unavailable, error

    var canSend: Bool { self == .secure }
    var root: RootState {
        switch self {
        case .notPaired: return .welcome
        case .pairing: return .pairing
        case .establishingSecureSession: return .establishing
        case .secure, .sessionUpdatePending: return .chats
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

/// Transport-facing envelope: MLS wire bytes plus non-secret routing and
/// sequencing metadata only. It has no plaintext field.
typealias WireEnvelope = Envelope
/// The QR payload holds conversation id, nonce, identity pin and expiry; no secret.
struct PairingPayload: Equatable { let code: Data }
struct IdentityDescriptor: Equatable { let displayName: String }

enum SecurityFailure: Error, Equatable { case unavailable, sessionNotSecure, emptyMessage, transportFailed, rejected }

/// Semantic boundary: MLS epochs, commits, Welcome handling, KeyPackages,
/// identity pins and persistence ordering all stay behind it. The engine's
/// `securityState` is the only source of permission to send.
protocol CryptoEngine: AnyObject {
    var securityState: SecurityState { get }
    var localIdentity: IdentityDescriptor? { get }
    /// Protects, durably commits, and only then releases MLS ciphertext to the transport.
    func sendApplicationMessage(_ text: String) throws
    /// Authenticated plaintext for an application message; nil for protocol messages.
    func processIncoming(_ envelope: WireEnvelope) throws -> String?
    /// Explicit user action. Creates the local identity on first use.
    func startPairing() throws -> PairingPayload
    /// Initiator side returns this device's reply code; responder side returns nil.
    func acceptPairingCode(_ code: Data) throws -> PairingPayload?
    /// Responder side: add the pinned peer once its KeyPackage is published.
    func establish() throws
    /// Retransmits the exact persisted commit bytes.
    func retryPendingCommit() throws
    /// Explicit user action: destroys identity and state; next pairing starts fresh.
    func resetSecurity() throws
    /// Re-attempts restore after protected data becomes available (unlock).
    func reopenIfUnavailable()
}

final class UnavailableCryptoEngine: CryptoEngine {
    let securityState = SecurityState.unavailable
    let localIdentity: IdentityDescriptor? = nil
    func sendApplicationMessage(_ text: String) throws { throw SecurityFailure.unavailable }
    func processIncoming(_ envelope: WireEnvelope) throws -> String? { throw SecurityFailure.unavailable }
    func startPairing() throws -> PairingPayload { throw SecurityFailure.unavailable }
    func acceptPairingCode(_ code: Data) throws -> PairingPayload? { throw SecurityFailure.unavailable }
    func establish() throws { throw SecurityFailure.unavailable }
    func retryPendingCommit() throws { throw SecurityFailure.unavailable }
    func resetSecurity() throws { throw SecurityFailure.unavailable }
    func reopenIfUnavailable() {}
}

protocol IdentityStore { func localIdentity() -> IdentityDescriptor? }
protocol SecureMessageStore { func messages() -> [LocalMessage] }
typealias EnvelopeTransport = RelaySequencer

/// No relay is created or started in this production path (real relay: M1.7).
final class UnavailableEnvelopeTransport: EnvelopeTransport {
    func post(_ conversation: Data, kind: String, base: UInt64?, data: Data, sender: String) throws -> RelayStatus {
        throw RelayUnavailable()
    }
    func entry(_ conversation: Data, seq: UInt64) throws -> Envelope { throw RelayUnavailable() }
    func fetch(_ conversation: Data, recipient: String, after: UInt64) -> [Envelope] { [] }
}

@MainActor @Observable
final class WatchlinkStore {
    private(set) var securityState: SecurityState
    private(set) var messages: [LocalMessage]
    /// The only path from UI to transport is through the engine; the store holds no transport.
    @ObservationIgnored private let engine: any CryptoEngine

    var rootState: RootState { securityState.root }
    var canSend: Bool { securityState.canSend && engine.securityState.canSend }

    /// `securityState` is a presentation override; it can never exceed what the engine permits.
    init(securityState: SecurityState? = nil,
         messages: [LocalMessage] = [],
         engine: any CryptoEngine = UnavailableCryptoEngine()) {
        self.engine = engine
        self.messages = messages
        self.securityState = Self.clamp(securityState ?? engine.securityState, engine: engine.securityState)
    }

    /// Fail-closed engine states win over any presentation state, and only the
    /// engine can report `.secure`.
    private static func clamp(_ state: SecurityState, engine: SecurityState) -> SecurityState {
        switch engine {
        case .identityChanged, .unavailable, .error, .sessionUpdatePending: return engine
        default: return state == .secure && engine != .secure ? engine : state
        }
    }

    func refresh() { securityState = Self.clamp(engine.securityState, engine: engine.securityState) }
    func beginPairing() { if securityState == .notPaired { transition(to: .pairing) } }
    func cancelPairing() { if securityState == .pairing { transition(to: .notPaired) } }
    func showUnavailable() { securityState = .unavailable }
    func transition(to state: SecurityState) {
        // Identity review is intentionally unresolved; no state change can approve it yet.
        if securityState == .identityChanged && state == .secure { return }
        securityState = Self.clamp(state, engine: engine.securityState)
    }

    /// Called when the app becomes active: a locked-at-launch engine may now restore.
    func reopenIfUnavailable() {
        guard securityState == .unavailable else { return }
        engine.reopenIfUnavailable()
        refresh()
    }

    /// Explicit user action only.
    func resetSecurity() {
        try? engine.resetSecurity()
        messages = []
        refresh()
    }

    @discardableResult
    func send(_ rawText: String) -> Result<UUID, SecurityFailure> {
        guard canSend else { return .failure(.sessionNotSecure) }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.emptyMessage) }
        defer { refresh() }
        do {
            try engine.sendApplicationMessage(text)
        } catch SecurityFailure.transportFailed {
            // Protected and committed, but not delivered. Never retried as plaintext.
            messages.append(LocalMessage(text: text, isMine: true, delivery: .failed))
            return .failure(.transportFailed)
        } catch {
            return .failure(.unavailable)
        }
        let message = LocalMessage(text: text, isMine: true, delivery: .sent)
        messages.append(message)
        return .success(message.id)
    }

    /// Authenticated plaintext is shown only after the engine accepted the envelope.
    @discardableResult
    func receive(_ envelope: WireEnvelope) -> Result<Void, SecurityFailure> {
        defer { refresh() }
        do {
            if let text = try engine.processIncoming(envelope) {
                messages.append(LocalMessage(text: text, isMine: false, delivery: .delivered))
            }
            return .success(())
        } catch {
            return .failure(.rejected)
        }
    }

    func markDelivered(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id && $0.delivery == .sent }) else { return }
        messages[index].delivery = .delivered
    }
}
