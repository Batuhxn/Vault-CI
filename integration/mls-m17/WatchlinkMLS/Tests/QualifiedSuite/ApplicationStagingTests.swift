import Foundation
import MLSBridge
import ProtectedStateStore
@testable import WatchlinkMLS
import XCTest

/// M1.7 requalification of the one qualified-core change: application
/// ciphertext is staged in the same transaction as the MLS state it depends
/// on, and released only from committed state.
final class ApplicationStagingTests: XCTestCase {
    private func applications(_ relay: Relay, _ device: Device) -> [Envelope] {
        relay.fetch(device.document.conversation!, recipient: "", after: 0).filter { $0.kind == "application" }
    }

    func testCiphertextIsDurableBeforeItIsTransportVisible() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let (a, _) = try h.pair(relay)
        var events: [String] = []
        a.store.faults.observer = { events.append($0) }
        let wire = try a.send(Data("durable first".utf8))
        let anchored = try XCTUnwrap(events.firstIndex(of: "anchored"))
        let released = try XCTUnwrap(events.firstIndex(of: "outbound-released"))
        XCTAssertLessThan(anchored, released, "anchor committed before release")
        XCTAssertEqual(applications(relay, a).last?.data, wire)
        XCTAssertTrue(a.document.outbound.isEmpty, "dropped only after the post succeeded")
    }

    /// Every crash point either leaves no durable state change, or leaves the
    /// exact ciphertext recoverable. Never advanced state without its bytes.
    func testEveryCrashPointIsAllOrNothingAndRecoverable() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let (a, b) = try h.pair(relay)
        for point in ["reserved", "group-written", "sealed", "replaced", "anchored"] {
            let caseRelay = relay.copy()
            let device = try h.clone(a, relay: caseRelay)
            let committed = try h.versions(device).committed
            device.store.faults.crashAt = point
            XCTAssertThrows(SimulatedCrash.self, try device.send(Data("crash \(point)".utf8)))
            XCTAssertTrue(applications(caseRelay, device).isEmpty, "nothing released at \(point)")
            if point == "anchored" {
                let restored = try h.reopen(device)
                XCTAssertEqual(try h.versions(restored).committed, committed + 1)
                let persisted = try XCTUnwrap(restored.document.outbound.first { $0.kind == "application" }).data
                try restored.releaseOutbound()
                XCTAssertEqual(applications(caseRelay, restored).map(\.data), [persisted], "exact bytes, once")
                XCTAssertTrue(restored.document.outbound.isEmpty)
            } else {
                XCTAssertThrows(Closed.self, try h.reopen(device), "abandoned marker fails closed at \(point)")
                XCTAssertEqual(try h.versions(device).committed, committed, "no durable partial send at \(point)")
            }
        }
        // The original session is unaffected by the clones.
        try a.send(Data("still works".utf8))
        XCTAssertEqual(try b.sync(), [Data("still works".utf8)])
    }

    /// Crash after commit, before transport acknowledgement: relaunch retries
    /// the exact bytes; duplicates never yield a second plaintext.
    func testRelaunchBeforeAckRetriesExactBytesWithoutDuplicatePlaintext() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let (a, b) = try h.pair(relay)
        relay.offline = true
        XCTAssertThrows(RelayUnavailable.self, try a.send(Data("queued".utf8)))
        let persisted = try XCTUnwrap(a.document.outbound.first { $0.kind == "application" }).data
        XCTAssertThrows(RelayUnavailable.self, try a.releaseOutbound(), "repeated failure")
        XCTAssertEqual(a.document.outbound.map(\.data), [persisted], "no replacement ciphertext")
        XCTAssertEqual(a.document.security, .ok, "transport failure is not a reset")

        let restarted = try h.reopen(a)
        XCTAssertEqual(restarted.document.outbound.map(\.data), [persisted], "survives relaunch")
        relay.offline = false
        try restarted.releaseOutbound()
        XCTAssertEqual(applications(relay, restarted).map(\.data), [persisted], "byte-identical")
        XCTAssertEqual(try b.sync(), [Data("queued".utf8)])

        // At-least-once transport: the same ciphertext delivered again under a new sequence.
        let conversation = restarted.document.conversation!
        let again = try relay.post(conversation, kind: "application", base: nil, data: persisted, sender: "alice")
        guard case .ok(let seq) = again else { return XCTFail("relay model accepts duplicates") }
        let before = try h.versions(b)
        XCTAssertThrows(Rejected.self, try b.receive(relay.entry(conversation, seq: seq)))
        XCTAssertTrue(try h.versions(b) == before, "duplicate ciphertext: no plaintext, no mutation")
    }

    func testPersistenceAndAnchorFailuresReleaseNothingAndFailClosed() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let (a, _) = try h.pair(relay)
        for point in ["sealed", "replaced"] {  // file write failure; anchor update never happens
            let caseRelay = relay.copy()
            let device = try h.clone(a, relay: caseRelay)
            let committed = try h.versions(device).committed
            device.store.faults.failAt = point
            XCTAssertThrows(Closed.self, try device.send(Data("fail \(point)".utf8)))
            XCTAssertTrue(applications(caseRelay, device).isEmpty, "nothing released at \(point)")
            XCTAssertNil(device.client, "session closed")
            XCTAssertThrows(Closed.self, try h.reopen(device), "fails closed at \(point)")
            XCTAssertEqual(try h.versions(device).committed, committed)
        }
    }

    func testPendingApplicationItemsDoNotBlockOrReorderAndPendingCommitStillBlocks() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let (a, b) = try h.pair(relay)
        relay.offline = true
        XCTAssertThrows(RelayUnavailable.self, try a.send(Data("one".utf8)))
        XCTAssertThrows(RelayUnavailable.self, try a.send(Data("two".utf8)))
        XCTAssertEqual(a.document.outbound.count, 2)
        relay.offline = false
        try a.releaseOutbound()
        XCTAssertEqual(try b.sync(), [Data("one".utf8), Data("two".utf8)], "relay order = send order")

        relay.offline = true
        XCTAssertThrows(RelayUnavailable.self, try a.update())
        XCTAssertThrows(Rejected.self, try a.send(Data("blocked".utf8)), "pending commit still blocks sends")
        XCTAssertNil(a.document.outbound.first { $0.kind == "application" })
    }
}
