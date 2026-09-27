import CryptoKit
import Foundation
import WatchlinkMLS

/// Production CryptoEngine backed by the M1.5-qualified MLS Device and its
/// protected persistence (one Keychain anchor, one sealed state file). It adds
/// no cryptography and no fallback: any state it cannot prove safe maps to a
/// blocked SecurityState, and nothing is ever regenerated implicitly.
final class MLSCryptoEngine: CryptoEngine {
    static let productionService = "com.batuhxn.watchlink.mls"
    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "WatchlinkMLS", directoryHint: .isDirectory)
    }

    let service: String
    let directory: URL
    private let transport: any EnvelopeTransport
    private let clock: () -> Int64
    private(set) var device: Device?
    /// Set when restore could not produce a live device.
    private var failure: SecurityState?
    /// Count-only check that no application plaintext appears in its own wire bytes.
    private(set) var wireChecks = (passed: 0, failed: 0)

    init(service: String = MLSCryptoEngine.productionService,
         directory: URL = MLSCryptoEngine.defaultDirectory,
         transport: any EnvelopeTransport = UnavailableEnvelopeTransport(),
         clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.service = service
        self.directory = directory
        self.transport = transport
        self.clock = clock
        restore()
    }

    /// Restore only. Absent state means "not paired"; anything else must open
    /// consistently or messaging stays unavailable.
    private func restore() {
        device = nil
        failure = nil
        switch Device.installState(service: service, directory: directory) {
        case .absent:
            return
        case .locked:
            failure = .unavailable
        case .present:
            do {
                device = try Device.restore(service: service, directory: directory, relay: transport, clock: clock)
            } catch let violation as Violation {
                failure = violation.security == .identityChanged ? .identityChanged : .error
            } catch {
                failure = Device.installState(service: service, directory: directory) == .locked ? .unavailable : .error
            }
        }
    }

    var securityState: SecurityState {
        if let failure { return failure }
        guard let device else { return .notPaired }
        let document = device.document
        switch document.security {
        case .identityChanged: return .identityChanged
        case .halted: return .error
        case .ok: break
        }
        // A failed transaction closes the session and keeps the pending marker.
        guard device.client != nil else { return .error }
        switch document.lifecycle {
        case .unpaired: return .notPaired
        case .offered, .joinPending, .pinned: return .pairing
        case .creating: return device.group == nil ? .error : .establishingSecureSession
        case .established:
            guard device.group != nil else { return .error }
            return document.pendingCommit == nil ? .secure : .sessionUpdatePending
        }
    }

    var localIdentity: IdentityDescriptor? {
        guard failure == nil, let device else { return nil }
        let fingerprint = device.ownPin.prefix(4).map { String(format: "%02X", $0) }.joined()
        return IdentityDescriptor(displayName: fingerprint)
    }

    /// Returns the opaque outbound id (SHA-256 of the ciphertext, never of the
    /// plaintext). Once this returns, the exact ciphertext is durable in the
    /// committed MLS state and only ever retransmitted byte-identically.
    @discardableResult
    func sendApplicationMessage(_ text: String) throws -> Data {
        guard securityState == .secure, let device else { throw SecurityFailure.sessionNotSecure }
        let wire: Data
        do {
            wire = try mapped { try device.send(Data(text.utf8)) }
        } catch SecurityFailure.transportFailed {
            // Committed and queued; the transport worker delivers the exact bytes.
            guard let queued = device.store.committed.outbound.last(where: { $0.kind == "application" })?.data
            else { throw SecurityFailure.unavailable }
            wire = queued
        }
        checkWire(wire, Data(text.utf8))
        return Self.outboundID(wire)
    }

    private func checkWire(_ wire: Data, _ plaintext: Data) {
        guard plaintext.count >= 4 else { return }
        if wire.range(of: plaintext) == nil { wireChecks.passed += 1 } else { wireChecks.failed += 1 }
    }

    /// Drops every live MLS object and restores from durable state only.
    func reload() { restore() }

    static func outboundID(_ wire: Data) -> Data { Data(SHA256.hash(data: wire)) }

    /// Ids of application ciphertexts committed but not yet accepted by the relay.
    var pendingOutboundIDs: Set<Data> {
        Set(device?.store.committed.outbound.filter { $0.kind == "application" }.map { Self.outboundID($0.data) } ?? [])
    }

    /// The code this device should currently display, rebuilt deterministically
    /// from committed state (survives relaunch); nil when none is valid.
    func currentPairingCode() -> PairingPayload? {
        guard failure == nil, let device else { return nil }
        let document = device.document
        guard [.offered, .joinPending].contains(document.lifecycle), let conversation = document.conversation,
              let nonce = document.ownNonce, let expires = document.qrExpires, expires > clock(),
              let code = try? makeQR(conversation: conversation, nonce: nonce, pin: device.ownPin, expires: expires)
        else { return nil }
        return PairingPayload(code: code)
    }

    var pairingLifecycle: Lifecycle? { failure == nil ? device?.document.lifecycle : nil }

    func cancelPairing() throws {
        let device = try live()
        try mapped { try device.abortPairing() }
    }

    func processIncoming(_ envelope: WireEnvelope) throws -> String? {
        let device = try live()
        do {
            if envelope.kind == "welcome" {
                try device.acceptWelcome(envelope)  // only valid while joinPending
                return nil
            }
            return try device.receive(envelope).map { String(decoding: $0, as: UTF8.self) }
        } catch {
            throw SecurityFailure.rejected
        }
    }

    func startPairing() throws -> PairingPayload {
        let device = try live(creating: true)
        return try mapped { PairingPayload(code: try device.startPairing()) }
    }

    func acceptPairingCode(_ code: Data) throws -> PairingPayload? {
        let device = try live(creating: true)
        return try mapped {
            switch device.document.lifecycle {
            case .unpaired:
                do {
                    return PairingPayload(code: try device.scanInitiator(code))
                } catch is RelayUnavailable {
                    // KeyPackage committed and queued for the transport worker.
                    guard let reply = currentPairingCode() else { throw SecurityFailure.unavailable }
                    return reply
                }
            case .offered:
                try device.scanResponder(code)
                return nil
            default: throw SecurityFailure.rejected
            }
        }
    }

    func establish() throws {
        let device = try live()
        do {
            try mapped { _ = try device.addPeer() }
        } catch SecurityFailure.transportFailed {
            return  // commit + Welcome committed; delivery is the worker's job
        }
    }

    /// One synchronous engine step for the transport worker, run only against
    /// relay answers the worker already cached in `port`. Inbound items are
    /// applied in relay order: peer items sequenced before our accepted (or
    /// winning) commit are processed before that commit. Returns new plaintexts.
    func pump(_ port: RelayPort) -> [String] {
        guard failure == nil, let device, device.document.security == .ok, device.client != nil,
              let conversation = device.document.conversation else { return [] }
        var plaintexts: [String] = []
        func receive(before limit: UInt64) {
            for envelope in port.fetch(conversation, recipient: device.name, after: device.document.lastSeq)
            where envelope.seq < limit && !port.rejected.contains(envelope.seq)
                && ["application", "commit"].contains(envelope.kind) {
                if envelope.kind == "commit" && device.document.pendingCommit != nil { break }
                do {
                    if let text = try processIncoming(envelope) {
                        checkWire(envelope.data, Data(text.utf8))
                        plaintexts.append(text)
                    }
                } catch {
                    port.rejected.insert(envelope.seq)  // rejected input: no mutation; not retried every tick
                }
                guard securityState == .secure || securityState == .sessionUpdatePending else { return }
            }
        }
        switch device.document.lifecycle {
        case .pinned:
            if port.fetch(conversation, recipient: device.name, after: 0).contains(where: { $0.kind == "keypackage" }) {
                try? establish()
            }
        case .joinPending:
            if let welcome = port.fetch(conversation, recipient: device.name, after: 0).first(where: { $0.kind == "welcome" }) {
                _ = try? processIncoming(welcome)
            }
        case .established:
            if let commit = device.document.outbound.first(where: { $0.kind == "commit" }) {
                // Only peer items sequenced before our (decided) commit belong to this epoch.
                if let decision = port.decisionSeq(for: commit.data) { receive(before: decision) }
            } else {
                receive(before: .max)
            }
        default:
            break
        }
        if device.document.pendingCommit != nil {
            _ = try? device.sendPending()
            if device.document.pendingCommit == nil, device.document.lifecycle == .established { receive(before: .max) }
        }
        if device.document.outbound.contains(where: { $0.kind != "commit" }) { try? device.releaseOutbound() }
        return plaintexts
    }

    func retryPendingCommit() throws {
        let device = try live()
        try mapped { _ = try device.sendPending() }
    }

    func resetSecurity() throws {
        // Qualified wipe order: anchor (crypto-shred) first, then identity, then state.
        (device ?? Device(name: "", service: service, directory: directory, relay: transport, clock: clock)).wipe()
        restore()
        guard device == nil, failure == nil else { throw SecurityFailure.unavailable }
    }

    func reopenIfUnavailable() {
        if failure == .unavailable { restore() }
    }

    /// Creation happens only on an explicit pairing action with nothing installed.
    private func live(creating: Bool = false) throws -> Device {
        guard failure == nil else { throw SecurityFailure.unavailable }
        if let device { return device }
        guard creating else { throw SecurityFailure.sessionNotSecure }
        do {
            let created = try Device.create(service: service, directory: directory, relay: transport, clock: clock)
            device = created
            return created
        } catch {
            restore()  // leftovers from a partial create fail closed
            throw SecurityFailure.unavailable
        }
    }

    private func mapped<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let failure as SecurityFailure {
            throw failure
        } catch is RelayUnavailable {
            throw SecurityFailure.transportFailed
        } catch is Rejected {
            throw SecurityFailure.rejected
        } catch {
            throw SecurityFailure.unavailable
        }
    }
}
