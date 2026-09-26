import WatchlinkMLS
import XCTest

private final class RecordingEnvelopeTransport: EnvelopeTransport {
    private(set) var envelopes: [WireEnvelope] = []
    func post(_ conversation: Data, kind: String, base: UInt64?, data: Data, sender: String) throws -> RelayStatus {
        envelopes.append(Envelope(conversation: conversation, seq: UInt64(envelopes.count + 1), kind: kind,
                                  base: base, data: data, sender: sender))
        return .ok(UInt64(envelopes.count))
    }
    func entry(_ conversation: Data, seq: UInt64) throws -> Envelope { envelopes[Int(seq) - 1] }
    func fetch(_ conversation: Data, recipient: String, after: UInt64) -> [Envelope] { envelopes }
}

private final class FailingEnvelopeTransport: EnvelopeTransport {
    func post(_ conversation: Data, kind: String, base: UInt64?, data: Data, sender: String) throws -> RelayStatus {
        throw RelayUnavailable()
    }
    func entry(_ conversation: Data, seq: UInt64) throws -> Envelope { throw RelayUnavailable() }
    func fetch(_ conversation: Data, recipient: String, after: UInt64) -> [Envelope] { [] }
}

/// Opaque test fixture, never installed by production.
private final class TestEngine: CryptoEngine {
    var securityState = SecurityState.secure
    let localIdentity: IdentityDescriptor? = IdentityDescriptor(displayName: "Test device")
    let transport: any EnvelopeTransport
    init(transport: any EnvelopeTransport = RecordingEnvelopeTransport()) { self.transport = transport }
    func sendApplicationMessage(_ text: String) throws {
        do { _ = try transport.post(Data(), kind: "application", base: nil, data: Data([0x01, 0x02]), sender: "t") }
        catch { throw SecurityFailure.transportFailed }
    }
    func processIncoming(_ envelope: WireEnvelope) throws -> String? { "test" }
    func startPairing() throws -> PairingPayload { throw SecurityFailure.unavailable }
    func acceptPairingCode(_ code: Data) throws -> PairingPayload? { throw SecurityFailure.unavailable }
    func establish() throws {}
    func retryPendingCommit() throws {}
    func resetSecurity() throws {}
    func reopenIfUnavailable() {}
}

@MainActor
final class WatchlinkSecurityTests: XCTestCase {
    func testBlockedStatesCannotSendOrReachTransport() {
        for state in [SecurityState.notPaired, .pairing, .establishingSecureSession, .sessionUpdatePending,
                      .identityChanged, .unavailable, .error] {
            let transport = RecordingEnvelopeTransport()
            let store = WatchlinkStore(securityState: state, engine: TestEngine(transport: transport))
            XCTAssertFalse(store.canSend)
            if case .success = store.send("hello") { XCTFail("send passed in \(state)") }
            XCTAssertTrue(store.messages.isEmpty)
            XCTAssertTrue(transport.envelopes.isEmpty)
        }
    }

    func testUnavailableEngineBlocksEvenSecureState() {
        let store = WatchlinkStore(securityState: .secure)
        XCTAssertFalse(store.canSend)
        XCTAssertEqual(store.rootState, .unavailable)
        if case .success = store.send("hello") { XCTFail("unavailable engine sent") }
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testSecureStateSendsOnlyOpaqueEnvelopeAndDeliveryTransitions() {
        let transport = RecordingEnvelopeTransport()
        let store = WatchlinkStore(securityState: .secure, engine: TestEngine(transport: transport))
        guard case .success(let id) = store.send("  hello  ") else { return XCTFail("secure send failed") }
        XCTAssertEqual(transport.envelopes.count, 1)
        XCTAssertEqual(store.messages.first?.text, "hello")
        XCTAssertEqual(store.messages.first?.delivery, .sent)
        store.markDelivered(id)
        XCTAssertEqual(store.messages.first?.delivery, .delivered)
        store.markDelivered(id)
        XCTAssertEqual(store.messages.count, 1)
    }

    func testTransportFailureIsVisibleAndNeverFallsBack() {
        let store = WatchlinkStore(securityState: .secure, engine: TestEngine(transport: FailingEnvelopeTransport()))
        if case .failure(.transportFailed) = store.send("hello") { } else { XCTFail("expected transport failure") }
        XCTAssertEqual(store.messages.first?.delivery, .failed)
    }

    func testStateTransitionsAndRootMapping() {
        let store = WatchlinkStore(securityState: .notPaired, engine: TestEngine())
        XCTAssertEqual(store.rootState, .welcome)
        XCTAssertTrue(store.messages.isEmpty)
        store.beginPairing()
        XCTAssertEqual(store.rootState, .pairing)
        store.cancelPairing()
        XCTAssertEqual(store.rootState, .welcome)
        store.transition(to: .establishingSecureSession)
        XCTAssertEqual(store.rootState, .establishing)
        store.transition(to: .secure)
        XCTAssertEqual(store.rootState, .chats)
        store.transition(to: .identityChanged)
        XCTAssertEqual(store.rootState, .identityReview)
        XCTAssertFalse(store.canSend)
        store.transition(to: .secure)
        XCTAssertEqual(store.rootState, .identityReview)
        XCTAssertFalse(store.canSend)
        store.showUnavailable()
        XCTAssertEqual(store.rootState, .unavailable)
    }

    func testLocalMessageHasNoRelayDependency() {
        let message = LocalMessage(text: "in memory", isMine: false)
        XCTAssertEqual(message.delivery, .pending)
        XCTAssertFalse(message.isMine)
    }

    func testEngineFailClosedStatesOverridePresentation() {
        let engine = TestEngine()
        let store = WatchlinkStore(securityState: .notPaired, engine: engine)
        for failed in [SecurityState.identityChanged, .unavailable, .error, .sessionUpdatePending] {
            engine.securityState = failed
            store.transition(to: .notPaired)
            XCTAssertEqual(store.securityState, failed)
            store.transition(to: .secure)
            XCTAssertEqual(store.securityState, failed)
            XCTAssertFalse(store.canSend)
        }
    }
}
