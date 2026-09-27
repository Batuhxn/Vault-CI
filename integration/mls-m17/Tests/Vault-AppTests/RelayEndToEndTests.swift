import Foundation
@testable import WatchlinkMLS
import XCTest

/// Two production installations against the real relay Worker (`wrangler dev`
/// in CI, via TEST_RUNNER_WATCHLINK_RELAY_URL). CI then scans the relay's
/// persisted Durable Object storage for the marker below.
@MainActor
final class RelayEndToEndTests: XCTestCase {
    static let marker = "M17-E2E-RELAY-MARKER-8b41"

    func testRealRelayPairingMessagingAndRetire() async throws {
        guard let value = ProcessInfo.processInfo.environment["WATCHLINK_RELAY_URL"], let url = URL(string: value) else {
            throw XCTSkip("no relay configured")
        }
        let clock = TestClock()
        clock.now = Int64(Date().timeIntervalSince1970)  // the real relay checks claim expiry against its clock
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m17e2e-\(UUID().uuidString)")
        func endpoint() -> Endpoint {
            Endpoint(service: "com.batuhxn.watchlink.m17e2e.\(UUID().uuidString)",
                     directory: root.appendingPathComponent(UUID().uuidString), api: HTTPRelayAPI(base: url), clock: clock)
        }
        let a = endpoint(), b = endpoint()
        defer {
            a.cleanup()
            b.cleanup()
            try? FileManager.default.removeItem(at: root)
        }
        func settle() async {
            for _ in 0..<8 {
                await a.transport.round()
                await b.transport.round()
            }
        }

        XCTAssertTrue(a.store.createLink())
        guard case .showCode(let codeA, true) = a.store.pairingStep else { return XCTFail("no code") }
        XCTAssertTrue(b.store.acceptScanned(codeA))
        guard case .showCode(let codeB, false) = b.store.pairingStep else { return XCTFail("no reply") }
        await settle()
        XCTAssertTrue(a.store.acceptScanned(codeB))
        await settle()
        XCTAssertEqual(a.store.securityState, .secure, "\(String(describing: a.worker.lastError))")
        XCTAssertEqual(b.store.securityState, .secure, "\(String(describing: b.worker.lastError))")
        XCTAssertEqual(a.device.document.peerPin, b.device.ownPin)
        XCTAssertEqual(b.device.document.peerPin, a.device.ownPin)

        _ = a.store.send(Self.marker)
        _ = b.store.send("\(Self.marker) reply ✓")
        await settle()
        XCTAssertEqual(b.received, [Self.marker])
        XCTAssertEqual(a.received, ["\(Self.marker) reply ✓"])
        XCTAssertEqual(a.engine.wireChecks.failed + b.engine.wireChecks.failed, 0)

        // Keep one undelivered ciphertext on the relay for the storage scan.
        _ = a.store.send("\(Self.marker) undelivered")
        await a.transport.round()

        let conversation = try XCTUnwrap(a.device.document.conversation)
        a.store.resetSecurity()
        await a.transport.round()
        XCTAssertNil(a.worker.memberships.load().first { $0.conversation == conversation }, "retired and forgotten")
        let late = try? await HTTPRelayAPI(base: url).open(conversation, credential: Data(repeating: 1, count: 32),
                                                          claimVerifier: Data(repeating: 2, count: 32),
                                                          claimExpires: Int64(Date().timeIntervalSince1970) + 60)
        XCTAssertNil(late, "retired conversation cannot be reopened")
    }
}
