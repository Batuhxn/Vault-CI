#if WATCHLINK_QUALIFICATION
import ProtectedStateStore
import XCTest

@MainActor
final class SecurityAdversaryTests: XCTestCase {
    private let clock = TestClock()
    private var root: URL!
    private var endpoints: [Endpoint] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("m17-adversary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        endpoints.forEach { $0.cleanup() }
        try? FileManager.default.removeItem(at: root)
    }

    private func endpoint(_ relay: FakeRelayAPI) -> Endpoint {
        let result = Endpoint(service: "com.batuhxn.watchlink.adversary.\(UUID().uuidString)",
                              directory: root.appendingPathComponent(UUID().uuidString, isDirectory: true),
                              api: relay, clock: clock)
        endpoints.append(result)
        return result
    }

    private func settle(_ endpoints: Endpoint...) async {
        for _ in 0..<7 { for endpoint in endpoints { await endpoint.transport.round() } }
    }

    private func pair(_ a: Endpoint, _ b: Endpoint) async throws {
        XCTAssertTrue(a.store.createLink())
        guard case .showCode(let codeA, true) = a.store.pairingStep else { return XCTFail("creator code") }
        XCTAssertTrue(b.store.acceptScanned(codeA))
        guard case .showCode(let codeB, false) = b.store.pairingStep else { return XCTFail("reply code") }
        await settle(a, b)
        XCTAssertTrue(a.store.acceptScanned(codeB))
        await settle(a, b)
        XCTAssertEqual(a.store.securityState, .secure)
        XCTAssertEqual(b.store.securityState, .secure)
    }

    private func assertFreshTraffic(_ a: Endpoint, _ b: Endpoint, expectedPrior: Int) async {
        XCTAssertEqual(a.store.securityState, .secure)
        XCTAssertEqual(b.store.securityState, .secure)
        XCTAssertTrue(b.device.document.pendingCommit == nil)
        XCTAssertTrue(b.device.document.outbound.isEmpty)
        XCTAssertTrue(b.store.canSend)
        guard case .success = a.store.send("fresh after attack") else { return XCTFail("fresh send") }
        await settle(a, b)
        XCTAssertEqual(b.received.count, expectedPrior + 1)
        XCTAssertTrue(b.received.last == "fresh after attack")
        guard case .success = b.store.send("fresh reply") else { return XCTFail("fresh reply send") }
        await settle(b, a)
        XCTAssertTrue(a.received.last == "fresh reply")
    }

    func testExactTransportCiphertextReplayIsIgnoredWithoutDuplicateDelivery() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        _ = a.store.send("first")
        await settle(a, b)
        XCTAssertTrue(b.received == ["first"])
        let epoch = b.device.group?.currentEpoch()
        let version = try b.anchor().committedVersion
        let accepted = try XCTUnwrap(b.engine.adversary.retained(.exactApplication))
        XCTAssertEqual(b.engine.adversary.run(.exactApplication, engine: b.engine, store: b.store), .ignored)
        let injected = try XCTUnwrap(b.engine.adversary.lastInjection)
        XCTAssertEqual(injected.seq, accepted.seq)
        XCTAssertTrue(injected.data == accepted.data, "exact MLS bytes")
        XCTAssertTrue(b.received == ["first"])
        XCTAssertEqual(b.device.group?.currentEpoch(), epoch)
        XCTAssertEqual(try b.anchor().committedVersion, version)
        XCTAssertEqual(b.engine.adversary.invariantViolations, 0)
        XCTAssertTrue(b.engine.adversary.summary().contains { $0.contains("exact application replay: accepted 0 rejected 0 ignored 1") })
        await assertFreshTraffic(a, b, expectedPrior: 1)
    }

    func testFreshSequenceOldApplicationReachesMLSAndIsRejected() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        _ = a.store.send("first")
        await settle(a, b)
        let document = b.device.store.committed
        let epoch = b.device.group?.currentEpoch()
        let version = try b.anchor().committedVersion
        let file = try b.stateFile()
        let accepted = try XCTUnwrap(b.engine.adversary.retained(.staleApplication))
        let lastSeq = document.lastSeq
        XCTAssertEqual(b.engine.adversary.run(.staleApplication, engine: b.engine, store: b.store), .rejected)
        let injected = try XCTUnwrap(b.engine.adversary.lastInjection)
        XCTAssertEqual(injected.seq, lastSeq + 1, "passed transport sequence deduplication")
        XCTAssertTrue(injected.data == accepted.data, "unchanged MLS bytes reach Device.receive")
        XCTAssertTrue(b.received == ["first"])
        XCTAssertTrue(b.device.store.committed == document)
        XCTAssertEqual(b.device.group?.currentEpoch(), epoch)
        XCTAssertEqual(try b.anchor().committedVersion, version)
        XCTAssertTrue(try b.stateFile() == file)
        XCTAssertEqual(b.engine.adversary.invariantViolations, 0)
        await assertFreshTraffic(a, b, expectedPrior: 1)
    }

    func testTamperLastCiphertextRejectsWithoutPlaintextOrStateMutation() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        _ = a.store.send("first")
        await settle(a, b)
        let document = b.device.store.committed
        let epoch = b.device.group?.currentEpoch()
        let version = try b.anchor().committedVersion
        let file = try b.stateFile()
        XCTAssertEqual(b.engine.adversary.run(.tamperApplication, engine: b.engine, store: b.store), .rejected)
        XCTAssertTrue(b.received == ["first"], "no plaintext after failed authentication")
        XCTAssertTrue(b.device.store.committed == document)
        XCTAssertEqual(b.device.group?.currentEpoch(), epoch)
        XCTAssertEqual(try b.anchor().committedVersion, version)
        XCTAssertNil(try b.anchor().pendingVersion)
        XCTAssertTrue(try b.stateFile() == file)
        XCTAssertEqual(b.engine.adversary.invariantViolations, 0)
        await assertFreshTraffic(a, b, expectedPrior: 1)
    }

    func testExactTransportCommitReplayLeavesEpochPendingAndOutboundCoherent() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        _ = try? a.device.update()  // committed even if the relay decision is deferred
        await settle(a, b)
        XCTAssertEqual(a.device.group?.currentEpoch(), b.device.group?.currentEpoch())
        let document = b.device.store.committed
        let epoch = b.device.group?.currentEpoch()
        let version = try b.anchor().committedVersion
        let accepted = try XCTUnwrap(b.engine.adversary.retained(.exactCommit))
        XCTAssertEqual(b.engine.adversary.run(.exactCommit, engine: b.engine, store: b.store), .ignored)
        let injected = try XCTUnwrap(b.engine.adversary.lastInjection)
        XCTAssertEqual(injected.seq, accepted.seq)
        XCTAssertTrue(injected.data == accepted.data, "exact MLS bytes")
        XCTAssertTrue(b.device.store.committed == document)
        XCTAssertEqual(b.device.group?.currentEpoch(), epoch)
        XCTAssertEqual(try b.anchor().committedVersion, version)
        XCTAssertTrue(b.device.document.pendingCommit == nil)
        XCTAssertEqual(b.engine.adversary.invariantViolations, 0)
        await assertFreshTraffic(a, b, expectedPrior: 0)
    }

    func testFreshSequenceOldCommitHardStopsWithoutApplyingItAgain() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        _ = try? a.device.update()
        await settle(a, b)
        let acceptedEpoch = try XCTUnwrap(b.device.group?.currentEpoch())
        XCTAssertEqual(a.device.group?.currentEpoch(), acceptedEpoch)
        let before = b.device.store.committed
        let version = try b.anchor().committedVersion
        let received = b.received
        let accepted = try XCTUnwrap(b.engine.adversary.retained(.staleCommit))
        XCTAssertLessThanOrEqual(accepted.seq, before.lastSeq)

        XCTAssertEqual(b.engine.adversary.run(.staleCommit, engine: b.engine, store: b.store), .rejected)
        var expected = before
        expected.security = .halted
        XCTAssertTrue(b.device.store.committed == expected, "only the fail-closed marker may change")
        XCTAssertTrue(b.device.group == nil, "hard stop removes the live group; no new epoch was accepted")
        XCTAssertTrue(b.device.document.groups == before.groups, "accepted epoch storage is unchanged")
        XCTAssertTrue(b.device.document.pendingCommit == nil)
        XCTAssertTrue(b.device.document.outbound == before.outbound, "no outbound commit synthesized")
        XCTAssertTrue(b.received == received, "no plaintext/UI delivery")
        XCTAssertEqual(b.engine.securityState, .error)
        XCTAssertFalse(b.store.canSend)
        XCTAssertEqual(try b.anchor().committedVersion, version + 1)
        XCTAssertNil(try b.anchor().pendingVersion)
        XCTAssertEqual(b.engine.adversary.invariantViolations, 0)

        // Qualified recovery model: a hard-stopped identity cannot receive
        // more traffic. Only an explicit reset and new pairing restores it.
        _ = a.store.send("valid while blocked")
        await settle(a, b)
        XCTAssertTrue(b.received == received)
        XCTAssertEqual(b.store.send("blocked"), .failure(.sessionNotSecure))
        a.store.resetSecurity()
        b.store.resetSecurity()
        XCTAssertNil(b.engine.adversary.run(.exactCommit, engine: b.engine, store: b.store))
        try await pair(a, b)
        await assertFreshTraffic(a, b, expectedPrior: 0)
    }

    func testRetainedEnvelopesDoNotSurviveResetIdentityOrNewConversation() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        try await pair(a, b)
        let oldConversation = b.device.document.conversation
        let oldIdentity = b.device.ownPin
        _ = a.store.send("old link")
        await settle(a, b)
        a.store.resetSecurity()
        b.store.resetSecurity()
        XCTAssertNil(b.engine.adversary.run(.exactApplication, engine: b.engine, store: b.store))
        try await pair(a, b)
        XCTAssertTrue(b.device.document.conversation != oldConversation)
        XCTAssertTrue(b.device.ownPin != oldIdentity)
        XCTAssertNil(b.engine.adversary.run(.staleApplication, engine: b.engine, store: b.store))
        await assertFreshTraffic(a, b, expectedPrior: 0)
    }
}
#endif
