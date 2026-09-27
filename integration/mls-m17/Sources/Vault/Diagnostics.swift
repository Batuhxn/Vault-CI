#if WATCHLINK_QUALIFICATION
// M1.7 physical-device qualification surface. Compiled only into qualification
// builds (SWIFT_ACTIVE_COMPILATION_CONDITIONS=WATCHLINK_QUALIFICATION); the
// production Release build contains none of this. The report is sanitized:
// truncated hashes, counters and versions only; never plaintext, keys, QR
// payloads, credentials or protected blobs.
import CryptoKit
import MLSBridge
import ProtectedStateStore
import SwiftUI
import UIKit
import WatchlinkMLS

@MainActor
struct DiagnosticsView: View {
    let store: WatchlinkStore
    let transport: LiveTransport?
    @Environment(\.dismiss) private var dismiss
    @State private var report = ""
    @State private var note = ""

    private var engine: MLSCryptoEngine? { transport?.worker.engine }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                if !note.isEmpty { Text(note).font(.footnote).padding(.horizontal) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Copy") { UIPasteboard.general.string = report }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(Self.paused ? "Resume delivery" : "Pause delivery") {
                        Self.paused.toggle()
                        transport?.worker.paused = Self.paused
                        refresh()
                    }
                    Button("Rotate keys") { rotate() }
                    Button("Inject roster change", role: .destructive) { inject() }
                }
            }
            .navigationTitle("M1.7 Diagnostics")
            .onAppear(perform: refresh)
        }
    }

    /// Persisted so a kill/relaunch keeps delivery held until explicitly resumed.
    static var paused: Bool {
        get { UserDefaults.standard.bool(forKey: "m17.delivery.paused") }
        set { UserDefaults.standard.set(newValue, forKey: "m17.delivery.paused") }
    }

    private func refresh() {
        store.refresh()
        report = Self.report(store: store, transport: transport)
    }

    /// Creates a real self-update commit (pending until the relay decides).
    private func rotate() {
        guard let device = engine?.device else { return }
        do { _ = try device.update(); note = "commit accepted" } catch is RelayUnavailable {
            note = "commit committed; pending relay decision"
        } catch { note = "rotate refused: \(Self.kind(error))" }
        transport?.kick()
        refresh()
    }

    /// Reproduces a validly signed peer identity change as seen by the OTHER device:
    /// this device commits an unknown third member and posts it as-is. The
    /// partner must hard-stop (identityChanged). This device then reloads its
    /// untouched durable state; both devices need an explicit reset afterwards.
    private func inject() {
        guard let engine, let transport, let device = engine.device, let group = device.group,
              let conversation = device.document.conversation,
              let membership = transport.worker.memberships.load().first(where: { $0.conversation == conversation })
        else { note = "not established"; return }
        do {
            let stranger = Client(id: Data("m17-roster-change".utf8),
                                  signatureKeypair: try generateSignatureKeypair(cipherSuite: .curve25519Aes128),
                                  clientConfig: ClientConfig(groupStateStorage: NullStorage(), useRatchetTreeExtension: true))
            let base = group.currentEpoch()
            let commit = try group.addMembers(keyPackages: [stranger.generateKeyPackageMessage()]).commitMessage.toBytes()
            engine.reload()  // discard the in-memory mutation; durable state untouched
            Task {
                let status = try? await transport.worker.api.post(conversation, credential: membership.credential,
                                                                  kind: "commit", base: base, data: commit)
                note = "injected roster change: \(status.map { "\($0)" } ?? "not delivered")"
                refresh()
            }
        } catch { note = "inject failed: \(Self.kind(error))" }
    }

    static func kind(_ error: Error) -> String { String(describing: type(of: error)) }
    static func short(_ data: Data?) -> String { data.map { Data(SHA256.hash(data: $0)).prefix(4).hex } ?? "-" }

    static func report(store: WatchlinkStore, transport: LiveTransport?) -> String {
        var lines = ["Watchlink M1.7 sanitized report", "time: \(ISO8601DateFormatter().string(from: Date()))"]
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let info = Bundle.main.infoDictionary ?? [:]
        lines += [
            "device: \(UIDevice.current.model) \(machine) iOS \(UIDevice.current.systemVersion)",
            "build: \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "relay: \(URL(string: info["WatchlinkRelayURL"] as? String ?? "")?.host ?? "none")",
            "ui state: \(store.securityState); connection: \(store.connectionAvailable ? "ok" : "unavailable")",
        ]
        guard let engine = transport?.worker.engine else { return (lines + ["engine: no transport"]).joined(separator: "\n") }
        lines.append("engine state: \(engine.securityState)")
        lines.append("wire plaintext checks: passed \(engine.wireChecks.passed), failed \(engine.wireChecks.failed)")
        if let device = engine.device {
            let document = device.store.committed
            let anchor = try? device.store.anchorStore.load()
            lines += [
                "own pin: \(device.ownPin.prefix(4).hex)  peer pin: \(document.peerPin?.prefix(4).hex ?? "-")",
                "conversation: \(short(document.conversation))",
                "lifecycle: \(document.lifecycle.rawValue)  security: \(document.security.rawValue)",
                "epoch: \(device.group.map { String($0.currentEpoch()) } ?? "-")  lastSeq: \(document.lastSeq)",
                "stateVersion: \(anchor.map { String($0.committedVersion) } ?? "?")"
                    + "  pending: \(anchor?.pendingVersion.map(String.init) ?? "none")",
                "pending commit: \(document.pendingCommit.map { "base \($0.base) \(Data($0.commitId.prefix(4)).hex)" } ?? "none")",
                "outbound: " + (document.outbound.isEmpty ? "none"
                    : document.outbound.map { "\($0.kind) \(short($0.data))" }.joined(separator: ", ")),
                "key packages outstanding: \(document.keyPackages.count)",
            ]
        } else {
            lines.append("identity: none")
        }
        let worker = transport!.worker
        lines += [
            "delivery: \(worker.paused ? "PAUSED" : "active")  last error: \(worker.lastError.map { "\($0)" } ?? "none")",
            "last relay success: \(worker.lastSuccess.map { ISO8601DateFormatter().string(from: $0) } ?? "never")",
            "memberships: " + worker.memberships.load().map {
                "\(short($0.conversation)) \($0.creator ? "creator" : "joiner") "
                    + "\($0.registered ? "registered" : "unregistered")\($0.retiring ? " retiring" : "")"
            }.joined(separator: ", "),
            "messages: sent \(store.messages.filter(\.isMine).count), received \(store.messages.filter { !$0.isMine }.count), "
                + "pending \(store.messages.filter { $0.delivery == .pending }.count)",
        ]
        return lines.joined(separator: "\n")
    }
}

/// Stranger client storage for the roster-change injection only.
private final class NullStorage: GroupStateStorage, @unchecked Sendable {
    func state(groupId: Data) throws -> Data? { nil }
    func epoch(groupId: Data, epochId: UInt64) throws -> Data? { nil }
    func write(groupId: Data, groupState: Data, epochInserts: [EpochRecord], epochUpdates: [EpochRecord]) throws {}
    func maxEpochId(groupId: Data) throws -> UInt64? { nil }
}
#endif
