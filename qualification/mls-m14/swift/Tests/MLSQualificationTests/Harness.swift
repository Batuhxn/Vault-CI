import Foundation
import MLSBridge
@testable import MLSQualification
import ProtectedStateStore
import XCTest

/// Synthetic devices with real Keychain items under unique test services.
final class Harness {
    var now: Int64 = 1_900_000_000
    let root: URL
    private var services: [String] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mls-m14-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var clock: () -> Int64 { { [unowned self] in self.now } }

    private func namespace(_ name: String) throws -> (String, URL) {
        let service = "dev.watchlink.m14.synthetic.\(UUID().uuidString).\(name)"
        services.append(service)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (service, directory)
    }

    func device(_ name: String, _ relay: Relay) throws -> Device {
        let (service, directory) = try namespace(name)
        return try Device.setup(name: name, service: service, directory: directory, relay: relay, clock: clock)
    }

    /// Destroys all live objects and recreates the device from durable state only.
    func reopen(_ device: Device, relay: Relay? = nil) throws -> Device {
        let fresh = Device(name: device.name, service: device.service, directory: device.directory,
                           relay: relay ?? device.relay, clock: clock)
        try fresh.open()
        return fresh
    }

    /// Copies the Keychain items and state file into an isolated namespace.
    func clone(_ device: Device, relay: Relay) throws -> Device {
        let (service, directory) = try namespace(device.name)
        try KeychainItem.add(service: service, account: "anchor",
                             data: KeychainItem.read(service: device.service, account: "anchor"))
        try KeychainItem.add(service: service + ".identity", account: "identity",
                             data: KeychainItem.read(service: device.identityService, account: "identity"))
        try FileManager.default.copyItem(at: device.directory.appendingPathComponent("state.aead"),
                                         to: directory.appendingPathComponent("state.aead"))
        let copy = Device(name: device.name, service: service, directory: directory, relay: relay, clock: clock)
        try copy.open()
        return copy
    }

    func pair(_ relay: Relay) throws -> (Device, Device) {
        let a = try device("alice", relay)
        let b = try device("bob", relay)
        try a.scanResponder(b.scanInitiator(a.startPairing()))
        guard case .accepted = try a.addPeer() else { throw Rejected(reason: "add commit not accepted") }
        try b.acceptWelcome(welcome(for: b))
        return (a, b)
    }

    func welcome(for device: Device) throws -> Envelope {
        try XCTUnwrap(device.relay.fetch(device.document.conversation!, recipient: device.name, after: 0)
            .first { $0.kind == "welcome" })
    }

    func versions(_ device: Device) throws -> (committed: UInt64, pending: UInt64?) {
        let anchor = try device.store.anchorStore.load()
        return (anchor.committedVersion, anchor.pendingVersion)
    }

    func rawClient(_ name: String) throws -> Client {
        Client(id: Data(name.utf8), signatureKeypair: try generateSignatureKeypair(cipherSuite: .curve25519Aes128),
               clientConfig: ClientConfig(groupStateStorage: MemoryGroupStorage(), useRatchetTreeExtension: true))
    }

    func cleanup() {
        for service in services {
            KeychainItem.delete(service: service, account: "anchor")
            KeychainItem.delete(service: service + ".identity", account: "identity")
        }
        try? FileManager.default.removeItem(at: root)
    }
}

/// In-memory storage for adversary/raw clients only (never a qualified device).
final class MemoryGroupStorage: GroupStateStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Data: Data] = [:]
    private var epochs: [Data: [UInt64: Data]] = [:]

    func state(groupId: Data) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return states[groupId]
    }

    func epoch(groupId: Data, epochId: UInt64) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return epochs[groupId]?[epochId]
    }

    func write(groupId: Data, groupState: Data, epochInserts: [EpochRecord], epochUpdates: [EpochRecord]) throws {
        lock.lock(); defer { lock.unlock() }
        states[groupId] = groupState
        for record in epochInserts + epochUpdates { epochs[groupId, default: [:]][record.id] = record.data }
    }

    func maxEpochId(groupId: Data) throws -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return epochs[groupId]?.keys.max()
    }
}

func application(_ conversation: Data, _ wire: Data, seq: UInt64, sender: String = "alice") -> Envelope {
    Envelope(conversation: conversation, seq: seq, kind: "application", base: nil, data: wire, sender: sender)
}

func XCTAssertThrows<E: Swift.Error, T>(_ expected: E.Type, _ expression: @autoclosure () throws -> T,
                                        _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
        XCTAssertTrue(error is E, "expected \(E.self), got \(error) \(message)", file: file, line: line)
    }
}
