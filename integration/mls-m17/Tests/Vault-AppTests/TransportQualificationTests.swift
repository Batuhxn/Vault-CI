import MLSBridge
import ProtectedStateStore
import Security
@testable import WatchlinkMLS
import XCTest

// M1.7 automated transport qualification: two production installations
// (engine + RelayPort + TransportWorker + store) over an in-memory relay with
// the Worker's semantics, and an adversarial relay that never holds keys.
// Numbers refer to the M1.7 test matrix. Synthetic data only.

@MainActor
final class TransportQualificationTests: XCTestCase {
    private let marker = "M17-PLAINTEXT-MARKER-5d21"
    private let clock = TestClock()
    private var root: URL!
    private var endpoints: [Endpoint] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("m17-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        endpoints.forEach { $0.cleanup() }
        try? FileManager.default.removeItem(at: root)
    }

    private func endpoint(_ api: any RelayAPI) -> Endpoint {
        let e = Endpoint(service: "com.batuhxn.watchlink.m17test.\(UUID().uuidString)",
                         directory: root.appendingPathComponent(UUID().uuidString, isDirectory: true), api: api, clock: clock)
        endpoints.append(e)
        return e
    }

    private func relaunch(_ e: Endpoint, api: (any RelayAPI)? = nil) -> Endpoint {
        let fresh = e.relaunch(api: api)
        endpoints.append(fresh)
        return fresh
    }

    private func settle(_ es: Endpoint..., rounds: Int = 6) async {
        for _ in 0..<rounds {
            for e in es { await e.transport.round() }
            await Task.yield()
        }
    }

    @discardableResult
    private func pair(_ a: Endpoint, _ b: Endpoint) async throws -> (Data, Data) {
        XCTAssertTrue(a.store.createLink())
        guard case .showCode(let codeA, true) = a.store.pairingStep else { throw XCTSkip("no creator code") }
        XCTAssertTrue(b.store.acceptScanned(codeA))
        guard case .showCode(let codeB, false) = b.store.pairingStep else { throw XCTSkip("no reply code") }
        XCTAssertNotEqual(a.store.securityState, .secure, "never secure before verified pairing")
        await settle(a, b)
        XCTAssertNotEqual(b.store.securityState, .secure)
        XCTAssertTrue(a.store.acceptScanned(codeB))
        await settle(a, b)
        XCTAssertEqual(a.store.securityState, .secure)
        XCTAssertEqual(b.store.securityState, .secure)
        return (codeA, codeB)
    }

    private func versions(_ e: Endpoint) throws -> (UInt64, UInt64?) {
        let anchor = try e.anchor()
        return (anchor.committedVersion, anchor.pendingVersion)
    }

    private func assertNoPlaintext(_ relay: FakeRelayAPI, file: StaticString = #filePath, line: UInt = #line) {
        let needle = Data(marker.utf8)
        for data in relay.posted + relay.stored {
            XCTAssertNil(data.range(of: needle), "plaintext marker reached the relay", file: file, line: line)
            XCTAssertNoThrow(try Message.fromBytes(bytes: data), "relay only ever sees MLS messages", file: file, line: line)
        }
    }

    // MARK: A. Pairing

    func testA01to04RealPairingPinsBothIdentitiesAndSharesConversation() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        XCTAssertNotEqual(a.device.ownPin, b.device.ownPin, "distinct identities")
        XCTAssertEqual(a.device.document.peerPin, b.device.ownPin)
        XCTAssertEqual(b.device.document.peerPin, a.device.ownPin)
        let conversation = try XCTUnwrap(a.device.document.conversation)
        XCTAssertEqual(b.device.document.conversation, conversation)
        let box = try XCTUnwrap(relay.mailboxes[conversation])
        XCTAssertNotNil(box.a)
        XCTAssertNotNil(box.b)
        XCTAssertNil(box.claim, "single-use claim capability consumed")
        assertNoPlaintext(relay)
    }

    func testA05ExpiredCodeRejected() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        XCTAssertTrue(a.store.createLink())
        guard case .showCode(let code, _) = a.store.pairingStep else { return XCTFail("no code") }
        clock.now += qrTTL + 1
        XCTAssertEqual(a.store.pairingStep, .expired)
        XCTAssertFalse(b.store.acceptScanned(code))
    }

    func testA06AlteredCodesRejected() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay)
        XCTAssertTrue(a.store.createLink())
        guard case .showCode(let code, _) = a.store.pairingStep else { return XCTFail("no code") }
        var truncated = code
        truncated.removeLast()
        XCTAssertFalse(endpoint(relay).store.acceptScanned(truncated), "malformed")

        // Validly encoded but altered nonce: the relay slot claim is refused.
        var altered = try JSONDecoder().decode(PairingCode.self, from: code)
        altered.nonce = Data(repeating: 9, count: 16)
        let c = endpoint(relay)
        XCTAssertTrue(c.store.acceptScanned(try makeQR(conversation: altered.cid, nonce: altered.nonce,
                                                       pin: altered.pin, expires: altered.exp)))
        await settle(a, c)
        XCTAssertEqual(c.worker.lastError, .http(403))
        XCTAssertNotEqual(c.store.securityState, .secure)

        // Validly encoded but altered pin: the join hard-stops on the roster check.
        let relay2 = FakeRelayAPI(clock: clock)
        let a2 = endpoint(relay2), b2 = endpoint(relay2)
        XCTAssertTrue(a2.store.createLink())
        guard case .showCode(let code2, _) = a2.store.pairingStep else { return XCTFail("no code") }
        var forged = try JSONDecoder().decode(PairingCode.self, from: code2)
        forged.pin = Data(repeating: 7, count: 32)
        XCTAssertTrue(b2.store.acceptScanned(try makeQR(conversation: forged.cid, nonce: forged.nonce,
                                                        pin: forged.pin, expires: forged.exp)))
        await settle(a2, b2)
        guard case .showCode(let reply, false) = b2.store.pairingStep else { return XCTFail("no reply") }
        XCTAssertTrue(a2.store.acceptScanned(reply))
        await settle(a2, b2)
        XCTAssertEqual(b2.engine.securityState, .identityChanged, "altered pin never trusted")
        XCTAssertFalse(b2.store.canSend)
    }

    func testA07CodeReplayAfterPairingRejected() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        let (codeA, _) = try await pair(a, b)
        XCTAssertFalse(b.store.acceptScanned(codeA), "established device refuses")
        let c = endpoint(relay)
        XCTAssertTrue(c.store.acceptScanned(codeA), "parses locally within its lifetime")
        await settle(a, b, c)
        XCTAssertEqual(c.worker.lastError, .http(409), "mailbox slot already claimed")
        XCTAssertNotEqual(c.store.securityState, .secure)
        XCTAssertEqual(a.store.securityState, .secure)
    }

    func testA08WrongConversationCodeRejected() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), other = endpoint(relay), b = endpoint(relay)
        XCTAssertTrue(a.store.createLink())
        XCTAssertTrue(other.store.createLink())
        guard case .showCode(let otherCode, _) = other.store.pairingStep else { return XCTFail("no code") }
        XCTAssertTrue(b.store.acceptScanned(otherCode))
        guard case .showCode(let foreignReply, false) = b.store.pairingStep else { return XCTFail("no reply") }
        XCTAssertFalse(a.store.acceptScanned(foreignReply), "reply for another conversation")
        XCTAssertEqual(a.engine.pairingLifecycle, .offered)
    }

    func testA09WelcomeOutsideJoinStateRejected() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let adversary = AdversarialRelayAPI(relay)
        let a = endpoint(relay), b = endpoint(adversary)
        try await pair(a, b)
        let conversation = try XCTUnwrap(b.device.document.conversation)
        let welcomeBytes = try XCTUnwrap(relay.postedItems.first { $0.kind == "welcome" }?.data)
        let replayed = Envelope(conversation: conversation, seq: 500, kind: "welcome", base: nil, data: welcomeBytes, sender: "peer")
        let before = try versions(b)
        XCTAssertThrowsError(try b.engine.processIncoming(replayed), "Welcome only valid while joining")
        b.port.merge([replayed])
        await settle(a, b)
        XCTAssertTrue(try versions(b) == before, "replayed Welcome ignored")
        XCTAssertEqual(b.store.securityState, .secure)
        _ = adversary
    }

    // MARK: B. Basic E2EE

    func testB10to15BidirectionalMessagesLimitsAndNoRelayPlaintext() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        let unicode = "Merhaba 👋 çğıöşü — 你好 \(marker)"
        let large = String(repeating: "x", count: WatchlinkStore.maxMessageBytes - marker.utf8.count) + marker
        for text in [marker, unicode, large] { _ = a.store.send(text) }
        guard case .success = b.store.send("\(marker) back") else { return XCTFail("reverse send") }
        await settle(a, b)
        XCTAssertEqual(b.received, [marker, unicode, large])
        XCTAssertEqual(a.received, ["\(marker) back"])
        XCTAssertTrue(a.store.messages.filter(\.isMine).allSatisfy { $0.delivery == .sent }, "relay accepted")
        XCTAssertEqual(a.store.send("   "), .failure(.emptyMessage))
        XCTAssertEqual(a.store.send(large + "!"), .failure(.messageTooLarge))
        XCTAssertEqual(a.engine.wireChecks.failed + b.engine.wireChecks.failed, 0)
        XCTAssertGreaterThan(b.engine.wireChecks.passed, 0)
        assertNoPlaintext(relay)
    }

    /// Regression: a network failure later in the same round must not swallow
    /// plaintext the engine already produced (its MLS state has advanced).
    func testPlaintextSurvivesLaterNetworkFailureInSameRound() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let adversary = AdversarialRelayAPI(relay)
        let a = endpoint(relay), b = endpoint(adversary)
        try await pair(a, b)
        adversary.modes = [.ackFails]
        _ = a.store.send("kept")
        await settle(a, b)
        XCTAssertEqual(b.received, ["kept"], "shown exactly once despite ack failures")
        XCTAssertEqual(b.worker.lastError, .http(0))
    }

    // MARK: C. Replay / duplicate

    func testC16to18DuplicateAndReplayedDeliveryYieldsOnePlaintextAndNoMutation() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let adversary = AdversarialRelayAPI(relay)
        let a = endpoint(relay), b = endpoint(adversary)
        try await pair(a, b)
        adversary.modes = [.duplicate]
        _ = a.store.send(marker)
        await settle(a, b)
        XCTAssertEqual(b.received, [marker])
        let settled = try versions(b)
        adversary.modes = [.duplicate, .replayPrior]
        await settle(a, b)
        XCTAssertEqual(b.received, [marker], "exactly one visible plaintext")
        XCTAssertTrue(try versions(b) == settled, "duplicates/replays never mutate MLS state twice")
        XCTAssertEqual(b.store.securityState, .secure)
    }

    /// A relay replaying an already-applied commit under a new sequence contradicts
    /// local MLS state: qualified rule, hard fail closed (a relay can always deny service).
    func testC17ReplayedCommitFailsClosed() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let adversary = AdversarialRelayAPI(relay)
        let a = endpoint(relay), b = endpoint(adversary)
        try await pair(a, b)
        _ = try? a.device.update()
        await settle(a, b)
        XCTAssertEqual(a.device.group?.currentEpoch(), b.device.group?.currentEpoch())
        adversary.modes = [.replayCommit]
        await settle(a, b)
        XCTAssertEqual(b.engine.securityState, .error)
        XCTAssertTrue(b.received.isEmpty)
    }

    // MARK: D. Ordering

    func testD19to20ReorderedDeliveryIsAppliedInRelayOrder() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let adversary = AdversarialRelayAPI(relay)
        let a = endpoint(relay), b = endpoint(adversary)
        try await pair(a, b)
        adversary.modes = [.delay]
        for n in 1...3 { _ = a.store.send("m\(n)") }
        await settle(a, b)
        XCTAssertTrue(b.received.isEmpty)
        adversary.modes = [.reorder]
        await settle(a, b)
        XCTAssertEqual(b.received, ["m1", "m2", "m3"])
    }

    func testD21StaleEpochMessageBeforeCommitStillDecrypts() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let adversary = AdversarialRelayAPI(relay)
        let a = endpoint(relay), b = endpoint(adversary)
        try await pair(a, b)
        adversary.modes = [.delay]
        _ = a.store.send("old epoch")
        await settle(a, b)
        _ = try? a.device.update()  // a's commit is sequenced after its epoch-N message
        await settle(a, b)
        adversary.modes = []
        await settle(a, b)
        XCTAssertEqual(b.received, ["old epoch"])
        XCTAssertEqual(a.device.group?.currentEpoch(), b.device.group?.currentEpoch())
        _ = a.store.send("new epoch")
        await settle(a, b)
        XCTAssertEqual(b.received, ["old epoch", "new epoch"])
    }

    func testD22FutureEpochMessageWithoutItsCommitRejectedWithoutMutation() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        _ = try? a.device.update()
        await settle(a)  // a moves to N+1; b has not fetched
        _ = a.store.send("future")
        await settle(a)
        let conversation = a.device.document.conversation!
        let future = try XCTUnwrap(relay.mailboxes[conversation]?.rows.last { $0.kind == "application" })
        let before = try versions(b)
        XCTAssertThrowsError(try b.engine.processIncoming(Envelope(conversation: conversation, seq: future.seq,
            kind: "application", base: future.base, data: future.data!, sender: "peer")))
        XCTAssertTrue(try versions(b) == before)
        XCTAssertTrue(b.received.isEmpty)
    }

    func testD23RelayLyingAboutBaseEpochHardFailsWithoutPartialMutation() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let adversary = AdversarialRelayAPI(relay)
        let a = endpoint(relay), b = endpoint(adversary)
        try await pair(a, b)
        let epoch = b.device.group?.currentEpoch()
        adversary.modes = [.wrongBase]
        _ = try? a.device.update()
        await settle(a, b)
        XCTAssertEqual(b.engine.securityState, .error, "halted, fail closed")
        XCTAssertEqual(b.relaunch().engine.securityState, .error, "persisted")
        XCTAssertEqual(b.device.group?.currentEpoch() ?? epoch, epoch, "epoch not advanced by the lie")
        XCTAssertFalse(b.store.canSend)
    }

    // MARK: E. Corruption

    func testE24to27CorruptTruncatedRandomAndForeignCiphertextRejected() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let adversary = AdversarialRelayAPI(relay)
        let a = endpoint(relay), b = endpoint(adversary)
        try await pair(a, b)
        for mode in [AdversarialRelayAPI.Mode.corrupt, .truncate, .randomBytes] {
            let before = try versions(b), file = try b.stateFile()
            adversary.modes = [mode]
            _ = a.store.send("\(marker) \(mode)")
            await settle(a, b)
            XCTAssertTrue(b.received.isEmpty, "no plaintext for \(mode)")
            XCTAssertTrue(try versions(b) == before, "no durable mutation for \(mode)")
            XCTAssertEqual(try b.stateFile(), file)
            XCTAssertEqual(b.store.securityState, .secure, "rejection is not a reset")
        }
        let wire = try XCTUnwrap(relay.posted.last)
        XCTAssertThrowsError(try b.engine.processIncoming(Envelope(conversation: Data(repeating: 1, count: 16),
            seq: 10_000, kind: "application", base: nil, data: wire, sender: "peer")), "wrong conversation")
        adversary.modes = []
        _ = a.store.send("clean")
        await settle(a, b)
        XCTAssertEqual(b.received, ["clean"], "session intact afterwards")
    }

    // MARK: F. Network failure

    func testF28to32TimeoutsAndOfflineRetryReuseExactCommittedBytes() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        let identity = a.device.ownPin
        relay.offline = true
        guard case .success = a.store.send(marker) else { return XCTFail("queued send") }
        XCTAssertEqual(a.store.messages.last?.delivery, .pending)
        let queued = try XCTUnwrap(a.device.store.committed.outbound.first { $0.kind == "application" }?.data)
        await settle(a, b, rounds: 5)
        XCTAssertEqual(a.device.store.committed.outbound.map(\.data), [queued], "no replacement ciphertext")
        XCTAssertEqual(a.worker.lastError, .http(0))
        XCTAssertFalse(a.store.connectionAvailable)
        XCTAssertEqual(a.store.securityState, .secure, "transport failure never resets")

        let restarted = relaunch(a)
        XCTAssertEqual(restarted.device.store.committed.outbound.map(\.data), [queued], "survives restart")
        XCTAssertEqual(restarted.device.ownPin, identity)
        relay.offline = false
        await settle(restarted, b)
        XCTAssertEqual(relay.posted.filter { $0 == queued }.count, 1, "exact bytes, sent once")
        XCTAssertEqual(b.received, [marker])
        XCTAssertTrue(restarted.engine.pendingOutboundIDs.isEmpty)
        XCTAssertTrue(restarted.store.connectionAvailable)
    }

    // MARK: G. Crash / restart

    func testG33KillAfterCommitBeforeAckRetriesSameItem() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let lossy = AdversarialRelayAPI(relay)
        let a = endpoint(lossy), b = endpoint(relay)
        try await pair(a, b)
        lossy.modes = [.dropAck]
        _ = a.store.send(marker)
        await settle(a, rounds: 2)
        let queued = try XCTUnwrap(a.device.store.committed.outbound.first?.data)
        let restarted = relaunch(a, api: relay)  // killed before any ACK arrived
        XCTAssertEqual(restarted.device.store.committed.outbound.map(\.data), [queued])
        await settle(restarted, b)
        XCTAssertEqual(relay.mailboxes.values.flatMap(\.rows).filter { $0.id == RelayPort.digest(queued) }.count, 1,
                       "one relay item for the retried bytes")
        XCTAssertEqual(b.received, [marker], "delivered exactly once")
        XCTAssertTrue(restarted.device.store.committed.outbound.isEmpty)
    }

    func testG34ReceiverKillAroundInboundIsCompleteOrFailClosed() async throws {
        for point in ["reserved", "group-written", "sealed", "replaced", "anchored"] {
            let relay = FakeRelayAPI(clock: clock)
            let a = endpoint(relay), b = endpoint(relay)
            try await pair(a, b)
            let committed = try versions(b).0
            _ = a.store.send("kill \(point)")
            await settle(a)
            b.device.store.faults.crashAt = point
            await b.transport.round()
            let relaunched = relaunch(b)
            if point == "anchored" {
                XCTAssertEqual(relaunched.engine.securityState, .secure, point)
                XCTAssertEqual(try versions(relaunched).0, committed + 1, "completed consistently at \(point)")
            } else {
                XCTAssertEqual(relaunched.engine.securityState, .error, "fail closed at \(point)")
                XCTAssertEqual(try versions(relaunched).0, committed, "no partial state at \(point)")
            }
        }
    }

    func testG35RestartBothKeepsIdentitiesAndConversation() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        let pins = (a.device.ownPin, b.device.ownPin), conversation = a.device.document.conversation
        let a2 = relaunch(a), b2 = relaunch(b)
        XCTAssertEqual(a2.device.ownPin, pins.0)
        XCTAssertEqual(b2.device.ownPin, pins.1)
        XCTAssertEqual(b2.device.document.conversation, conversation)
        _ = a2.store.send("after restart")
        await settle(a2, b2)
        XCTAssertEqual(b2.received, ["after restart"])
    }

    // MARK: H. Pending commit

    func testH36to39PendingCommitBlocksSurvivesRestartRetriesExactlyAndPeerFollows() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        relay.offline = true
        XCTAssertThrowsError(try a.device.update())
        a.store.refresh()
        XCTAssertEqual(a.store.securityState, .sessionUpdatePending)
        XCTAssertEqual(a.store.send("blocked"), .failure(.sessionNotSecure))
        let commit = try XCTUnwrap(a.device.store.committed.outbound.first { $0.kind == "commit" }?.data)
        await settle(a, rounds: 3)
        let restarted = relaunch(a)
        XCTAssertEqual(restarted.device.store.committed.outbound.first { $0.kind == "commit" }?.data, commit)
        relay.offline = false
        await settle(restarted, b)
        XCTAssertEqual(relay.posted.filter { $0 == commit }.count, 1, "byte-identical, not rebuilt")
        XCTAssertEqual(restarted.store.securityState, .secure)
        XCTAssertEqual(b.device.group?.currentEpoch(), restarted.device.group?.currentEpoch(), "peer followed")
        _ = restarted.store.send("after commit")
        await settle(restarted, b)
        XCTAssertEqual(b.received, ["after commit"])
    }

    // MARK: I. Concurrent commit

    func testI40ConcurrentCommitsConvergeWithoutSplitBrain() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        relay.offline = true
        XCTAssertThrowsError(try a.device.update())
        XCTAssertThrowsError(try b.device.update())
        relay.offline = false
        await settle(a, b)
        XCTAssertEqual(a.store.securityState, .secure)
        XCTAssertEqual(b.store.securityState, .secure)
        XCTAssertEqual(a.device.group?.currentEpoch(), b.device.group?.currentEpoch(), "one winner, both converge")
        _ = a.store.send("from a")
        _ = b.store.send("from b")
        await settle(a, b)
        XCTAssertEqual(b.received, ["from a"])
        XCTAssertEqual(a.received, ["from b"])
    }

    // MARK: J. Identity change

    func testJ41to43PeerIdentityChangeHardStopsPersistsAndOnlyResetRecovers() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        let pinned = a.device.document.peerPin
        // b's installation commits a validly signed roster change with an unknown identity.
        let group = try XCTUnwrap(b.device.group)
        let stranger = Client(id: Data("stranger".utf8),
                              signatureKeypair: try generateSignatureKeypair(cipherSuite: .curve25519Aes128),
                              clientConfig: ClientConfig(groupStateStorage: NullStorage(), useRatchetTreeExtension: true))
        let base = group.currentEpoch()
        let commit = try group.addMembers(keyPackages: [stranger.generateKeyPackageMessage()]).commitMessage.toBytes()
        b.engine.reload()
        let conversation = try XCTUnwrap(b.device.document.conversation)
        let credential = try XCTUnwrap(b.worker.memberships.load().first?.credential)
        _ = try await relay.post(conversation, credential: credential, kind: "commit", base: base, data: commit)
        await settle(a)
        XCTAssertEqual(a.store.securityState, .identityChanged)
        XCTAssertFalse(a.store.canSend)
        XCTAssertEqual(a.store.send("x"), .failure(.sessionNotSecure))

        let restarted = relaunch(a)
        XCTAssertEqual(restarted.store.securityState, .identityChanged, "persists")
        XCTAssertEqual(restarted.device.document.peerPin, pinned, "no automatic re-pin")
        restarted.store.transition(to: .secure)
        XCTAssertFalse(restarted.store.canSend)
        restarted.store.resetSecurity()
        XCTAssertEqual(restarted.store.securityState, .notPaired, "explicit reset is the only way out")
        try await pair(restarted, endpoint(relay))
    }

    // MARK: K. Reset / retired conversation

    func testK44to49ResetRetiresConversationAndOldMaterialStaysDead() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        let (oldCode, _) = try await pair(a, b)
        let oldConversation = try XCTUnwrap(a.device.document.conversation)
        let oldPins = (a.device.ownPin, b.device.ownPin)
        _ = b.store.send("old")
        await settle(a, b)
        let oldWire = try XCTUnwrap(relay.posted.last)

        a.store.resetSecurity()
        b.store.resetSecurity()
        await settle(a, b)
        XCTAssertEqual(relay.mailboxes[oldConversation]?.retired, true, "relay retired the conversation")
        XCTAssertEqual(KeychainItem.readStatus(service: a.service, account: "anchor"), errSecItemNotFound)

        try await pair(a, b)
        XCTAssertNotEqual(a.device.document.conversation, oldConversation, "fresh conversation")
        XCTAssertNotEqual(a.device.ownPin, oldPins.0, "fresh identity")
        XCTAssertNotEqual(b.device.ownPin, oldPins.1)
        XCTAssertThrowsError(try a.engine.processIncoming(Envelope(conversation: oldConversation, seq: 99,
            kind: "application", base: nil, data: oldWire, sender: "peer")), "old ciphertext rejected")

        let late = endpoint(relay)
        XCTAssertTrue(late.store.acceptScanned(oldCode), "still inside its 5-minute lifetime")
        await settle(late)
        XCTAssertEqual(late.worker.lastError, .http(410), "relay refuses the retired conversation")
        XCTAssertNotEqual(late.store.securityState, .secure)
        clock.now += qrTTL + 1
        XCTAssertFalse(endpoint(relay).store.acceptScanned(oldCode), "expired old code rejected locally")
        do {
            try await relay.open(oldConversation, credential: Data(repeating: 3, count: 32),
                                 claimVerifier: Data(repeating: 4, count: 32), claimExpires: clock.now + 60)
            XCTFail("retired conversation revived")
        } catch {
            XCTAssertEqual(error as? RelayError, .http(410))
        }
        let revived = try? await relay.post(oldConversation, credential: Data(repeating: 3, count: 32),
                                            kind: "application", base: 1, data: oldWire)
        XCTAssertNil(revived, "unknown credential for a retired conversation")
    }

    // MARK: Bounded dedup state

    func testDeduplicationStateStaysBounded() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        for n in 0..<30 { _ = a.store.send("n\(n)") }
        await settle(a, b)
        XCTAssertEqual(b.received.count, 30)
        let conversation = b.device.document.conversation!
        XCTAssertTrue(b.port.fetch(conversation, recipient: "", after: 0).isEmpty, "inbox trimmed after ack")
        XCTAssertTrue(b.port.rejected.isEmpty)
        XCTAssertTrue(relay.stored.isEmpty, "relay dropped acknowledged ciphertext")
    }
}

/// Stranger client storage (identity-change reproduction only).
private final class NullStorage: GroupStateStorage, @unchecked Sendable {
    func state(groupId: Data) throws -> Data? { nil }
    func epoch(groupId: Data, epochId: UInt64) throws -> Data? { nil }
    func write(groupId: Data, groupState: Data, epochInserts: [EpochRecord], epochUpdates: [EpochRecord]) throws {}
    func maxEpochId(groupId: Data) throws -> UInt64? { nil }
}
