import XCTest

private struct TestEngine: CryptoEngine {
    let isAvailable = true
    let localIdentity: IdentityDescriptor? = IdentityDescriptor(displayName: "Test device")
    func encryptOutgoing(_ text: String) throws -> WireEnvelope {
        WireEnvelope(opaqueBytes: Data([0x01, 0x02])) // Opaque test fixture, never installed by production.
    }
    func decryptIncoming(_ envelope: WireEnvelope) throws -> String { "test" }
}

private final class RecordingEnvelopeTransport: EnvelopeTransport {
    private(set) var envelopes: [WireEnvelope] = []
    func send(_ envelope: WireEnvelope) throws { envelopes.append(envelope) }
}


private struct FailingEnvelopeTransport: EnvelopeTransport {
    func send(_ envelope: WireEnvelope) throws { throw SecurityFailure.transportFailed }
}

@MainActor
final class WatchlinkSecurityTests: XCTestCase {
    func testBlockedStatesCannotSendOrReachTransport() {
        for state in [SecurityState.notPaired, .pairing, .establishingSecureSession, .identityChanged, .unavailable, .error] {
            let transport = RecordingEnvelopeTransport()
            let store = WatchlinkStore(securityState: state, engine: TestEngine(), transport: transport)
            XCTAssertFalse(store.canSend)
            if case .success = store.send("hello") { XCTFail("send passed in \(state)") }
            XCTAssertTrue(store.messages.isEmpty)
            XCTAssertTrue(transport.envelopes.isEmpty)
        }
    }

    func testUnavailableEngineBlocksEvenSecureState() {
        let transport = RecordingEnvelopeTransport()
        let store = WatchlinkStore(securityState: .secure, transport: transport)
        XCTAssertFalse(store.canSend)
        XCTAssertEqual(store.rootState, .unavailable)
        if case .success = store.send("hello") { XCTFail("unavailable engine sent") }
        XCTAssertTrue(transport.envelopes.isEmpty)
    }

    func testSecureStateSendsOnlyOpaqueEnvelopeAndDeliveryTransitions() {
        let transport = RecordingEnvelopeTransport()
        let store = WatchlinkStore(securityState: .secure, engine: TestEngine(), transport: transport)
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
        let store = WatchlinkStore(securityState: .secure, engine: TestEngine(), transport: FailingEnvelopeTransport())
        if case .failure(.transportFailed) = store.send("hello") { } else { XCTFail("expected transport failure") }
        XCTAssertEqual(store.messages.first?.delivery, .failed)
    }

    func testStateTransitionsAndRootMapping() {
        let store = WatchlinkStore(engine: TestEngine())
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
}
