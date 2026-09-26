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

    func sendApplicationMessage(_ text: String) throws {
        guard securityState == .secure, let device else { throw SecurityFailure.sessionNotSecure }
        try mapped { _ = try device.send(Data(text.utf8)) }
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
            case .unpaired: return PairingPayload(code: try device.scanInitiator(code))
            case .offered:
                try device.scanResponder(code)
                return nil
            default: throw SecurityFailure.rejected
            }
        }
    }

    func establish() throws {
        let device = try live()
        try mapped { _ = try device.addPeer() }
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
