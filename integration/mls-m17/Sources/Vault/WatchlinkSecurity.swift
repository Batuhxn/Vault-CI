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
    /// Opaque id of the committed ciphertext (never derived from plaintext).
    var outboundID: Data?

    init(id: UUID = UUID(), text: String, isMine: Bool, timestamp: Date = Date(), delivery: DeliveryState = .pending,
         outboundID: Data? = nil) {
        self.id = id; self.text = text; self.isMine = isMine
        self.timestamp = timestamp; self.delivery = delivery; self.outboundID = outboundID
    }
}

/// Transport-facing envelope: MLS wire bytes plus non-secret routing and
/// sequencing metadata only. It has no plaintext field.
typealias WireEnvelope = Envelope
/// The QR payload holds conversation id, nonce, identity pin and expiry; no secret.
struct PairingPayload: Equatable { let code: Data }
struct IdentityDescriptor: Equatable { let displayName: String }

enum SecurityFailure: Error, Equatable { case unavailable, sessionNotSecure, emptyMessage, messageTooLarge, transportFailed, rejected }

/// Semantic boundary: MLS epochs, commits, Welcome handling, KeyPackages,
/// identity pins and persistence ordering all stay behind it. The engine's
/// `securityState` is the only source of permission to send.
protocol CryptoEngine: AnyObject {
    var securityState: SecurityState { get }
    var localIdentity: IdentityDescriptor? { get }
    /// Protects and durably commits the exact ciphertext; delivery follows from
    /// committed state only. Returns the opaque outbound id.
    func sendApplicationMessage(_ text: String) throws -> Data
    /// Outbound ids committed but not yet accepted by the relay.
    var pendingOutboundIDs: Set<Data> { get }
    /// The pairing code this device should display now, if any.
    func currentPairingCode() -> PairingPayload?
    var pairingLifecycle: Lifecycle? { get }
    func cancelPairing() throws
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
    func sendApplicationMessage(_ text: String) throws -> Data { throw SecurityFailure.unavailable }
    let pendingOutboundIDs: Set<Data> = []
    func currentPairingCode() -> PairingPayload? { nil }
    let pairingLifecycle: Lifecycle? = nil
    func cancelPairing() throws { throw SecurityFailure.unavailable }
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

/// What the UI store may ask of the transport layer. No method carries plaintext.
@MainActor
protocol TransportHooks: AnyObject {
    /// Creates the per-conversation transport credential for a validated pairing code.
    func adopt(code: Data, creator: Bool) throws
    /// Marks every known conversation for relay retirement (reset / cancelled pairing).
    func retireAll() throws
    /// Requests an immediate delivery round.
    func kick()
}

/// No relay is created or started in this production path (real relay: M1.7).
final class UnavailableEnvelopeTransport: EnvelopeTransport {
    func post(_ conversation: Data, kind: String, base: UInt64?, data: Data, sender: String) throws -> RelayStatus {
        throw RelayUnavailable.deliveryFailed
    }
    func entry(_ conversation: Data, seq: UInt64) throws -> Envelope { throw RelayUnavailable.deliveryFailed }
    func fetch(_ conversation: Data, recipient: String, after: UInt64) -> [Envelope] { [] }
}

@MainActor @Observable
final class WatchlinkStore {
    private(set) var securityState: SecurityState
    private(set) var messages: [LocalMessage]
    /// False while the relay cannot be reached (content security is unaffected).
    var connectionAvailable = true
    /// Bumped whenever engine-derived pairing state may have changed.
    private(set) var revision = 0
    /// The only path from UI to transport is through the engine; the store holds no transport.
    @ObservationIgnored private let engine: any CryptoEngine
    /// Transport bookkeeping only (credentials, retire, wake-up); never receives plaintext.
    @ObservationIgnored var hooks: (any TransportHooks)?

    /// Text limit; ciphertext stays well inside the relay's 64 KiB envelope cap.
    static let maxMessageBytes = 16 * 1024
    /// Pairing screens are derived from engine state. Before any identity exists,
    /// the joiner's explicit "Scan Partner Code" choice is remembered here, so the
    /// periodic refresh can never snap the screen back (the M1.7 scanner race).
    private(set) var joining = false
    /// Camera scanner presentation; only user actions and scan results change it.
    private(set) var scanner: ScannerState = .idle
    @ObservationIgnored var camera: any CameraAccess = SystemCameraAccess()

    enum ScannerState: Equatable { case idle, requestingPermission, scanning, permissionDenied, failed }
    enum ScanOutcome: Equatable { case ignored, accepted, rejected }

    var rootState: RootState { securityState == .notPaired && joining ? .pairing : securityState.root }
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

    func refresh() {
        securityState = Self.clamp(engine.securityState, engine: engine.securityState)
        let pending = engine.pendingOutboundIDs
        for index in messages.indices where messages[index].delivery == .pending {
            if let id = messages[index].outboundID, !pending.contains(id) { messages[index].delivery = .sent }
        }
        revision += 1
    }

    /// Authenticated plaintexts produced by the engine for the transport worker.
    func ingest(_ plaintexts: [String]) {
        for text in plaintexts { messages.append(LocalMessage(text: text, isMine: false, delivery: .delivered)) }
        refresh()
    }

    enum PairingStep: Equatable {
        case none
        /// Show this code. The creator must then scan the partner's reply code.
        case showCode(Data, scanPartnerNext: Bool)
        case waiting
        case expired
    }

    var pairingStep: PairingStep {
        _ = revision
        switch engine.pairingLifecycle {
        case .offered?, .joinPending?:
            guard let code = engine.currentPairingCode() else { return .expired }
            return .showCode(code.code, scanPartnerNext: engine.pairingLifecycle == .offered)
        case .pinned?, .creating?: return .waiting
        default: return .none
        }
    }

    /// Explicit user action: create a link and show its code.
    @discardableResult
    func createLink() -> Bool {
        defer { refresh() }
        do {
            let payload = try engine.startPairing()
            try hooks?.adopt(code: payload.code, creator: true)
            hooks?.kick()
            securityState = Self.clamp(.pairing, engine: engine.securityState)
            return true
        } catch {
            return false
        }
    }

    /// Explicit user action: a scanned code (creator's link code or partner's reply code).
    @discardableResult
    func acceptScanned(_ code: Data) -> Bool {
        let joining = engine.pairingLifecycle == nil || engine.pairingLifecycle == .unpaired
        defer { refresh() }
        do {
            _ = try engine.acceptPairingCode(code)
            if joining { try hooks?.adopt(code: code, creator: false) }
            hooks?.kick()
            securityState = Self.clamp(.pairing, engine: engine.securityState)
            return true
        } catch {
            return false
        }
    }
    func beginPairing() { if securityState == .notPaired { joining = true } }

    /// One tap: request permission if needed, then present the scanner.
    func requestScan() async {
        guard scanner != .scanning, scanner != .requestingPermission else { return }
        switch camera.permission {
        case .authorized:
            scanner = .scanning
        case .notDetermined:
            scanner = .requestingPermission
            scanner = await camera.requestAccess() ? .scanning : .permissionDenied
        case .denied:
            scanner = .permissionDenied
        }
    }

    func cancelScan() { if scanner == .scanning || scanner == .requestingPermission { scanner = .idle } }
    func scannerFailed() { scanner = .failed }
    func acknowledgeScannerNotice() { if scanner == .permissionDenied || scanner == .failed { scanner = .idle } }

    /// A payload that is not a Watchlink pairing code keeps the scanner open;
    /// a Watchlink code is processed exactly once and closes it.
    func scanned(_ code: Data) -> ScanOutcome {
        guard scanner == .scanning, (try? JSONDecoder().decode(PairingCode.self, from: code)) != nil else {
            return .ignored
        }
        scanner = .idle
        return acceptScanned(code) ? .accepted : .rejected
    }
    func cancelPairing() {
        joining = false
        scanner = .idle
        if engine.pairingLifecycle.map({ [.offered, .joinPending, .pinned].contains($0) }) == true {
            try? hooks?.retireAll()
            try? engine.cancelPairing()
            refresh()
        }
        if securityState == .pairing { transition(to: .notPaired) }
    }
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
        joining = false
        scanner = .idle
        try? hooks?.retireAll()  // the relay will refuse the old conversation from now on
        try? engine.resetSecurity()
        messages = []
        refresh()
    }

    @discardableResult
    func send(_ rawText: String) -> Result<UUID, SecurityFailure> {
        guard canSend else { return .failure(.sessionNotSecure) }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.emptyMessage) }
        guard text.utf8.count <= Self.maxMessageBytes else { return .failure(.messageTooLarge) }
        defer { refresh() }
        let id: Data
        do {
            id = try engine.sendApplicationMessage(text)
        } catch SecurityFailure.transportFailed {
            // Engines that deliver synchronously may report a failed delivery. Never retried as plaintext.
            messages.append(LocalMessage(text: text, isMine: true, delivery: .failed))
            return .failure(.transportFailed)
        } catch {
            return .failure(.unavailable)
        }
        let message = LocalMessage(text: text, isMine: true, delivery: .pending, outboundID: id)
        messages.append(message)
        hooks?.kick()
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
