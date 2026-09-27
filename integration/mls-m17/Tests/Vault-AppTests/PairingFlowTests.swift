import Foundation
@testable import WatchlinkMLS
import XCTest

/// Fake camera permission (the simulator has no camera).
final class FakeCamera: CameraAccess {
    var permission: CameraPermission
    var grant: Bool
    private(set) var requests = 0
    init(_ permission: CameraPermission, grant: Bool = true) { self.permission = permission; self.grant = grant }
    func requestAccess() async -> Bool {
        requests += 1
        permission = grant ? .authorized : .denied
        return grant
    }
}

/// M1.7 pairing UI/state integration: explicit initiation, a stable QR, a
/// one-tap scanner that survives refreshes, and labels that never present
/// relay reachability as a verified secure session.
@MainActor
final class PairingFlowTests: XCTestCase {
    private let clock = TestClock()
    private var root: URL!
    private var endpoints: [Endpoint] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("m17ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        endpoints.forEach { $0.cleanup() }
        try? FileManager.default.removeItem(at: root)
    }

    private func endpoint(_ api: any RelayAPI, camera: CameraPermission = .authorized) -> Endpoint {
        let e = Endpoint(service: "com.batuhxn.watchlink.m17ui.\(UUID().uuidString)",
                         directory: root.appendingPathComponent(UUID().uuidString, isDirectory: true), api: api, clock: clock)
        e.store.camera = FakeCamera(camera)
        endpoints.append(e)
        return e
    }

    /// What the app's poll loop does every 2 s and on every return to the foreground.
    private func pollChurn(_ e: Endpoint, times: Int = 5) async {
        for n in 0..<times {
            e.store.connectionAvailable = n % 2 == 0
            await e.transport.round()
            e.store.reopenIfUnavailable()
            e.store.refresh()
        }
        e.store.connectionAvailable = true
    }

    // 1-3
    func testFreshInstallCreatesLinkAndQRStaysPresented() async throws {
        let a = endpoint(FakeRelayAPI(clock: clock))
        XCTAssertEqual(a.store.rootState, .welcome, "fresh install lands on the explicit start screen")
        XCTAssertTrue(a.store.createLink(), "explicit create action")
        XCTAssertEqual(a.store.rootState, .pairing)
        guard case .showCode(let code, true) = a.store.pairingStep else { return XCTFail("QR not shown") }
        await pollChurn(a)
        XCTAssertEqual(a.store.rootState, .pairing, "QR screen stable across refreshes")
        XCTAssertEqual(a.store.pairingStep, .showCode(code, scanPartnerNext: true), "same code, not reset")
    }

    // 4-7: the joiner path that used to race the 2 s refresh
    func testOneTapScannerSurvivesRefreshesOnFreshJoiner() async throws {
        let b = endpoint(FakeRelayAPI(clock: clock))
        b.store.beginPairing()
        await b.store.requestScan()
        XCTAssertEqual(b.store.scanner, .scanning, "one tap presents the scanner")
        XCTAssertEqual(b.store.rootState, .pairing)
        await pollChurn(b, times: 8)
        XCTAssertEqual(b.store.scanner, .scanning, "refreshes never dismiss the scanner")
        XCTAssertEqual(b.store.rootState, .pairing, "joiner screen never snaps back")
        await b.store.requestScan()
        XCTAssertEqual(b.store.scanner, .scanning, "repeated taps are harmless")

        XCTAssertEqual(b.store.scanned(Data("https://example.invalid/not-watchlink".utf8)), .ignored)
        XCTAssertEqual(b.store.scanner, .scanning, "a non-Watchlink QR keeps the scanner open")
        b.store.cancelScan()
        XCTAssertEqual(b.store.scanner, .idle, "explicit cancel closes it")
        XCTAssertEqual(b.store.rootState, .pairing, "cancelling the scanner keeps the pairing screen")
        b.store.cancelPairing()
        XCTAssertEqual(b.store.rootState, .welcome)
    }

    func testScannerDismissesOnValidScanAndOnCameraFailure() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        XCTAssertTrue(a.store.createLink())
        guard case .showCode(let codeA, _) = a.store.pairingStep else { return XCTFail("no code") }
        b.store.beginPairing()
        await b.store.requestScan()
        XCTAssertEqual(b.store.scanned(codeA), .accepted)
        XCTAssertEqual(b.store.scanner, .idle, "valid code processed -> closed")
        guard case .showCode(_, false) = b.store.pairingStep else { return XCTFail("joiner reply code not shown") }

        await a.store.requestScan()
        a.store.scannerFailed()
        XCTAssertEqual(a.store.scanner, .failed, "real camera error closes and reports")
        a.store.acknowledgeScannerNotice()
        await a.store.requestScan()
        XCTAssertEqual(a.store.scanner, .scanning, "retry after a failure is one tap")
    }

    func testRejectedWatchlinkCodeClosesScannerAndReportsIt() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        XCTAssertTrue(a.store.createLink())
        guard case .showCode(let codeA, _) = a.store.pairingStep else { return XCTFail("no code") }
        clock.now += qrTTL + 1
        b.store.beginPairing()
        await b.store.requestScan()
        XCTAssertEqual(b.store.scanned(codeA), .rejected, "expired code is processed once and refused")
        XCTAssertEqual(b.store.scanner, .idle)
    }

    // Camera permission
    func testCameraPermissionPaths() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let firstTime = endpoint(relay, camera: .notDetermined)
        await firstTime.store.requestScan()
        XCTAssertEqual(firstTime.store.scanner, .scanning, "first request granted -> scanner in the same tap")
        XCTAssertEqual((firstTime.store.camera as? FakeCamera)?.requests, 1)

        let refused = endpoint(relay, camera: .notDetermined)
        (refused.store.camera as? FakeCamera)?.grant = false
        await refused.store.requestScan()
        XCTAssertEqual(refused.store.scanner, .permissionDenied)

        let allowed = endpoint(relay, camera: .authorized)
        await allowed.store.requestScan()
        XCTAssertEqual(allowed.store.scanner, .scanning)
        XCTAssertEqual((allowed.store.camera as? FakeCamera)?.requests, 0, "no prompt when already allowed")

        let denied = endpoint(relay, camera: .denied)
        await denied.store.requestScan()
        XCTAssertEqual(denied.store.scanner, .permissionDenied, "denied -> settings notice, no scanner")
        XCTAssertEqual((denied.store.camera as? FakeCamera)?.requests, 0)
        denied.store.acknowledgeScannerNotice()
        (denied.store.camera as? FakeCamera)?.permission = .authorized  // user enabled it in Settings and returned
        await denied.store.requestScan()
        XCTAssertEqual(denied.store.scanner, .scanning, "returning from Settings: one tap opens the scanner")
    }

    // 8-9
    func testRelayReachabilityIsNeverASecureStateUntilMutualPairing() async throws {
        let relay = FakeRelayAPI(clock: clock)
        let a = endpoint(relay), b = endpoint(relay)
        for state in [SecurityState.notPaired, .pairing, .establishingSecureSession, .sessionUpdatePending,
                      .identityChanged, .unavailable, .error] {
            let label = SecurityStatusView.label(state, connected: true)
            XCTAssertNotEqual(label, "Secure connection established", "\(state)")
            XCTAssertFalse(label.localizedCaseInsensitiveContains("connected"), "\(state): \(label)")
        }
        XCTAssertEqual(SecurityStatusView.label(.secure, connected: false), "Connection unavailable")

        XCTAssertTrue(a.store.createLink())
        guard case .showCode(let codeA, true) = a.store.pairingStep else { return XCTFail("no code") }
        XCTAssertTrue(b.store.acceptScanned(codeA))
        guard case .showCode(let codeB, false) = b.store.pairingStep else { return XCTFail("no reply") }
        for _ in 0..<6 { await a.transport.round(); await b.transport.round() }
        XCTAssertTrue(a.store.connectionAvailable && b.store.connectionAvailable, "relay reachable")
        XCTAssertNotEqual(a.store.securityState, .secure, "reachable relay alone is not a secure session")
        XCTAssertNotEqual(b.store.securityState, .secure)

        XCTAssertTrue(a.store.acceptScanned(codeB))
        for _ in 0..<6 { await a.transport.round(); await b.transport.round() }
        for e in [a, b] {
            XCTAssertEqual(e.store.securityState, .secure)
            XCTAssertEqual(e.store.rootState, .chats)
            XCTAssertEqual(SecurityStatusView.label(e.store.securityState, connected: e.store.connectionAvailable),
                           "Secure connection established")
            XCTAssertTrue(e.store.canSend, "conversation can be started right away")
        }
    }
}
