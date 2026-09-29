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
                    Menu("Adversarial") {
                        Button("Exact Ciphertext Replay") { attack(.exactApplication) }
                        Button("Stale Ciphertext Replay") { attack(.staleApplication) }
                        Button("Tamper Last Ciphertext") { attack(.tamperApplication) }
                        Button("Exact Commit Replay") { attack(.exactCommit) }
                        Button("Stale Commit Replay") { attack(.staleCommit) }
                    }
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

    private func attack(_ type: SecurityAdversary.Attack) {
        guard let engine else { note = "no engine"; return }
        if let outcome = engine.adversary.run(type, engine: engine, store: store) {
            note = type == .staleCommit && engine.securityState == .error
                ? "staleCommit: rejected; qualified hard stop, Reset Security required"
                : "\(type.rawValue): \(outcome.rawValue); send a fresh peer message to confirm recovery"
        } else {
            note = "\(type.rawValue): no accepted packet available or session unavailable"
        }
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

    static func kind(_ error: Swift.Error) -> String { String(describing: type(of: error)) }
    static func short(_ data: Data?) -> String { data.map { Data(SHA256.hash(data: $0)).prefix(4).hex } ?? "-" }

    static func report(store: WatchlinkStore, transport: LiveTransport?) -> String {
        var lines = ["Watchlink M1.7 sanitized report", "time: \(ISO8601DateFormatter().string(from: Date()))"]
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let relayHost = URL(string: info["WatchlinkRelayURL"] as? String ?? "")?.host ?? "none"
        lines.append("device: \(UIDevice.current.model) \(machine) iOS \(UIDevice.current.systemVersion)")
        lines.append("build: \(version) (\(build))")
        lines.append("relay: \(relayHost)")
        lines.append("ui state: \(store.securityState); connection: \(store.connectionAvailable ? "ok" : "unavailable")")
        guard let engine = transport?.worker.engine else { return (lines + ["engine: no transport"]).joined(separator: "\n") }
        lines.append("engine state: \(engine.securityState)")
        lines.append("wire plaintext checks: passed \(engine.wireChecks.passed), failed \(engine.wireChecks.failed)")
        lines += engine.adversary.summary()
        if let device = engine.device {
            let document = device.store.committed
            let anchor = try? device.store.anchorStore.load()
            let epoch = device.group.map { String($0.currentEpoch()) } ?? "-"
            let committedVersion = anchor.map { String($0.committedVersion) } ?? "?"
            let pendingVersion = anchor?.pendingVersion.map { String($0) } ?? "none"
            let pendingCommit = document.pendingCommit.map { "base \($0.base) \(Data($0.commitId.prefix(4)).hex)" } ?? "none"
            let outbound = document.outbound.map { "\($0.kind) \(short($0.data))" }
            lines.append("own pin: \(device.ownPin.prefix(4).hex)  peer pin: \(document.peerPin?.prefix(4).hex ?? "-")")
            lines.append("conversation: \(short(document.conversation))")
            lines.append("lifecycle: \(document.lifecycle.rawValue)  security: \(document.security.rawValue)")
            lines.append("epoch: \(epoch)  lastSeq: \(document.lastSeq)")
            lines.append("stateVersion: \(committedVersion)  pending: \(pendingVersion)")
            lines.append("pending commit: \(pendingCommit)")
            lines.append("outbound: " + (outbound.isEmpty ? "none" : outbound.joined(separator: ", ")))
            lines.append("key packages outstanding: \(document.keyPackages.count)")
        } else {
            lines.append("identity: none")
        }
        let worker = transport!.worker
        let memberships = worker.memberships.load().map { membership -> String in
            let role = membership.creator ? "creator" : "joiner"
            let state = membership.registered ? "registered" : "unregistered"
            return "\(short(membership.conversation)) \(role) \(state)\(membership.retiring ? " retiring" : "")"
        }
        let sent = store.messages.filter(\.isMine).count
        let received = store.messages.count - sent
        let pending = store.messages.filter { $0.delivery == .pending }.count
        let lastError = worker.lastError.map { "\($0)" } ?? "none"
        let lastSuccess = worker.lastSuccess.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
        lines.append("delivery: \(worker.paused ? "PAUSED" : "active")  last error: \(lastError)")
        lines.append("last relay success: \(lastSuccess)")
        lines.append("memberships: " + memberships.joined(separator: ", "))
        lines.append("messages: sent \(sent), received \(received), pending \(pending)")
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
