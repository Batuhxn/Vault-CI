import CryptoKit
import Foundation
import Security

public enum ProtectedStateError: Error {
    case unavailable
    case alreadyExists
    case invalidAnchor
    case pendingTransaction
    case versionMismatch
    case malformedEnvelope
    case authenticationFailed
    case keychain(OSStatus)
}

public struct StateAnchor: Codable {
    public var storageKey: Data
    public var committedVersion: UInt64
    public var pendingVersion: UInt64?

    public init(storageKey: Data, committedVersion: UInt64, pendingVersion: UInt64?) {
        self.storageKey = storageKey
        self.committedVersion = committedVersion
        self.pendingVersion = pendingVersion
    }
}

public protocol StateAnchorStore: AnyObject {
    func create(_ anchor: StateAnchor) throws
    func load() throws -> StateAnchor
    func replace(_ anchor: StateAnchor) throws
}

/// One non-synchronizing Keychain item holds the random storage key and the
/// committed/pending version together. It is intentionally device-bound.
public final class KeychainStateAnchorStore: StateAnchorStore {
    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func create(_ anchor: StateAnchor) throws {
        var attributes = query
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = try JSONEncoder().encode(anchor)
        let result = SecItemAdd(attributes as CFDictionary, nil)
        if result == errSecDuplicateItem { throw ProtectedStateError.alreadyExists }
        guard result == errSecSuccess else { throw ProtectedStateError.keychain(result) }
    }

    public func load() throws -> StateAnchor {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess else { throw ProtectedStateError.keychain(status) }
        guard let data = result as? Data else { throw ProtectedStateError.invalidAnchor }
        return try JSONDecoder().decode(StateAnchor.self, from: data)
    }

    public func replace(_ anchor: StateAnchor) throws {
        let update: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(anchor)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecSuccess else { throw ProtectedStateError.keychain(status) }
    }
}

private struct StateEnvelope: Codable {
    let formatVersion: UInt8
    let stateVersion: UInt64
    let combined: Data
}

private struct StatePayload: Codable {
    let stateVersion: UInt64
    let opaqueMLSState: Data
}

/// Local storage only. The caller must reserve BEFORE mutating MLS state and
/// must not release an outbound envelope or acknowledge an inbound message
/// until commit returns. Any error leaves sending disabled for that session.
public final class ProtectedStateStore {
    private let anchorStore: any StateAnchorStore
    private let fileURL: URL
    private let formatVersion: UInt8 = 1

    public init(anchorStore: any StateAnchorStore, fileURL: URL) {
        self.anchorStore = anchorStore
        self.fileURL = fileURL
    }

    /// Explicit first-pairing operation. Restore never calls this.
    public func create() throws {
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        try anchorStore.create(StateAnchor(storageKey: bytes, committedVersion: 0, pendingVersion: nil))
    }

    public func reserve() throws -> UInt64 {
        var anchor = try checkedAnchor()
        guard anchor.pendingVersion == nil else { throw ProtectedStateError.pendingTransaction }
        guard anchor.committedVersion < UInt64.max else { throw ProtectedStateError.invalidAnchor }
        anchor.pendingVersion = anchor.committedVersion + 1
        try anchorStore.replace(anchor)
        return anchor.pendingVersion!
    }

    public func commit(opaqueMLSState: Data, version: UInt64) throws {
        var anchor = try checkedAnchor()
        guard anchor.pendingVersion == version,
              anchor.committedVersion + 1 == version else {
            throw ProtectedStateError.versionMismatch
        }
        let key = SymmetricKey(data: anchor.storageKey)
        let payload = try JSONEncoder().encode(
            StatePayload(stateVersion: version, opaqueMLSState: opaqueMLSState)
        )
        let sealed = try AES.GCM.seal(payload, using: key, authenticating: associatedData(version))
        guard let combined = sealed.combined else { throw ProtectedStateError.malformedEnvelope }
        let envelope = StateEnvelope(formatVersion: formatVersion, stateVersion: version, combined: combined)
        let encoded = try JSONEncoder().encode(envelope)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoded.write(to: fileURL, options: [.atomic, .completeFileProtection])
        anchor.committedVersion = version
        anchor.pendingVersion = nil
        try anchorStore.replace(anchor)
    }

    public func restore() throws -> Data {
        let anchor = try checkedAnchor()
        guard anchor.pendingVersion == nil else { throw ProtectedStateError.pendingTransaction }
        guard anchor.committedVersion > 0 else { throw ProtectedStateError.unavailable }
        let envelope: StateEnvelope
        do {
            envelope = try JSONDecoder().decode(StateEnvelope.self, from: Data(contentsOf: fileURL))
        } catch {
            throw ProtectedStateError.malformedEnvelope
        }
        guard envelope.formatVersion == formatVersion,
              envelope.stateVersion == anchor.committedVersion else {
            throw ProtectedStateError.versionMismatch
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: envelope.combined)
            let opened = try AES.GCM.open(
                sealed,
                using: SymmetricKey(data: anchor.storageKey),
                authenticating: associatedData(envelope.stateVersion)
            )
            let payload = try JSONDecoder().decode(StatePayload.self, from: opened)
            guard payload.stateVersion == envelope.stateVersion else {
                throw ProtectedStateError.versionMismatch
            }
            return payload.opaqueMLSState
        } catch {
            throw ProtectedStateError.authenticationFailed
        }
    }

    private func checkedAnchor() throws -> StateAnchor {
        let anchor = try anchorStore.load()
        guard anchor.storageKey.count == 32 else { throw ProtectedStateError.invalidAnchor }
        return anchor
    }

    private func associatedData(_ version: UInt64) -> Data {
        var data = Data("Watchlink M1.2 local state envelope v1".utf8)
        var bigEndian = version.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        return data
    }
}
