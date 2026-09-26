import Foundation
import MLSBridge
import ProtectedStateStore
import Security

// MARK: - Real Keychain items (device-only, non-synchronizing)

public enum KeychainItem {
    static func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    public static func add(service: String, account: String, data: Data) throws {
        var attributes = query(service, account)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw ProtectedStateError.keychain(status) }
    }

    public static func read(service: String, account: String) throws -> Data {
        var attributes = query(service, account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw ProtectedStateError.keychain(status)
        }
        return data
    }

    public static func accessibility(service: String, account: String) -> String? {
        var attributes = query(service, account)
        attributes[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as? [String: Any])?[kSecAttrAccessible as String] as? String
    }

    public static func delete(service: String, account: String) {
        SecItemDelete(query(service, account) as CFDictionary)
    }
}

struct IdentityItem: Codable {
    var credentialId: Data
    var publicKey: Data
    var secretKey: Data
}

// MARK: - Fault injection

public final class Faults: @unchecked Sendable {
    /// Simulated process death: throws SimulatedCrash and suppresses cleanup.
    public var crashAt: String?
    /// Simulated storage failure at a callback point.
    public var failAt: String?
    public private(set) var crashed = false

    func hit(_ point: String) throws {
        if crashAt == point {
            crashed = true
            throw SimulatedCrash(point: point)
        }
        if failAt == point { throw Closed(reason: "injected storage failure at \(point)") }
    }
}

// MARK: - Transactional staging store

/// All callback mutations land in `staging`; only seal -> atomic replace ->
/// anchor commit (ProtectedStateStore) makes them durable.
public final class QualificationStore: @unchecked Sendable {
    public let anchorStore: KeychainStateAnchorStore
    public let faults: Faults
    let protected: ProtectedStateStore
    let clock: () -> Int64
    public private(set) var committed = StateDocument()
    public private(set) var staging: StateDocument?
    public internal(set) var callbackLog: [String] = []
    private var version: UInt64 = 0
    private var begunAt: UInt64 = 0
    private(set) var mutated = false
    private(set) var callbackFailed = false
    private(set) var replaced = false

    init(service: String, fileURL: URL, clock: @escaping () -> Int64) {
        let anchorStore = KeychainStateAnchorStore(service: service, account: "anchor")
        let faults = Faults()
        self.faults = faults
        self.anchorStore = anchorStore
        self.clock = clock
        protected = ProtectedStateStore(anchorStore: anchorStore, fileURL: fileURL) { point in
            switch point {
            case .beforeFileWrite: try faults.hit("sealed")
            case .afterFileWrite: try faults.hit("replaced")
            case .afterAnchorCommit: try faults.hit("anchored")
            }
        }
    }

    public var view: StateDocument { staging ?? committed }

    func create() throws {
        try protected.create()
        committed = StateDocument()
        try begin()
        try commit()
    }

    func load() throws {
        do {
            committed = try JSONDecoder().decode(StateDocument.self, from: protected.restore())
        } catch {
            throw Closed(reason: "local state unavailable or invalid")
        }
    }

    func begin() throws {
        guard staging == nil else { throw Closed(reason: "nested transaction") }
        version = try protected.reserve()
        begunAt = version - 1
        staging = committed
        mutated = false
        callbackFailed = false
        replaced = false
        try faults.hit("reserved")
    }

    func commit() throws {
        guard let document = staging else { throw Closed(reason: "missing transaction") }
        replaced = true  // from here on the operation is never releasable
        try protected.commit(opaqueMLSState: JSONEncoder().encode(document), version: version)
        committed = document
        staging = nil
    }

    /// Any document mutation, from a callback or from the state machine.
    func stage(_ body: (inout StateDocument) throws -> Void) throws {
        mutated = true
        guard var document = staging else {
            callbackFailed = true
            throw Closed(reason: "storage write outside a transaction")
        }
        try body(&document)
        staging = document
    }

    /// Wraps a mutation callback: any failure marks the transaction unreleasable.
    func callback<T>(_ name: String, _ body: () throws -> T) throws -> T {
        callbackLog.append(name)
        do {
            return try body()
        } catch {
            callbackFailed = true
            throw error
        }
    }

    /// True only if the operation provably stayed read-only.
    func releasable() -> Bool {
        guard let staging, !callbackFailed, !mutated, !replaced, staging == committed,
              let anchor = try? anchorStore.load() else { return false }
        return anchor.committedVersion == begunAt && anchor.pendingVersion == version
    }

    /// Clears ONLY the reservation; the committed version is unchanged.
    func release() throws {
        guard releasable() else { throw Closed(reason: "cannot prove the operation was read-only") }
        try protected.release(version: version)
        staging = nil
    }

    /// Callback or persistence failure: keep the fail-closed marker.
    func abandon() {
        staging = nil
    }
}

// MARK: - Foreign callbacks (P1 + existing group storage)

final class GroupCallbacks: GroupStateStorage, @unchecked Sendable {
    let store: QualificationStore

    init(_ store: QualificationStore) { self.store = store }

    func state(groupId: Data) throws -> Data? {
        store.view.groups[groupId]?.state
    }

    func epoch(groupId: Data, epochId: UInt64) throws -> Data? {
        store.view.groups[groupId]?.epochs[epochId]
    }

    func write(groupId: Data, groupState: Data, epochInserts: [EpochRecord], epochUpdates: [EpochRecord]) throws {
        try store.callback("group.write") {
            try store.stage { document in
                var group = document.groups[groupId] ?? GroupRecord(state: Data(), epochs: [:])
                for record in epochInserts {
                    guard group.epochs[record.id] == nil else { throw Closed(reason: "duplicate epoch insert") }
                    group.epochs[record.id] = record.data
                }
                for record in epochUpdates {
                    guard group.epochs[record.id] != nil else { throw Closed(reason: "update to absent epoch") }
                    group.epochs[record.id] = record.data
                }
                group.state = groupState
                // Retention: current epoch (group state) + exactly one prior epoch record.
                if let newest = group.epochs.keys.max() {
                    group.epochs = group.epochs.filter { $0.key >= newest }
                }
                document.groups[groupId] = group
            }
            try store.faults.hit("group-written")
        }
    }

    func maxEpochId(groupId: Data) throws -> UInt64? {
        store.view.groups[groupId]?.epochs.keys.max()
    }
}

final class KeyPackageCallbacks: KeyPackageStorage, @unchecked Sendable {
    let store: QualificationStore

    init(_ store: QualificationStore) { self.store = store }

    func insert(id: Data, data: Data) throws {
        try store.callback("kp.insert") {
            try store.stage { document in
                guard document.keyPackages.isEmpty else {
                    throw Closed(reason: "a key package is already outstanding")
                }
                // Opaque upstream bytes: stored and returned, never parsed here.
                document.keyPackages[id] = KeyPackageRecord(data: data, expires: store.clock() + keyPackageTTL)
            }
        }
    }

    func get(id: Data) throws -> Data? {
        store.callbackLog.append("kp.get")
        guard let record = store.view.keyPackages[id], record.expires > store.clock() else {
            return nil  // unknown, deleted, or expired: unusable
        }
        return record.data
    }

    func delete(id: Data) throws {
        try store.callback("kp.delete") {
            try store.faults.hit("kp-delete")
            try store.stage { $0.keyPackages[id] = nil }  // idempotent
        }
    }
}
