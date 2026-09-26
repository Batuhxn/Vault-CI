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
        session.restoreTest(reboot: false)
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
