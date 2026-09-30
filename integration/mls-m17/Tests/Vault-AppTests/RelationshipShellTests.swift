import WatchlinkMLS
import XCTest

/// Reports a fixed security state; never produced by production code.
private final class StateEngine: CryptoEngine {
    var securityState: SecurityState
    init(_ state: SecurityState) { securityState = state }
    let localIdentity: IdentityDescriptor? = nil
    func sendApplicationMessage(_ text: String) throws -> Data { Data([0x01]) }
    let pendingOutboundIDs: Set<Data> = []
    func currentPairingCode() -> PairingPayload? { nil }
    let pairingLifecycle: Lifecycle? = nil
    func cancelPairing() throws {}
    func processIncoming(_ envelope: WireEnvelope) throws -> String? { nil }
    func startPairing() throws -> PairingPayload { throw SecurityFailure.unavailable }
    func acceptPairingCode(_ code: Data) throws -> PairingPayload? { nil }
    func establish() throws {}
    func retryPendingCommit() throws {}
    func resetSecurity() throws {}
    func reopenIfUnavailable() {}
}

private final class MemoryPersistence: RelationshipPersistence {
    var saved: RelationshipSnapshot?
    func load() throws -> RelationshipSnapshot? { saved }
    func save(_ snapshot: RelationshipSnapshot) throws { saved = snapshot }
}

@MainActor
final class RelationshipShellTests: XCTestCase {
    private let allStates: [SecurityState] = [.notPaired, .pairing, .establishingSecureSession, .secure,
                                              .sessionUpdatePending, .identityChanged, .unavailable, .error]

    func testNavigationIsExactlyHomeChatUs() {
        XCTAssertEqual(RelationshipShell.Destination.allCases.map(\.title), ["Home", "Chat", "Us"])
    }

    func testOnlyEstablishedStatesReachTheShell() {
        for state in allStates {
            let store = WatchlinkStore(engine: StateEngine(state))
            XCTAssertEqual(store.rootState == .chats, state == .secure || state == .sessionUpdatePending, "\(state)")
        }
        // Inside the shell, anything short of a secure, connected link shows the security notice.
        let updating = WatchlinkStore(engine: StateEngine(.sessionUpdatePending))
        XCTAssertTrue(RelationshipShell.showsSecurityNotice(canSend: updating.canSend, connected: true))
        let secure = WatchlinkStore(engine: StateEngine(.secure))
        XCTAssertFalse(RelationshipShell.showsSecurityNotice(canSend: secure.canSend, connected: true))
        XCTAssertTrue(RelationshipShell.showsSecurityNotice(canSend: secure.canSend, connected: false))
    }

    func testHomeCardsFollowStoreAndResolvedCardsDisappear() throws {
        let relationship = RelationshipStore(persistence: MemoryPersistence())
        relationship.apply(.signal(Signal(kind: .footprint)))
        let card = try XCTUnwrap(relationship.homeCards().first)
        XCTAssertEqual(HomeCardContent(card, in: relationship.snapshot)?.actionTitle, "Okay")
        relationship.resolve(card)
        XCTAssertEqual(relationship.homeCards(), [])

        // A card whose feature isn't built yet keeps waiting rather than being dismissed.
        relationship.apply(.revealAnswer(session: UUID(), prompt: "?", category: .serious, answer: "a"))
        let reveal = try XCTUnwrap(relationship.homeCards().first)
        XCTAssertNil(HomeCardContent(reveal, in: relationship.snapshot)?.actionTitle)
        relationship.resolve(reveal)
        XCTAssertEqual(relationship.homeCards(), [reveal])
    }

    func testChatTranscriptNeverReachesRelationshipState() throws {
        let persistence = MemoryPersistence()
        let relationship = RelationshipStore(persistence: persistence)
        let store = WatchlinkStore(engine: StateEngine(.secure))
        if case .failure(let error) = store.send("a very private sentence") { XCTFail("\(error)") }
        store.ingest(["an equally private reply"])
        XCTAssertEqual(store.messages.count, 2)

        relationship.update { $0.jar.append(JarItem(text: "Picnic")) }
        let saved = String(decoding: try JSONEncoder().encode(try XCTUnwrap(persistence.saved)), as: UTF8.self)
        XCTAssertFalse(saved.contains("private sentence"))
        XCTAssertFalse(saved.contains("private reply"))
    }

    func testComposerFollowsCanSend() {
        for state in allStates {
            let store = WatchlinkStore(engine: StateEngine(state))
            XCTAssertEqual(ChatScreen.canSubmit(draft: "hi", canSend: store.canSend), store.canSend, "\(state)")
        }
        XCTAssertFalse(ChatScreen.canSubmit(draft: "   ", canSend: true))
        XCTAssertFalse(ChatScreen.canSubmit(draft: String(repeating: "a", count: WatchlinkStore.maxMessageBytes + 1),
                                            canSend: true))
    }

    func testDeliveryLabelsNeverClaimPeerDelivery() {
        for delivery in [DeliveryState.pending, .sending, .sent, .delivered, .failed] {
            XCTAssertFalse(ChatScreen.deliveryLabel(delivery).localizedCaseInsensitiveContains("deliver"), "\(delivery)")
            XCTAssertFalse(ChatScreen.deliveryLabel(delivery).localizedCaseInsensitiveContains("read"), "\(delivery)")
        }
        XCTAssertEqual(ChatScreen.deliveryLabel(.pending), "Sending")
        XCTAssertEqual(ChatScreen.deliveryLabel(.sent), "Sent")
    }

    func testNoFakePresenceOrPartnerActionsWithoutSync() {
        let relationship = RelationshipStore(persistence: MemoryPersistence())
        XCTAssertEqual(PartnerPresence.current(for: relationship), .unknown)
        XCTAssertFalse(HomeView.partnerActionsEnabled(channelAvailable: relationship.channel.isAvailable, canSend: true))
        XCTAssertFalse(relationship.share(.signal(Signal(kind: .footprint))))
    }
}
