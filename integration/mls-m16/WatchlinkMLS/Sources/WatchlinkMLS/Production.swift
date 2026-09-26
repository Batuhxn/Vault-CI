import Foundation
import Security

// Production composition of the qualified Device (M1.6). Nothing here changes
// qualified behaviour: identity creation and restore go through the unchanged
// Device.setup/open/wipe paths.

/// The transport boundary. It only ever receives MLS wire bytes plus
/// non-secret routing/sequencing metadata. Its answers are sequencing input,
/// never cryptographic authority (Device re-checks every accepted commit).
public protocol RelaySequencer: AnyObject {
    func post(_ conversation: Data, kind: String, base: UInt64?, data: Data, sender: String) throws -> RelayStatus
    func entry(_ conversation: Data, seq: UInt64) throws -> Envelope
    func fetch(_ conversation: Data, recipient: String, after: UInt64) -> [Envelope]
}

/// The qualified relay model; production uses it only as a test-controlled stub.
extension Relay: RelaySequencer {}

extension RelayUnavailable {
    /// What a RelaySequencer throws when it cannot deliver (the qualified init is internal).
    public static var deliveryFailed: RelayUnavailable { RelayUnavailable() }
}

public enum InstallState: Equatable, Sendable {
    /// No Keychain item and no state file: first pairing may create an identity.
    case absent
    /// Protected data is unavailable (device locked); retry after unlock.
    case locked
    /// Something exists; only a successful restore may use it.
    case present
}

extension Device {
    /// Only errSecItemNotFound counts as absent, so a locked item or a leftover
    /// Keychain item after reinstall is never mistaken for a fresh install.
    public static func installState(service: String, directory: URL) -> InstallState {
        let statuses = [KeychainItem.readStatus(service: service, account: "anchor"),
                        KeychainItem.readStatus(service: service + ".identity", account: "identity")]
        if statuses.contains(errSecInteractionNotAllowed) { return .locked }
        let file = FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.aead").path)
        return statuses.allSatisfy { $0 == errSecItemNotFound } && !file ? .absent : .present
    }

    /// Explicit first pairing only. The fresh random credential id doubles as
    /// the non-secret relay sender name.
    public static func create(service: String, directory: URL, relay: any RelaySequencer,
                              clock: @escaping () -> Int64) throws -> Device {
        let name = randomID().map { String(format: "%02x", $0) }.joined()
        return try setup(name: name, service: service, directory: directory, relay: relay, clock: clock)
    }

    /// Restore only; never creates or repairs anything.
    public static func restore(service: String, directory: URL, relay: any RelaySequencer,
                               clock: @escaping () -> Int64) throws -> Device {
        let credentialId: Data
        do {
            credentialId = try JSONDecoder().decode(
                IdentityItem.self, from: KeychainItem.read(service: service + ".identity", account: "identity")
            ).credentialId
        } catch {
            throw Closed(reason: "local identity unavailable")
        }
        let device = Device(name: String(decoding: credentialId, as: UTF8.self), service: service,
                            directory: directory, relay: relay, clock: clock)
        try device.open()
        return device
    }
}
