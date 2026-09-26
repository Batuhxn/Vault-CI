import Foundation
@testable import M15Qualification
import XCTest

/// Simulator smoke run of every M1.5 scenario so logic errors surface before a
/// manual device session. A "force-kill" is modelled by a brand-new lab that
/// reloads everything (devices and relay) from disk. This is NOT M1.5 evidence:
/// the simulator does not enforce lock state or Data Protection.
@MainActor
final class ScenarioTests: XCTestCase {
    private var root: URL!
    private var prefix = ""

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("m15-\(UUID().uuidString)")
        prefix = "dev.watchlink.m15.test.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        lab().explicitWipe(record: false)
        try? FileManager.default.removeItem(at: root)
    }

    private func lab() -> QualificationLab { QualificationLab(root: root, servicePrefix: prefix) }

    /// New results since `from` contain no FAIL (simulator-unobservable checks excluded).
    private func assertNoFailure(_ lab: QualificationLab, from: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        let failures = lab.results.dropFirst(from).filter {
            $0.status == "FAIL" && $0.test != "Data Protection class"
        }
        XCTAssertTrue(failures.isEmpty, failures.map { "\($0.test): \($0.detail)" }.joined(separator: "; "),
                      file: file, line: line)
    }

    func testFullScenarioSequenceWithSimulatedKills() async throws {
        var session = lab()
        session.runSetup(osVersion: "simulator", protectedDataAvailable: true)
        session.createProtectedState()
        XCTAssertTrue(session.results.contains { $0.test == "Create Protected State" && $0.status == "PASS" })
        assertNoFailure(session)

        session = lab()  // force-kill + relaunch
        session.relaunchTest()
        session.pendingCommitStart()
        session = lab()
        session.pendingCommitFinish()
        session.keyPackageStart()
        session = lab()
        session.keyPackageFinish()
        session.hardStopStart()
        session = lab()
        session.hardStopFinish()
        assertNoFailure(session)
        XCTAssertEqual(session.results.filter { $0.test == "Pending Commit: Finish" && $0.status == "PASS" }.count, 4)
        XCTAssertEqual(session.results.filter { $0.test == "KeyPackage: Finish" && $0.status == "PASS" }.count, 3)
        XCTAssertTrue(session.results.contains { $0.test == "Hard Stop: Finish" && $0.status == "PASS" })

        await session.lockDuringOperation(seconds: 1, available: { true })
        session.lockDuringOperationVerify()
        XCTAssertTrue(session.results.contains { $0.test == "Lock During Operation (ordering)" && $0.status == "PASS" })
        assertNoFailure(session)

        let before = session.results.count
        session.wipeTest()
        XCTAssertEqual(session.results.dropFirst(before).filter { $0.status == "PASS" }.count, 4)
        session.leakageScan(container: root)
        assertNoFailure(session)
        XCTAssertTrue(session.report(osVersion: "sim", build: "0").contains("[PASS] Plaintext Scan"))
    }

    func testReinstallWithLeftoverKeychainFailsClosed() async throws {
        let session = lab()
        session.runSetup(osVersion: "simulator", protectedDataAvailable: true)
        session.createProtectedState()
        // Model a reinstall: the app container is deleted, Keychain items survive.
        for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: entry)
        }
        let reinstalled = lab()
        reinstalled.reinstallCheck()
        XCTAssertEqual(reinstalled.results.last?.test, "Reinstall Check")
        XCTAssertEqual(reinstalled.results.last?.status, "PASS")
    }

    // MARK: Reboot Test regression (a false "reboot observed" must be impossible)

    private func preparedLab(boot: BootSnapshot) -> QualificationLab {
        let session = lab()
        session.bootSource = { boot }
        session.runSetup(osVersion: "simulator", protectedDataAvailable: true)
        session.createProtectedState()
        session.rebootPrepare()
        return session
    }

    private let sameBoot = BootSnapshot(bootTime: 1_789_990_921, bootSession: "A1B2C3D4-SAME", wallClock: 1_790_000_000)

    func testPrepareThenVerifyWithoutRebootIsNotObserved() async throws {
        let session = preparedLab(boot: sameBoot)
        XCTAssertTrue(session.results.contains { $0.detail.hasPrefix("REBOOT_PENDING") })
        XCTAssertFalse(session.results.contains { $0.test.hasPrefix("Reboot Test") && $0.status == "PASS" },
                       "prepare must not claim a reboot")
        session.bootSource = { BootSnapshot(bootTime: 1_789_990_921, bootSession: "A1B2C3D4-SAME", wallClock: 1_790_000_090) }
        session.rebootVerify()
        let last = try XCTUnwrap(session.results.last)
        XCTAssertEqual(last.status, "NOT_OBSERVED")
        XCTAssertTrue(last.detail.hasPrefix("REBOOT_NOT_OBSERVED"))
        XCTAssertNotNil(try session.baseline().rebootPending, "still pending")
    }

    func testRepeatedVerifyWithoutRebootNeverPasses() async throws {
        let session = preparedLab(boot: sameBoot)
        for drift: Int64 in [0, 1, -2, 3] {  // small wall-clock adjustments of kern.boottime
            session.bootSource = { BootSnapshot(bootTime: 1_789_990_921 + drift, bootSession: "A1B2C3D4-SAME",
                                                wallClock: 1_790_000_100) }
            session.rebootVerify()
            XCTAssertEqual(session.results.last?.status, "NOT_OBSERVED")
        }
        XCTAssertFalse(session.results.contains { $0.test == "Reboot Test: Verify" && $0.status == "PASS" })
    }

    func testSimulatedRebootIsDetectedAndClearsPending() async throws {
        let session = preparedLab(boot: sameBoot)
        session.bootSource = { BootSnapshot(bootTime: 1_790_000_300, bootSession: "E5F6-NEW", wallClock: 1_790_000_400) }
        let before = session.results.count
        session.rebootVerify()
        let verify = session.results.dropFirst(before)
        XCTAssertTrue(verify.first?.detail.hasPrefix("REBOOT_OBSERVED") == true)
        XCTAssertEqual(verify.filter { $0.status == "PASS" }.count, 5, "reboot + identity + conversation + version + messaging")
        XCTAssertFalse(verify.contains { $0.status == "FAIL" })
        XCTAssertNil(try session.baseline().rebootPending, "cleared only after successful verification")
    }

    func testRebootEvidenceRules() {
        let prepared = sameBoot
        let unchanged = BootSnapshot(bootTime: prepared.bootTime, bootSession: prepared.bootSession, wallClock: prepared.wallClock + 60)
        XCTAssertFalse(BootSnapshot.rebootObserved(prepared: prepared, now: unchanged))
        let clockAdjusted = BootSnapshot(bootTime: prepared.bootTime + 4, bootSession: prepared.bootSession, wallClock: prepared.wallClock + 60)
        XCTAssertFalse(BootSnapshot.rebootObserved(prepared: prepared, now: clockAdjusted))
        let sameSessionLaterBoot = BootSnapshot(bootTime: prepared.wallClock + 30, bootSession: prepared.bootSession, wallClock: prepared.wallClock + 90)
        XCTAssertFalse(BootSnapshot.rebootObserved(prepared: prepared, now: sameSessionLaterBoot), "session must change when reported")
        let rebooted = BootSnapshot(bootTime: prepared.wallClock + 30, bootSession: "NEW", wallClock: prepared.wallClock + 90)
        XCTAssertTrue(BootSnapshot.rebootObserved(prepared: prepared, now: rebooted))
        let noSession = BootSnapshot(bootTime: prepared.wallClock + 30, bootSession: nil, wallClock: prepared.wallClock + 90)
        XCTAssertTrue(BootSnapshot.rebootObserved(prepared: BootSnapshot(bootTime: 1, bootSession: nil, wallClock: prepared.wallClock), now: noSession))
    }

    func testBaselineRoundTripPreservesExactBootValues() throws {
        let snapshot = BootSnapshot(bootTime: 1_789_990_921, bootSession: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0",
                                    wallClock: Int64.max - 1)
        let baseline = Baseline(conversation: Data(repeating: 7, count: 16), alicePin: Data(repeating: 1, count: 32),
                                bobPin: Data(repeating: 2, count: 32), aliceVersion: UInt64.max, bobVersion: 9,
                                bootTime: Int64.min + 1, ownNonce: nil, pendingCommitHash: nil, rebootPending: snapshot)
        let decoded = try JSONDecoder().decode(Baseline.self, from: JSONEncoder().encode(baseline))
        XCTAssertEqual(decoded.rebootPending, snapshot)
        XCTAssertEqual(decoded.bootTime, Int64.min + 1)
        XCTAssertEqual(decoded.aliceVersion, UInt64.max)
    }

    func testReportCarriesNoSecretsOrPlaintext() async throws {
        let session = lab()
        session.runSetup(osVersion: "simulator", protectedDataAvailable: true)
        session.createProtectedState()
        let report = session.report(osVersion: "sim", build: "0")
        for marker in plaintextMarkers { XCTAssertFalse(report.contains(marker)) }
        XCTAssertFalse(report.localizedCaseInsensitiveContains("secret"))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("private key"))
    }
}
