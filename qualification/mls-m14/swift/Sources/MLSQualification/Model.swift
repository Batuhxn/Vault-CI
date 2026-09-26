import CryptoKit
import Foundation
import MLSBridge

// Qualification-only Swift port of the M1.4 Linux model. Not production code.
// MLSBridge exports its own `Error` type, so conformances name `Swift.Error`.

/// Local state unavailable, or an operation could not be proven read-only.
public struct Closed: Swift.Error, Equatable { public let reason: String }
/// Input refused; durable state unchanged; the session continues.
public struct Rejected: Swift.Error, Equatable { public let reason: String }
/// Security hard stop; persisted before it is thrown.
public struct Violation: Swift.Error, Equatable {
    public let security: SecurityState
    public let reason: String
}
/// Models process death at a fault point: no cleanup code may run.
public struct SimulatedCrash: Swift.Error, Equatable { public let point: String }
public struct RelayUnavailable: Swift.Error {}

public let keyPackageTTL: Int64 = 600
public let qrTTL: Int64 = 300
let idBytes = 16

public enum Lifecycle: String, Codable, Sendable {
    case unpaired, offered, joinPending, pinned, creating, established
}

public enum SecurityState: String, Codable, Sendable {
    case ok, identityChanged, halted
}

public struct Outbound: Codable, Equatable, Sendable {
    public var kind: String
    public var base: UInt64?
    public var data: Data
}

public struct PendingCommit: Codable, Equatable, Sendable {
    public var base: UInt64
    public var commitId: Data
}

public struct GroupRecord: Codable, Equatable, Sendable {
    public var state: Data
    public var epochs: [UInt64: Data]
}

public struct KeyPackageRecord: Codable, Equatable, Sendable {
    public var data: Data
    public var expires: Int64
}

/// Everything durable about a device except the Keychain items.
public struct StateDocument: Codable, Equatable, Sendable {
    public var lifecycle = Lifecycle.unpaired
    public var security = SecurityState.ok
    public var conversation: Data?
    public var ownNonce: Data?
    public var qrExpires: Int64?
    public var peerPin: Data?
    public var consumedNonces: [Data] = []
    public var groups: [Data: GroupRecord] = [:]
    public var keyPackages: [Data: KeyPackageRecord] = [:]
    public var pendingCommit: PendingCommit?
    public var outbound: [Outbound] = []
    public var lastSeq: UInt64 = 0
}

// MARK: - Identity pin

/// SHA-256("watchlink-identity-pin-v1" || u32be(len) || id || u32be(len) || key).
public func identityPin(credentialId: Data, signaturePublicKey: Data) -> Data {
    var input = Data("watchlink-identity-pin-v1".utf8)
    for part in [credentialId, signaturePublicKey] {
        withUnsafeBytes(of: UInt32(part.count).bigEndian) { input.append(contentsOf: $0) }
        input.append(part)
    }
    return Data(SHA256.hash(data: input))
}

public func memberPin(_ identity: SigningIdentity) throws -> Data {
    guard let identifier = identity.basicIdentifier() else {
        throw Violation(security: .identityChanged, reason: "non-basic credential")
    }
    return identityPin(credentialId: identifier, signaturePublicKey: identity.signaturePublicKey())
}

// MARK: - Mutual QR payload (data only; no camera)

public struct PairingCode: Codable, Equatable, Sendable {
    public var v: Int
    public var cid: Data
    public var nonce: Data
    public var pin: Data
    public var exp: Int64
}

public func makeQR(conversation: Data, nonce: Data, pin: Data, expires: Int64) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(PairingCode(v: 1, cid: conversation, nonce: nonce, pin: pin, exp: expires))
}

public func parseQR(_ data: Data, now: Int64, consumed: [Data]) throws -> PairingCode {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys) == ["v", "cid", "nonce", "pin", "exp"],
          let code = try? JSONDecoder().decode(PairingCode.self, from: data) else {
        throw Rejected(reason: "malformed pairing code")
    }
    guard code.v == 1 else { throw Rejected(reason: "unsupported pairing code") }
    guard code.cid.count == idBytes, code.nonce.count == idBytes, code.pin.count == 32 else {
        throw Rejected(reason: "malformed pairing code")
    }
    guard now < code.exp, code.exp <= now + qrTTL else { throw Rejected(reason: "expired pairing code") }
    guard !consumed.contains(code.nonce) else { throw Rejected(reason: "reused pairing nonce") }
    return code
}

// MARK: - Relay sequencer model (opaque; metadata is not authority)

public struct Envelope: Equatable, Sendable {
    public var conversation: Data
    public var seq: UInt64
    public var kind: String
    public var base: UInt64?
    public var data: Data
    public var sender: String

    public init(conversation: Data, seq: UInt64, kind: String, base: UInt64?, data: Data, sender: String) {
        self.conversation = conversation
        self.seq = seq
        self.kind = kind
        self.base = base
        self.data = data
        self.sender = sender
    }
}

public enum RelayStatus: Equatable, Sendable {
    case accepted(UInt64), stale(UInt64), ok(UInt64), reject
}

public final class Relay {
    struct Conversation {
        var current: UInt64 = 0
        var accepted: [UInt64: (commitId: Data, seq: UInt64)] = [:]
        var log: [Envelope] = []
        var retired = false
    }

    var conversations: [Data: Conversation] = [:]
    public var offline = false

    public init() {}

    public func copy() -> Relay {
        let relay = Relay()
        relay.conversations = conversations
        return relay
    }

    public func post(_ conversation: Data, kind: String, base: UInt64?, data: Data, sender: String) throws -> RelayStatus {
        if offline { throw RelayUnavailable() }
        var c = conversations[conversation] ?? Conversation()
        defer { conversations[conversation] = c }
        if c.retired { return .reject }
        let seq = UInt64(c.log.count + 1)
        if kind == "commit" {
            guard let base else { return .reject }
            let commitId = Data(SHA256.hash(data: data))
            if base < c.current, let accepted = c.accepted[base] {
                return accepted.commitId == commitId ? .accepted(accepted.seq) : .stale(accepted.seq)
            }
            guard base == c.current else { return .reject }
            c.accepted[base] = (commitId, seq)  // saved before acknowledging
            c.current += 1
        }
        c.log.append(Envelope(conversation: conversation, seq: seq, kind: kind, base: base, data: data, sender: sender))
        return kind == "commit" ? .accepted(seq) : .ok(seq)
    }

    public func entry(_ conversation: Data, seq: UInt64) -> Envelope {
        conversations[conversation]!.log[Int(seq) - 1]
    }

    public func fetch(_ conversation: Data, recipient: String, after: UInt64) -> [Envelope] {
        (conversations[conversation]?.log ?? []).filter { $0.seq > after && $0.sender != recipient }
    }

    public func retire(_ conversation: Data) {
        conversations[conversation, default: Conversation()].retired = true
    }

    /// Test hook: a malicious relay substitutes stored bytes.
    public func substitute(_ conversation: Data, seq: UInt64, data: Data) {
        conversations[conversation]!.log[Int(seq) - 1].data = data
    }
}
