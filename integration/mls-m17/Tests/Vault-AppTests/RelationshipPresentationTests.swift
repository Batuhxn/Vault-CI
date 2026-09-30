import SwiftUI
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

@MainActor
final class RelationshipPresentationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_900_000_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testMessageRunsGroupBySenderFiveMinutesAndDay() {
        let messages = [
            LocalMessage(text: "a", isMine: false, timestamp: t0, delivery: .delivered),
            LocalMessage(text: "b", isMine: false, timestamp: t0 + 60, delivery: .delivered),
            LocalMessage(text: "c", isMine: true, timestamp: t0 + 120, delivery: .sent),
            LocalMessage(text: "d", isMine: true, timestamp: t0 + 120 + 301, delivery: .sent),
            LocalMessage(text: "e", isMine: false, timestamp: t0 + 86_400, delivery: .delivered),
        ]
        let runs = MessageRun.group(messages, calendar: utc, now: t0 + 86_400)
        XCTAssertEqual(runs.map { $0.messages.map(\.text) }, [["a", "b"], ["c"], ["d"], ["e"]])
        XCTAssertEqual(runs.map(\.dayBreak), ["Yesterday", nil, nil, "Today"])
        XCTAssertEqual([runs[0].position(of: 0), runs[0].position(of: 1), runs[1].position(of: 0)], [.first, .last, .single])
    }

    func testRunFootersNeverClaimPeerDelivery() {
        let sent = LocalMessage(text: "x", isMine: true, timestamp: t0, delivery: .sent)
        let failed = LocalMessage(text: "y", isMine: true, timestamp: t0 + 10, delivery: .failed)
        let pending = LocalMessage(text: "z", isMine: true, timestamp: t0 + 700, delivery: .pending)
        let runs = MessageRun.group([sent, failed, pending], calendar: utc, now: t0)
        // A failed message stands alone so its state is unambiguous.
        XCTAssertEqual(runs.count, 3)
        XCTAssertTrue(runs[1].footer.hasSuffix("Not sent"))
        XCTAssertTrue(runs[2].footer.hasSuffix("Sending"))
        for footer in runs.map(\.footer) {
            for claim in ["Sent", "deliver", "Deliver", "Read", "Seen", "Online"] where !(claim == "Sent" && footer.hasSuffix("Not sent")) {
                XCTAssertFalse(footer.contains(claim), footer)
            }
        }
    }

    func testTheLetterOnlyFollowsAcceptedSends() {
        XCTAssertEqual(ChatScreen.draftAfterSend(.success(UUID()), draft: "hello"), "")
        for failure in [SecurityFailure.sessionNotSecure, .transportFailed, .messageTooLarge, .unavailable] {
            XCTAssertEqual(ChatScreen.draftAfterSend(.failure(failure), draft: "hello"), "hello")
        }
        // A blocked send inserts nothing, so nothing can animate into the transcript.
        let paused = WatchlinkStore(engine: StateEngine(.sessionUpdatePending))
        let result = paused.send("hello")
        XCTAssertEqual(ChatScreen.draftAfterSend(result, draft: "hello"), "hello")
        XCTAssertTrue(paused.messages.isEmpty)
    }

    func testEncryptionLabelOnlyClaimsWhatSecurityReports() {
        XCTAssertEqual(EncryptionLabel.text(.secure, connected: true), "End-to-end encrypted")
        XCTAssertEqual(EncryptionLabel.text(.secure, connected: false), SecurityStatusView.label(.secure, connected: false))
        for state in [SecurityState.sessionUpdatePending, .identityChanged, .unavailable, .error] {
            XCTAssertEqual(EncryptionLabel.text(state, connected: true), SecurityStatusView.label(state, connected: true))
        }
        XCTAssertFalse(UsView.whereYouAre(.sessionUpdatePending, connected: true).contains("encrypted"))
        XCTAssertFalse(UsView.whereYouAre(.secure, connected: true).localizedCaseInsensitiveContains("verified"))
    }

    func testHeadlinesUseNamesOnlyWhenTheyExist() {
        let evening = utc.date(bySettingHour: 20, minute: 0, second: 0, of: t0)!
        XCTAssertEqual(HomeView.headline(at: evening, name: "", calendar: utc), "Good evening.")
        XCTAssertEqual(HomeView.headline(at: evening, name: "Deniz", calendar: utc), "Good evening,\nDeniz.")
        XCTAssertEqual(UsView.headline(me: Person(displayName: "Deniz"), partner: Person(nickname: "Ada")), "Deniz\n& Ada.")
        XCTAssertEqual(UsView.headline(me: Person(), partner: Person(nickname: "Ada")), "The two\nof you.")
    }

    func testReduceMotionResolvesEveryMoveToACrossfade() {
        for animation in [RelationshipMotion.soft, RelationshipMotion.softHero, RelationshipMotion.softSmall, RelationshipMotion.slow, RelationshipMotion.halo] {
            XCTAssertEqual(RelationshipMotion.resolve(animation, reduceMotion: true), RelationshipMotion.reduced)
            XCTAssertEqual(RelationshipMotion.resolve(animation, reduceMotion: false), animation)
        }
    }

    func testTabGlyphsAreNativeOutlinesWithoutHearts() {
        for destination in RelationshipShell.Destination.allCases {
            XCTAssertFalse(destination.symbol.contains("heart"))
            XCTAssertFalse(destination.symbol.hasSuffix(".fill"), "the system fills only the selected tab")
        }
    }
}
