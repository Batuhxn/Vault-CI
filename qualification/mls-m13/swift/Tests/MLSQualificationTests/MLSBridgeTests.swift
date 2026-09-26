import Foundation
import Security
import XCTest
import MLSBridge
import ProtectedStateStore

private let suite = CipherSuite.curve25519Aes128
private let groupID = Data("synthetic-mls-group".utf8)

private final class OpaqueGroupStore: GroupStateStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var groupStates: [Data: Data] = [:]
    private var epochs: [Data: [UInt64: Data]] = [:]

    init(snapshot: GroupSnapshot? = nil) {
        if let snapshot {
            groupStates[snapshot.groupID] = snapshot.state
            epochs[snapshot.groupID] = snapshot.epochs
        }
    }

    func state(groupId: Data) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return groupStates[groupId]
    }

    func epoch(groupId: Data, epochId: UInt64) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return epochs[groupId]?[epochId]
    }

    func write(groupId: Data, groupState: Data, epochInserts: [EpochRecord], epochUpdates: [EpochRecord]) throws {
        lock.lock(); defer { lock.unlock() }
        var records = epochs[groupId] ?? [:]
        for record in epochInserts {
            guard records[record.id] == nil else { throw FixtureError.invalidEpoch }
            records[record.id] = record.data
        }
        for record in epochUpdates {
            guard records[record.id] != nil else { throw FixtureError.invalidEpoch }
            records[record.id] = record.data
        }
        groupStates[groupId] = groupState
        epochs[groupId] = records
    }

    func maxEpochId(groupId: Data) throws -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return epochs[groupId]?.keys.max()
    }

    func snapshot(groupId: Data) throws -> GroupSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard let state = groupStates[groupId] else { throw FixtureError.missingState }
        return GroupSnapshot(groupID: groupId, state: state, epochs: epochs[groupId] ?? [:])
    }
}

private enum FixtureError: Swift.Error {
    case invalidEpoch, missingState, invalidIdentity
}

private struct GroupSnapshot: Codable {
    let groupID: Data
    let state: Data
    let epochs: [UInt64: Data]
}

private struct PeerSnapshot: Codable {
    let id: Data
    let publicKey: Data
    let secretKey: Data
    let group: GroupSnapshot
}

private func receivedPlaintext(_ group: Group, wire: Data) throws -> Data {
    let result = try group.processIncomingMessage(message: Message.fromBytes(bytes: wire))
    guard case .applicationMessage(_, let data) = result else { throw FixtureError.missingState }
    return data
}

private final class SecurePeer {
    let id: Data
    let keypair: SignatureKeypair
    let callback: OpaqueGroupStore
    let client: Client
    let protected: ProtectedStateStore
    var group: Group?

    private init(id: Data, keypair: SignatureKeypair, callback: OpaqueGroupStore,
                 client: Client, protected: ProtectedStateStore, group: Group?) {
        self.id = id
        self.keypair = keypair
        self.callback = callback
        self.client = client
        self.protected = protected
        self.group = group
    }

    static func create(id: String, service: String, file: URL) throws -> SecurePeer {
        let anchor = KeychainStateAnchorStore(service: service, account: "anchor")
        let protected = ProtectedStateStore(anchorStore: anchor, fileURL: file)
        try protected.create()
        let keypair = try generateSignatureKeypair(cipherSuite: suite)
        XCTAssertTrue(try validateSignatureKeypair(keypair: keypair))
        let callback = OpaqueGroupStore()
        let bytes = Data(id.utf8)
        let client = Client(id: bytes, signatureKeypair: keypair,
                            clientConfig: ClientConfig(groupStateStorage: callback, useRatchetTreeExtension: true))
        return SecurePeer(id: bytes, keypair: keypair, callback: callback, client: client,
                          protected: protected, group: nil)
    }

    static func restore(service: String, file: URL, substitute: SignatureKeypair? = nil) throws -> SecurePeer {
        let anchor = KeychainStateAnchorStore(service: service, account: "anchor")
        let protected = ProtectedStateStore(anchorStore: anchor, fileURL: file)
        let snapshot = try JSONDecoder().decode(PeerSnapshot.self, from: protected.restore())
        let original = SignatureKeypair(cipherSuite: suite,
                                        publicKey: SignaturePublicKey(bytes: snapshot.publicKey),
                                        secretKey: SignatureSecretKey(bytes: snapshot.secretKey))
        let selected = substitute ?? original
        guard selected == original, try validateSignatureKeypair(keypair: selected) else {
            throw FixtureError.invalidIdentity
        }
        let callback = OpaqueGroupStore(snapshot: snapshot.group)
        let client = Client(id: snapshot.id, signatureKeypair: selected,
                            clientConfig: ClientConfig(groupStateStorage: callback, useRatchetTreeExtension: true))
        let group = try client.loadGroup(groupId: snapshot.group.groupID)
        return SecurePeer(id: snapshot.id, keypair: selected, callback: callback,
                          client: client, protected: protected, group: group)
    }

    func transact<T>(_ action: () throws -> T) throws -> T {
        let version = try protected.reserve()
        let result = try action()
        guard let group else { throw FixtureError.missingState }
        try group.writeToStorage()
        let snapshot = PeerSnapshot(id: id, publicKey: keypair.publicKey.bytes,
                                    secretKey: keypair.secretKey.bytes,
                                    group: try callback.snapshot(groupId: groupID))
        try protected.commit(opaqueMLSState: JSONEncoder().encode(snapshot), version: version)
        return result
    }
}

final class MLSBridgeTests: XCTestCase {
    private func temporaryFile(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mls-m13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    private func withKeychainService<T>(_ action: (String) throws -> T) rethrows -> T {
        let service = "dev.watchlink.m13.synthetic.\(UUID().uuidString)"
        defer {
            for suffix in [".alice", ".bob"] {
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                             kSecAttrService as String: service + suffix]
                SecItemDelete(query as CFDictionary)
            }
        }
        return try action(service)
    }

    func testWrongPrivateAndClaimedPublicIdentityRejected() throws {
        let original = try generateSignatureKeypair(cipherSuite: suite)
        let another = try generateSignatureKeypair(cipherSuite: suite)
        XCTAssertTrue(try validateSignatureKeypair(keypair: original))
        let wrongPrivate = SignatureKeypair(cipherSuite: suite, publicKey: original.publicKey,
                                            secretKey: another.secretKey)
        let wrongPublic = SignatureKeypair(cipherSuite: suite, publicKey: another.publicKey,
                                           secretKey: original.secretKey)
        let truncated = SignatureKeypair(cipherSuite: suite, publicKey: original.publicKey,
                                         secretKey: SignatureSecretKey(bytes: Data(original.secretKey.bytes.prefix(32))))
        XCTAssertFalse(try validateSignatureKeypair(keypair: wrongPrivate))
        XCTAssertFalse(try validateSignatureKeypair(keypair: wrongPublic))
        XCTAssertFalse(try validateSignatureKeypair(keypair: truncated))
    }

    func testSwiftWireRoundtripAndMalformedInput() throws {
        let aliceStorage = OpaqueGroupStore()
        let bobStorage = OpaqueGroupStore()
        let aliceKey = try generateSignatureKeypair(cipherSuite: suite)
        let bobKey = try generateSignatureKeypair(cipherSuite: suite)
        XCTAssertTrue(try validateSignatureKeypair(keypair: aliceKey))
        XCTAssertTrue(try validateSignatureKeypair(keypair: bobKey))
        let alice = Client(id: Data("alice".utf8), signatureKeypair: aliceKey,
                           clientConfig: ClientConfig(groupStateStorage: aliceStorage, useRatchetTreeExtension: true))
        let bob = Client(id: Data("bob".utf8), signatureKeypair: bobKey,
                         clientConfig: ClientConfig(groupStateStorage: bobStorage, useRatchetTreeExtension: true))
        let aliceGroup = try alice.createGroup(groupId: groupID)
        let keyPackageWire = try bob.generateKeyPackageMessage().toBytes()
        let output = try aliceGroup.addMembers(keyPackages: [Message.fromBytes(bytes: keyPackageWire)])
        let welcome = try XCTUnwrap(output.welcomeMessage)
        let welcomeWire = try welcome.toBytes()
        let commitWire = try output.commitMessage.toBytes()
        _ = try aliceGroup.processIncomingMessage(message: Message.fromBytes(bytes: commitWire))
        let bobGroup = try bob.joinGroup(ratchetTree: nil, welcomeMessage: Message.fromBytes(bytes: welcomeWire)).group

        let plaintext = Data("synthetic hello from Alice".utf8)
        let wire = try aliceGroup.encryptApplicationMessage(message: plaintext).toBytes()
        XCTAssertNil(wire.range(of: plaintext))
        XCTAssertEqual(try receivedPlaintext(bobGroup, wire: wire), plaintext)
        XCTAssertThrowsError(try receivedPlaintext(bobGroup, wire: wire))
        var corrupt = wire
        corrupt[corrupt.index(before: corrupt.endIndex)] ^= 1
        XCTAssertThrowsError(try receivedPlaintext(bobGroup, wire: corrupt))
        XCTAssertThrowsError(try Message.fromBytes(bytes: Data()))
        XCTAssertThrowsError(try Message.fromBytes(bytes: Data(wire.dropLast())))

        let reply = Data("synthetic reply from Bob".utf8)
        let replyWire = try bobGroup.encryptApplicationMessage(message: reply).toBytes()
        XCTAssertNil(replyWire.range(of: reply))
        XCTAssertEqual(try receivedPlaintext(aliceGroup, wire: replyWire), reply)

        let thirdStorage = OpaqueGroupStore()
        let third = Client(id: Data("third".utf8),
                           signatureKeypair: try generateSignatureKeypair(cipherSuite: suite),
                           clientConfig: ClientConfig(groupStateStorage: thirdStorage, useRatchetTreeExtension: true))
        let wrongGroup = try third.createGroup(groupId: Data("different-group".utf8))
        XCTAssertThrowsError(try receivedPlaintext(wrongGroup, wire: replyWire))
    }

    func testProtectedMLSRestartReplayAndMutation() throws {
        try withKeychainService { service in
            let aliceFile = try temporaryFile("alice.state")
            let bobFile = try temporaryFile("bob.state")
            let aliceService = service + ".alice"
            let bobService = service + ".bob"
            var alice: SecurePeer? = try SecurePeer.create(id: "alice", service: aliceService, file: aliceFile)
            var bob: SecurePeer? = try SecurePeer.create(id: "bob", service: bobService, file: bobFile)

            try alice!.transact { alice!.group = try alice!.client.createGroup(groupId: groupID) }
            let keyPackageWire = try bob!.client.generateKeyPackageMessage().toBytes()
            let output = try alice!.transact {
                try alice!.group!.addMembers(keyPackages: [Message.fromBytes(bytes: keyPackageWire)])
            }
            let commitWire = try output.commitMessage.toBytes()
            let welcomeWire = try XCTUnwrap(output.welcomeMessage).toBytes()
            try alice!.transact {
                _ = try alice!.group!.processIncomingMessage(message: Message.fromBytes(bytes: commitWire))
            }
            try bob!.transact {
                bob!.group = try bob!.client.joinGroup(ratchetTree: nil,
                    welcomeMessage: Message.fromBytes(bytes: welcomeWire)).group
            }
            let before = try alice!.transact {
                try alice!.group!.encryptApplicationMessage(message: Data("before restart".utf8)).toBytes()
            }
            let openedBefore = try bob!.transact { try receivedPlaintext(bob!.group!, wire: before) }
            XCTAssertEqual(openedBefore, Data("before restart".utf8))

            // Release all active Swift handles before recreating the clients.
            alice = nil
            bob = nil
            alice = try SecurePeer.restore(service: aliceService, file: aliceFile)
            bob = try SecurePeer.restore(service: bobService, file: bobFile)
            let after = try bob!.transact {
                try bob!.group!.encryptApplicationMessage(message: Data("after restart".utf8)).toBytes()
            }
            let openedAfter = try alice!.transact { try receivedPlaintext(alice!.group!, wire: after) }
            XCTAssertEqual(openedAfter, Data("after restart".utf8))
            XCTAssertThrowsError(try bob!.transact { try receivedPlaintext(bob!.group!, wire: before) })

            alice = nil
            bob = nil
            var mutated = try Data(contentsOf: aliceFile)
            mutated[mutated.index(before: mutated.endIndex)] ^= 1
            try mutated.write(to: aliceFile, options: [.atomic, .completeFileProtection])
            XCTAssertThrowsError(try SecurePeer.restore(service: aliceService, file: aliceFile))
            let replacement = try generateSignatureKeypair(cipherSuite: suite)
            XCTAssertThrowsError(try SecurePeer.restore(service: bobService, file: bobFile,
                                                        substitute: replacement))
        }
    }
}
