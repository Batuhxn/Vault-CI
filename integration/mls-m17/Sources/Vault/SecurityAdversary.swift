#if WATCHLINK_QUALIFICATION
import Foundation
import WatchlinkMLS

/// In-memory qualification material only. Envelopes contain ciphertext and routing
/// metadata; they are never persisted, printed, or sent to the relay by this harness.
final class SecurityAdversary {
    enum Attack: String, Hashable {
        case exactApplication, staleApplication, tamperApplication, exactCommit, staleCommit
    }
    enum Outcome: String, Hashable { case accepted, rejected, ignored }

    private var application: Envelope?
    private var commit: Envelope?
    private var scope: Scope?
    private(set) var lastInjection: Envelope?
    private(set) var counts: [Attack: [Outcome: Int]] = [:]
    private(set) var lastTest: Attack?
    private(set) var invariantViolations = 0

    private struct Scope: Equatable {
        let conversation: Data?
        let identity: Data
    }

    func scopeTo(conversation: Data?, identity: Data) {
        let current = Scope(conversation: conversation, identity: identity)
        if scope != current { clear(); scope = current }
    }

    func capture(_ envelope: Envelope, identity: Data) {
        scopeTo(conversation: envelope.conversation, identity: identity)
        switch envelope.kind {
        case "application": application = envelope
        case "commit": commit = envelope
        default: break
        }
    }

    func retained(_ attack: Attack) -> Envelope? {
        attack == .exactCommit || attack == .staleCommit ? commit : application
    }

    func clear() { application = nil; commit = nil; scope = nil; lastInjection = nil }

    private struct Snapshot {
        let document: StateDocument?
        let epoch: UInt64?
        let version: UInt64?
        let pendingVersion: UInt64?
        let security: SecurityState
        let messageCount: Int

        @MainActor init(_ engine: MLSCryptoEngine, _ store: WatchlinkStore) {
            document = engine.device?.store.committed
            epoch = engine.device?.group?.currentEpoch()
            let anchor = try? engine.device?.store.anchorStore.load()
            version = anchor?.committedVersion
            pendingVersion = anchor?.pendingVersion
            security = engine.securityState
            messageCount = store.messages.count
        }
    }

    /// Uses the same store → engine → qualified Device.receive path as an
    /// ordinary delivery. Fresh-sequence cases leave MLS bytes unchanged,
    /// except tamperApplication, which flips one MLS wire bit.
    @MainActor
    @discardableResult
    func run(_ attack: Attack, engine: MLSCryptoEngine, store: WatchlinkStore) -> Outcome? {
        scopeTo(conversation: engine.device?.document.conversation, identity: engine.device?.ownPin ?? Data())
        guard let source = retained(attack),
              engine.securityState == .secure,
              source.conversation == engine.device?.document.conversation else { return nil }
        var injected = source
        if attack == .staleApplication || attack == .staleCommit || attack == .tamperApplication {
            guard let last = engine.device?.document.lastSeq,
                  last < UInt64.max else { return nil }
            injected.seq = last + 1
        }
        if attack == .tamperApplication {
            guard !injected.data.isEmpty else { return nil }
            injected.data[injected.data.index(before: injected.data.endIndex)] ^= 0x01
        }
        lastInjection = injected
        let before = Snapshot(engine, store)
        let result = store.receive(injected)
        let after = Snapshot(engine, store)
        let outcome: Outcome
        switch result {
        case .failure: outcome = .rejected
        case .success: outcome = after.messageCount > before.messageCount ? .accepted : .ignored
        }
        counts[attack, default: [:]][outcome, default: 0] += 1
        lastTest = attack

        // Rejected/ignored input must be read-only. The document comparison
        // covers lifecycle, lastSeq, pending commit and durable outbound bytes.
        let readOnly = before.document == after.document && before.epoch == after.epoch
            && before.version == after.version && before.pendingVersion == after.pendingVersion
            && before.security == after.security
        let pendingCoherent = after.document?.pendingCommit == nil
            || after.document?.outbound.contains { $0.kind == "commit" } == true
        let failClosed = after.security == .secure || !store.canSend
        let versionMonotone = before.version.flatMap { old in after.version.map { $0 >= old } } ?? false
        let noStaleCommitEffects = before.document?.groups == after.document?.groups
            && before.document?.lifecycle == after.document?.lifecycle
            && before.document?.pendingCommit == after.document?.pendingCommit
            && before.document?.outbound == after.document?.outbound
            && before.document?.lastSeq == after.document?.lastSeq
        let staleCommitClosed = attack == .staleCommit && outcome == .rejected
            && after.security == .error && !store.canSend
            && before.epoch != nil && after.epoch == nil
            && noStaleCommitEffects && versionMonotone && after.pendingVersion == nil
        let safe = outcome != .accepted && (readOnly || staleCommitClosed)
            && pendingCoherent && failClosed && after.messageCount == before.messageCount
        if !safe { invariantViolations += 1 }
        return outcome
    }

    func summary() -> [String] {
        func count(_ attack: Attack, _ outcome: Outcome) -> Int { counts[attack]?[outcome] ?? 0 }
        return [
            "exact application replay: accepted \(count(.exactApplication, .accepted)) rejected \(count(.exactApplication, .rejected)) ignored \(count(.exactApplication, .ignored))",
            "stale application replay: accepted \(count(.staleApplication, .accepted)) rejected \(count(.staleApplication, .rejected)) ignored \(count(.staleApplication, .ignored))",
            "tampered application: accepted \(count(.tamperApplication, .accepted)) rejected \(count(.tamperApplication, .rejected))",
            "exact commit replay: accepted \(count(.exactCommit, .accepted)) rejected \(count(.exactCommit, .rejected)) ignored \(count(.exactCommit, .ignored))",
            "stale commit replay: accepted \(count(.staleCommit, .accepted)) rejected \(count(.staleCommit, .rejected)) ignored \(count(.staleCommit, .ignored))",
            "last adversarial test: \(lastTest?.rawValue ?? "none")",
            "security invariant violations: \(invariantViolations)"
        ]
    }
}
#endif
