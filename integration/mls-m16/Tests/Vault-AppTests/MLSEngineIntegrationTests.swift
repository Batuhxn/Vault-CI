import MLSBridge
import ProtectedStateStore
import Security
@testable import WatchlinkMLS
import XCTest

// M1.6: the production CryptoEngine (MLSCryptoEngine) over the qualified MLS
// core, with real simulator Keychain items under unique test services and the
// qualified relay model as the test-controlled transport. Synthetic data only.

private final class TestClock: @unchecked Sendable { var now: Int64 = 1_900_000_000 }

/// Raw adversary clients only; never used by an engine.
private final class NullGroupStorage: GroupStateStorage, @unchecked Sendable {
    func state(groupId: Data) throws -> Data? { nil }
    func epoch(groupId: Data, epochId: UInt64) throws -> Data? { nil }
    func write(groupId: Data, groupState: Data, epochInserts: [EpochRecord], epochUpdates: [EpochRecord]) throws {}
    func maxEpochId(groupId: Data) throws -> UInt64? { nil }
}

/// Forwards to the relay model and lets a test observe the instant of release.
private final class ProbeTransport: RelaySequencer {
    let relay: Relay
    var onPost: (() -> Void)?
    private(set) var posts = 0
    init(_ relay: Relay) { self.relay = relay }
    func post(_ conversation: Data, kind: String, base: UInt64?, data: Data, sender: String) throws -> RelayStatus {
        posts += 1
        onPost?()
        return try relay.post(conversation, kind: kind, base: base, data: data, sender: sender)
    }
    func entry(_ conversation: Data, seq: UInt64) throws -> Envelope { relay.entry(conversation, seq: seq) }
    func fetch(_ conversation: Data, recipient: String, after: UInt64) -> [Envelope] {
        relay.fetch(conversation, recipient: recipient, after: after)
    }
}

@MainActor
final class MLSEngineIntegrationTests: XCTestCase {
    private let marker = "M16-PLAINTEXT-MARKER-7f3a"
    private let clock = TestClock()
    private var root: URL!
    private var services: [String] = []

    private struct Slot { let service: String; let directory: URL }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("m16-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for service in services {
            KeychainItem.delete(service: service, account: "anchor")
            KeychainItem.delete(service: service + ".identity", account: "identity")
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func slot() -> Slot {
        let service = "com.batuhxn.watchlink.m16test.\(UUID().uuidString)"
        services.append(service)
        return Slot(service: service, directory: root.appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    private func engine(_ slot: Slot, _ transport: any EnvelopeTransport) -> MLSCryptoEngine {
        let clock = clock
        return MLSCryptoEngine(service: slot.service, directory: slot.directory, transport: transport,
                               clock: { clock.now })
    }

    private func stateFile(_ slot: Slot) -> URL { slot.directory.appendingPathComponent("state.aead") }

    private func anchor(_ slot: Slot) throws -> StateAnchor {
        try KeychainStateAnchorStore(service: slot.service, account: "anchor").load()
    }

    private func all(_ relay: Relay, _ engine: MLSCryptoEngine) throws -> [Envelope] {
        relay.fetch(try XCTUnwrap(engine.device?.document.conversation), recipient: "", after: 0)
    }

    private func welcome(_ relay: Relay, for engine: MLSCryptoEngine) throws -> Envelope {
        try XCTUnwrap(all(relay, engine).first { $0.kind == "welcome" })
    }

    /// Mutual QR pairing through the production engine API only.
    private func pair(_ relay: Relay) throws -> (MLSCryptoEngine, MLSCryptoEngine, Slot, Slot) {
        let (sa, sb) = (slot(), slot())
        let a = engine(sa, relay), b = engine(sb, relay)
        let offer = try a.startPairing()
        let reply = try XCTUnwrap(b.acceptPairingCode(offer.code))
        XCTAssertNil(try a.acceptPairingCode(reply.code))
        try a.establish()
        XCTAssertNil(try b.processIncoming(welcome(relay, for: b)))
        XCTAssertEqual(a.securityState, .secure)
        XCTAssertEqual(b.securityState, .secure)
        return (a, b, sa, sb)
    }

    private func lastApplication(_ relay: Relay, _ engine: MLSCryptoEngine) throws -> Envelope {
        try XCTUnwrap(all(relay, engine).last { $0.kind == "application" })
    }

    // MARK: A. Engine boundary

    func test01UnpairedEngineCannotSendAndCreatesNothing() throws {
        let s = slot()
        let relay = Relay()
        let a = engine(s, relay)
        XCTAssertEqual(a.securityState, .notPaired)
        XCTAssertNil(a.device)
        XCTAssertEqual(Device.installState(service: s.service, directory: s.directory), .absent, "restore never creates")
        let store = WatchlinkStore(engine: a)
        XCTAssertFalse(store.canSend)
        if case .success = store.send(marker) { XCTFail("unpaired engine sent") }
        XCTAssertThrowsError(try a.sendApplicationMessage(marker))
        XCTAssertTrue(relay.conversations.isEmpty)
    }

    func test02TransportSeesOnlyMLSCiphertext() throws {
        let relay = Relay()
        let (a, _, _, _) = try pair(relay)
        let store = WatchlinkStore(engine: a)
        guard case .success = store.send(marker) else { return XCTFail("send failed") }
        let envelope = try lastApplication(relay, a)
        XCTAssertNil(envelope.data.range(of: Data(marker.utf8)), "no plaintext on the wire")
        XCTAssertNoThrow(try Message.fromBytes(bytes: envelope.data), "upstream MLS codec parses the wire bytes")
        // Structural: the transport-facing type has exactly these non-plaintext fields.
        XCTAssertEqual(Mirror(reflecting: envelope).children.compactMap(\.label),
                       ["conversation", "seq", "kind", "base", "data", "sender"])
        XCTAssertFalse(envelope.sender.contains(marker) || envelope.kind.contains(marker))
    }

    func test03InboundPlaintextOnlyAfterMLSProcessing() throws {
        let relay = Relay()
        let (a, b, _, _) = try pair(relay)
        try a.sendApplicationMessage(marker)
        let envelope = try lastApplication(relay, a)
        let receiver = WatchlinkStore(engine: b)
        XCTAssertTrue(receiver.messages.isEmpty)
        guard case .success = receiver.receive(envelope) else { return XCTFail("receive failed") }
        XCTAssertEqual(receiver.messages.map(\.text), [marker])
        XCTAssertEqual(receiver.messages.first?.isMine, false)
    }

    func test04CorruptInboundRejectedWithoutMutation() throws {
        let relay = Relay()
        let (a, b, _, sb) = try pair(relay)
        try a.sendApplicationMessage(marker)
        let good = try lastApplication(relay, a)
        var bad = good
        bad.data[bad.data.index(before: bad.data.endIndex)] ^= 0x01
        let (anchorBefore, fileBefore) = (try anchor(sb), try Data(contentsOf: stateFile(sb)))
        let store = WatchlinkStore(engine: b)
        if case .success = store.receive(bad) { XCTFail("corrupt input accepted") }
        XCTAssertTrue(store.messages.isEmpty, "no plaintext output")
        XCTAssertEqual(try anchor(sb).committedVersion, anchorBefore.committedVersion)
        XCTAssertNil(try anchor(sb).pendingVersion, "reservation released: read-only rejection")
        XCTAssertEqual(try Data(contentsOf: stateFile(sb)), fileBefore, "no durable mutation")
        XCTAssertEqual(b.securityState, .secure, "rejected input is not a reset")
        XCTAssertEqual(try b.processIncoming(good), marker, "session intact")
    }

    func test05WrongConversationRejected() throws {
        let relay = Relay()
        let (a, b, _, sb) = try pair(relay)
        try a.sendApplicationMessage(marker)
        var foreign = try lastApplication(relay, a)
        foreign.conversation = Data(repeating: 7, count: 16)
        let before = try Data(contentsOf: stateFile(sb))
        XCTAssertThrowsError(try b.processIncoming(foreign))
        XCTAssertEqual(try Data(contentsOf: stateFile(sb)), before)
        XCTAssertEqual(b.securityState, .secure)
    }

    // MARK: B. Persistence

    func test06RecreatedEngineRestoresSameIdentityAndSession() throws {
        let relay = Relay()
        let (a, b, sa, _) = try pair(relay)
        let (pin, conversation) = (a.device!.ownPin, a.device!.document.conversation)
        let restored = engine(sa, relay)
        XCTAssertEqual(restored.device?.ownPin, pin)
        XCTAssertEqual(restored.device?.document.conversation, conversation)
        XCTAssertEqual(restored.securityState, .secure)
        XCTAssertEqual(restored.localIdentity, a.localIdentity)
        try restored.sendApplicationMessage(marker)
        XCTAssertEqual(try b.processIncoming(lastApplication(relay, restored)), marker)
    }

    func test07AnchorVersionMismatchFailsClosed() throws {
        let relay = Relay()
        let (_, _, sa, _) = try pair(relay)
        var tampered = try anchor(sa)
        tampered.committedVersion += 1
        try KeychainStateAnchorStore(service: sa.service, account: "anchor").replace(tampered)
        assertFailClosed(engine(sa, relay))
    }

    func test08ProtectedStateCorruptionFailsClosed() throws {
        let relay = Relay()
        let (_, _, sa, _) = try pair(relay)
        let file = stateFile(sa)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var combined = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["combined"] as? String)))
        combined[combined.index(before: combined.endIndex)] ^= 1
        envelope["combined"] = combined.base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: file, options: [.atomic, .completeFileProtection])
        assertFailClosed(engine(sa, relay))
    }

    func test09IdentitySigningKeyMismatchFailsClosed() throws {
        let relay = Relay()
        let (a, _, sa, _) = try pair(relay)
        let other = try generateSignatureKeypair(cipherSuite: .curve25519Aes128)
        KeychainItem.delete(service: sa.service + ".identity", account: "identity")
        try KeychainItem.add(service: sa.service + ".identity", account: "identity", data: JSONEncoder().encode(
            IdentityItem(credentialId: Data(a.device!.name.utf8), publicKey: other.publicKey.bytes,
                         secretKey: other.secretKey.bytes)))
        assertFailClosed(engine(sa, relay))
        assertFailClosed(engine(sa, relay), "persisted halt survives another restart")
    }

    func testReinstallLeftoverKeychainFailsClosedUntilExplicitReset() throws {
        let relay = Relay()
        let (_, _, sa, _) = try pair(relay)
        try FileManager.default.removeItem(at: stateFile(sa))
        let reinstalled = engine(sa, relay)
        assertFailClosed(reinstalled)
        XCTAssertNoThrow(try KeychainItem.read(service: sa.service, account: "anchor"), "nothing auto-deleted")
        try reinstalled.resetSecurity()
        XCTAssertEqual(reinstalled.securityState, .notPaired)
    }

    private func assertFailClosed(_ engine: MLSCryptoEngine, _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(engine.securityState, .error, message, file: file, line: line)
        XCTAssertFalse(WatchlinkStore(engine: engine).canSend, file: file, line: line)
        XCTAssertThrowsError(try engine.sendApplicationMessage(marker), file: file, line: line)
        let pin = engine.device?.ownPin
        XCTAssertThrowsError(try engine.startPairing(), "no replacement identity", file: file, line: line)
        XCTAssertEqual(engine.device?.ownPin, pin, "no replacement identity", file: file, line: line)
        XCTAssertEqual(engine.securityState, .error, file: file, line: line)
    }

    // MARK: C. Pending commit

    func test10To12PendingCommitBlocksSendsSurvivesRestartAndRetriesByteIdentical() throws {
        let relay = Relay()
        let (a, b, sa, _) = try pair(relay)
        relay.offline = true
        XCTAssertThrowsError(try a.device!.update(), "commit persisted, delivery failed")
        XCTAssertEqual(a.securityState, .sessionUpdatePending)
        let persisted = try XCTUnwrap(a.device!.document.outbound.first { $0.kind == "commit" }?.data)
        relay.offline = false
        let visible = try all(relay, a).count

        let store = WatchlinkStore(engine: a)
        XCTAssertEqual(store.rootState, .chats)
        XCTAssertFalse(store.canSend)
        if case .success = store.send(marker) { XCTFail("sent while a commit is pending") }
        XCTAssertThrowsError(try a.sendApplicationMessage(marker))
        XCTAssertEqual(try all(relay, a).count, visible, "nothing released")

        let restarted = engine(sa, relay)
        XCTAssertEqual(restarted.securityState, .sessionUpdatePending)
        XCTAssertEqual(restarted.device!.document.outbound.first { $0.kind == "commit" }?.data, persisted)

        try restarted.retryPendingCommit()
        let commit = try XCTUnwrap(all(relay, restarted).last { $0.kind == "commit" })
        XCTAssertEqual(commit.data, persisted, "byte-identical retransmission")
        XCTAssertEqual(restarted.securityState, .secure)
        XCTAssertNil(try b.processIncoming(commit))
        try restarted.sendApplicationMessage(marker)
        XCTAssertEqual(try b.processIncoming(lastApplication(relay, restarted)), marker)
    }

    // MARK: D. KeyPackage

    func test13OutstandingKeyPackageSurvivesRecreation() throws {
        let relay = Relay()
        let (sa, sb) = (slot(), slot())
        let a = engine(sa, relay)
        let reply = try XCTUnwrap(engine(sb, relay).acceptPairingCode(a.startPairing().code))
        let b = engine(sb, relay)  // recreated
        XCTAssertEqual(b.securityState, .pairing)
        XCTAssertEqual(b.device?.document.keyPackages.count, 1)
        XCTAssertNil(try a.acceptPairingCode(reply.code))
        try a.establish()
        XCTAssertNil(try b.processIncoming(welcome(relay, for: b)))
        XCTAssertEqual(b.securityState, .secure)
        XCTAssertEqual(b.device?.document.keyPackages.isEmpty, true, "consumed package deleted")
    }

    func test14ConsumedKeyPackageCannotBeReused() throws {
        let relay = Relay()
        let (_, b, _, sb) = try pair(relay)
        XCTAssertEqual(b.device?.document.keyPackages.isEmpty, true)
        let published = try XCTUnwrap(all(relay, b).first { $0.kind == "keypackage" })
        let rogue = try Client(id: Data("rogue".utf8),
                               signatureKeypair: generateSignatureKeypair(cipherSuite: .curve25519Aes128),
                               clientConfig: ClientConfig(groupStateStorage: NullGroupStorage(),
                                                          useRatchetTreeExtension: true))
        let output = try rogue.createGroup(groupId: b.device!.document.conversation!)
            .addMembers(keyPackages: [Message.fromBytes(bytes: published.data)])
        let before = try Data(contentsOf: stateFile(sb))
        XCTAssertThrowsError(try b.processIncoming(Envelope(
            conversation: b.device!.document.conversation!, seq: 99, kind: "welcome", base: nil,
            data: output.welcomeMessage!.toBytes(), sender: "rogue")))
        XCTAssertEqual(try Data(contentsOf: stateFile(sb)), before)
        XCTAssertEqual(b.securityState, .secure)
    }

    func test15WelcomeCannotBeProcessedTwice() throws {
        let relay = Relay()
        let (_, b, _, sb) = try pair(relay)
        let replay = try welcome(relay, for: b)
        XCTAssertThrowsError(try b.processIncoming(replay))
        XCTAssertThrowsError(try engine(sb, relay).processIncoming(replay), "also after restart")
        XCTAssertEqual(b.securityState, .secure)
    }

    func testExpiredKeyPackageRejected() throws {
        let relay = Relay()
        let (sa, sb) = (slot(), slot())
        let a = engine(sa, relay), b = engine(sb, relay)
        XCTAssertNil(try a.acceptPairingCode(XCTUnwrap(b.acceptPairingCode(a.startPairing().code)).code))
        try a.establish()
        clock.now += keyPackageTTL + 1
        XCTAssertThrowsError(try b.processIncoming(welcome(relay, for: b)))
        XCTAssertEqual(b.securityState, .pairing)
    }

    // MARK: E. Identity

    func test16To18PeerPinMismatchHardStopsPersistsAndNeverRepins() throws {
        let relay = Relay()
        let (sa, sb) = (slot(), slot())
        let a = engine(sa, relay), b = engine(sb, relay)
        XCTAssertNil(try a.acceptPairingCode(XCTUnwrap(b.acceptPairingCode(a.startPairing().code)).code))
        let pinned = a.device!.document.peerPin
        let entry = try XCTUnwrap(all(relay, a).first { $0.kind == "keypackage" })
        let impostor = try Client(id: Data(b.device!.name.utf8),  // same BasicCredential, other key
                                  signatureKeypair: generateSignatureKeypair(cipherSuite: .curve25519Aes128),
                                  clientConfig: ClientConfig(groupStateStorage: NullGroupStorage(),
                                                             useRatchetTreeExtension: true))
        try relay.substitute(entry.conversation, seq: entry.seq, data: impostor.generateKeyPackageMessage().toBytes())
        XCTAssertThrowsError(try a.establish())
        XCTAssertEqual(a.securityState, .identityChanged)

        let restarted = engine(sa, relay)
        XCTAssertEqual(restarted.securityState, .identityChanged, "hard stop persists")
        XCTAssertEqual(restarted.device?.document.peerPin, pinned, "no automatic re-pin")
        XCTAssertThrowsError(try restarted.establish())
        XCTAssertThrowsError(try restarted.sendApplicationMessage(marker))
        XCTAssertThrowsError(try restarted.startPairing())
        let store = WatchlinkStore(engine: restarted)
        XCTAssertEqual(store.rootState, .identityReview)
        store.transition(to: .secure)
        XCTAssertFalse(store.canSend)
        XCTAssertEqual(restarted.securityState, .identityChanged)
    }

    // MARK: F. Reset

    func test19To21ResetDestroysStateThenFreshIdentityAndConversation() throws {
        let relay = Relay()
        let (a, b, sa, _) = try pair(relay)
        let (oldPin, oldConversation) = (a.device!.ownPin, try XCTUnwrap(a.device!.document.conversation))
        try b.sendApplicationMessage(marker)
        let oldWire = try lastApplication(relay, b)

        let store = WatchlinkStore(engine: a)
        store.resetSecurity()
        XCTAssertEqual(store.securityState, .notPaired)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(KeychainItem.readStatus(service: sa.service, account: "anchor"), errSecItemNotFound)
        XCTAssertEqual(KeychainItem.readStatus(service: sa.service + ".identity", account: "identity"), errSecItemNotFound)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile(sa).path))
        XCTAssertEqual(engine(sa, relay).securityState, .notPaired)

        let sc = slot()
        let c = engine(sc, relay)
        XCTAssertNil(try a.acceptPairingCode(XCTUnwrap(c.acceptPairingCode(a.startPairing().code)).code))
        try a.establish()
        XCTAssertNil(try c.processIncoming(welcome(relay, for: c)))
        XCTAssertEqual(a.securityState, .secure)
        XCTAssertNotEqual(a.device!.ownPin, oldPin, "fresh local identity")
        XCTAssertNotEqual(a.device!.document.conversation, oldConversation, "fresh conversation id")

        XCTAssertThrowsError(try a.processIncoming(oldWire), "retired conversation rejected by the device")
        try relay.retire(oldConversation)
        XCTAssertEqual(try relay.post(oldConversation, kind: "application", base: 1, data: oldWire.data, sender: "x"),
                       .reject, "and by the relay model")
    }

    // MARK: G. Plaintext guard

    func test23StoreHoldsNoTransport() throws {
        let relay = Relay()
        let (a, _, _, _) = try pair(relay)
        let store = WatchlinkStore(engine: a)
        for child in Mirror(reflecting: store).children {
            XCTAssertFalse(child.value is any RelaySequencer, "UI store must not reach transport: \(child.label ?? "")")
        }
    }

    func test24NoPlaintextMarkerAtRest() throws {
        let relay = Relay()
        let (a, b, sa, sb) = try pair(relay)
        try a.sendApplicationMessage(marker)
        XCTAssertEqual(try b.processIncoming(lastApplication(relay, a)), marker)
        for s in [sa, sb] {
            let files = try FileManager.default.contentsOfDirectory(atPath: s.directory.path)
            XCTAssertEqual(files, ["state.aead"], "no temp or side files")
            let data = try Data(contentsOf: stateFile(s))
            XCTAssertNil(data.range(of: Data(marker.utf8)))
            // NSFileProtectionComplete itself is device-qualified (M1.5 result 3); the simulator does not enforce it.
        }
    }

    // MARK: H. Transaction order

    func test25OutboundReleasedOnlyAfterDurableCommit() throws {
        let relay = Relay()
        let (_, _, sa, _) = try pair(relay)
        let probe = ProbeTransport(relay)
        let a = engine(sa, probe)
        let before = try anchor(sa).committedVersion
        let service = sa.service
        probe.onPost = {
            // At the moment ciphertext becomes transport-visible, its state is already anchored.
            let anchor = try? KeychainStateAnchorStore(service: service, account: "anchor").load()
            XCTAssertNil(anchor?.pendingVersion)
            XCTAssertEqual(anchor?.committedVersion, before + 1)
        }
        var events: [String] = []
        a.device!.store.faults.observer = { events.append($0) }
        try a.sendApplicationMessage(marker)
        XCTAssertEqual(probe.posts, 1)
        let committed = try XCTUnwrap(events.firstIndex(of: "anchored"))
        let released = try XCTUnwrap(events.firstIndex(of: "outbound-released"))
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "sealed")), committed)
        XCTAssertLessThan(committed, released)
    }

    func test26InjectedPersistenceFailurePreventsRelease() throws {
        try assertInjectedFailure(at: "sealed")
    }

    func test27InjectedAnchorWriteFailureFailsClosed() throws {
        // "replaced": the sealed file is written but the Keychain anchor update never happens.
        try assertInjectedFailure(at: "replaced")
    }

    private func assertInjectedFailure(at point: String) throws {
        let relay = Relay()
        let (a, _, sa, _) = try pair(relay)
        let visible = try all(relay, a).count
        a.device!.store.faults.failAt = point
        let store = WatchlinkStore(engine: a)
        if case .success = store.send(marker) { XCTFail("send succeeded despite \(point) failure") }
        XCTAssertEqual(try all(relay, a).count, visible, "nothing released")
        XCTAssertEqual(a.securityState, .error)
        XCTAssertFalse(store.canSend)
        XCTAssertNotNil(try anchor(sa).pendingVersion, "pending marker kept")
        assertFailClosed(engine(sa, relay), "fails closed after restart")
    }
}
