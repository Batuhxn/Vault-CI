import M15Qualification
import SwiftUI
import UIKit

/// Isolated M1.5 real-device qualification app. Synthetic data only; not part
/// of the Watchlink runtime. Shows labels, statuses and public identifiers only.
@main
struct M15QualificationApp: App {
    @State private var lab = QualificationLab(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("m15", isDirectory: true),
        servicePrefix: "dev.watchlink.m15.qualification")

    var body: some Scene {
        WindowGroup { QualificationView(lab: lab) }
    }
}

/// Keeps the process alive (about 30 s) while the device is being locked.
@MainActor
final class BackgroundRun {
    private var task = UIBackgroundTaskIdentifier.invalid

    func run(_ work: @MainActor () async -> Void) async {
        task = UIApplication.shared.beginBackgroundTask(withName: "m15-lock-probe") { [weak self] in
            Task { @MainActor in self?.end() }
        }
        await work()
        end()
    }

    func end() {
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
    }
}

struct QualificationView: View {
    let lab: QualificationLab
    @State private var background = BackgroundRun()

    private var osVersion: String { UIDevice.current.systemVersion }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    private var report: String { lab.report(osVersion: osVersion, build: build) }
    private var available: @MainActor () -> Bool { { UIApplication.shared.isProtectedDataAvailable } }

    var body: some View {
        NavigationStack {
            List {
                Section("Setup") {
                    Button("Run Setup") {
                        lab.runSetup(osVersion: osVersion, protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
                    }
                    Button("Create Protected State") { lab.createProtectedState() }
                    Button("Reinstall Check") { lab.reinstallCheck() }
                }
                Section("Lock (tap, then lock the device within 5 s)") {
                    Button("Lock Test") { Task { await background.run { await lab.lockTest(seconds: 25, available: available) } } }
                    Button("Lock Test: Verify After Unlock") { lab.lockVerify() }
                    Button("Lock During Operation") {
                        Task { await background.run { await lab.lockDuringOperation(seconds: 25, available: available) } }
                    }
                    Button("Lock During Operation: Verify") { lab.lockDuringOperationVerify() }
                }
                Section("Force-kill / reboot") {
                    Button("Relaunch Test") { lab.restoreTest(reboot: false) }
                    Button("Reboot Test") { lab.restoreTest(reboot: true) }
                    Button("Pending Commit Test") { lab.pendingCommitStart() }
                    Button("Pending Commit: Finish") { lab.pendingCommitFinish() }
                    Button("KeyPackage Test") { lab.keyPackageStart() }
                    Button("KeyPackage: Finish") { lab.keyPackageFinish() }
                    Button("Hard Stop Test") { lab.hardStopStart() }
                    Button("Hard Stop: Finish") { lab.hardStopFinish() }
                }
                Section("Wipe / leakage") {
                    Button("Wipe Test") { lab.wipeTest() }
                    Button("Plaintext Scan") { lab.leakageScan(container: URL(fileURLWithPath: NSHomeDirectory())) }
                    Button("Explicit Wipe (all qualification data)", role: .destructive) { lab.explicitWipe() }
                }
                Section("Show Sanitized Results") {
                    Button("Copy Sanitized Report") { UIPasteboard.general.string = report }
                    ShareLink("Share Sanitized Report", item: report)
                    Button("Clear Results", role: .destructive) { lab.clearResults() }
                    ForEach(lab.results.reversed()) { line in
                        VStack(alignment: .leading) {
                            Text("[\(line.status)] \(line.test)").font(.caption.bold())
                            Text(line.detail).font(.caption2)
                        }
                    }
                }
            }
            .disabled(lab.busy)
            .navigationTitle("M1.5 Qualification")
        }
    }
}
