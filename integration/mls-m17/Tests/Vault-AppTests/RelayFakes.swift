import CryptoKit
import Foundation
import ProtectedStateStore
import Security
@testable import WatchlinkMLS
import XCTest

/// Shared test clock (seconds).
final class TestClock: @unchecked Sendable { var now: Int64 = 1_900_000_000 }

/// In-memory relay with the same semantics as relay/src/mailbox.ts (slots,
/// one-time claim, qualified commit sequencing, idempotent ids, ack, retire).
/// It only ever holds what clients post: ciphertext/protocol bytes.
final class FakeRelayAPI: RelayAPI {
    struct Row { var seq: UInt64; var sender: String; var kind: String; var base: UInt64?; var id: Data; var data: Data? }
    struct Mailbox {
        var a: Data?
        var b: Data?
        var claim: Data?
        var claimExpires: Int64 = 0
        var current: UInt64 = 0
        var nextSeq: UInt64 = 1
        var commits: [UInt64: (id: Data, seq: UInt64)] = [:]
        var rows: [Row] = []
        var retired = false
    }

    let clock: TestClock
    var mailboxes: [Data: Mailbox] = [:]
    var offline = false
    /// Every item any client ever posted (for plaintext scans).
    private(set) var postedItems: [(kind: String, data: Data)] = []
    var posted: [Data] { postedItems.map(\.data) }

    init(clock: TestClock) { self.clock = clock }

    private func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private func up() throws { if offline { throw URLError(.notConnectedToInternet) } }

    private func slot(_ box: Mailbox, _ credential: Data) throws -> String {
        let verifier = hash(credential)
        if verifier == box.a { return "a" }
        if verifier == box.b { return "b" }
        throw RelayError.http(401)
    }

    func open(_ conversation: Data, credential: Data, claimVerifier: Data, claimExpires: Int64) async throws {
        try up()
        var box = mailboxes[conversation] ?? Mailbox()
        if box.retired { throw RelayError.http(410) }
        if let a = box.a { if a == hash(credential) { return } else { throw RelayError.http(409) } }
        guard claimExpires > clock.now, claimExpires <= clock.now + 600 else { throw RelayError.http(400) }
        box.a = hash(credential)
        box.claim = claimVerifier
        box.claimExpires = claimExpires
        mailboxes[conversation] = box
    }

    func claim(_ conversation: Data, credential: Data, claim: Data) async throws {
        try up()
        guard var box = mailboxes[conversation], box.a != nil else { throw RelayError.http(404) }
        if box.retired { throw RelayError.http(410) }
        if let b = box.b { if b == hash(credential) { return } else { throw RelayError.http(409) } }
        if clock.now > box.claimExpires { throw RelayError.http(410) }
        guard hash(claim) == box.claim else { throw RelayError.http(403) }
        box.b = hash(credential)
        box.claim = nil
        mailboxes[conversation] = box
    }

    func post(_ conversation: Data, credential: Data, kind: String, base: UInt64?, data: Data) async throws -> RelayStatus {
        try up()
        guard var box = mailboxes[conversation] else { throw RelayError.http(401) }
        let sender = try slot(box, credential)
        postedItems.append((kind, data))
        if box.retired { return .reject }
        let id = hash(data)
        if let prior = box.rows.first(where: { $0.id == id && $0.sender == sender }) {
            return kind == "commit" ? .accepted(prior.seq) : .ok(prior.seq)
        }
        let seq = box.nextSeq
        if kind == "commit" {
            guard let base else { return .reject }
            if base < box.current {
                guard let accepted = box.commits[base] else { return .reject }
                return accepted.id == id ? .accepted(accepted.seq) : .stale(accepted.seq)
            }
            guard base == box.current else { return .reject }
            box.commits[base] = (id, seq)
            box.current += 1
        }
        box.rows.append(Row(seq: seq, sender: sender, kind: kind, base: base, id: id, data: data))
        box.nextSeq += 1
        mailboxes[conversation] = box
        return kind == "commit" ? .accepted(seq) : .ok(seq)
    }

    func fetch(_ conversation: Data, credential: Data, after: UInt64) async throws -> [Envelope] {
        try up()
        guard let box = mailboxes[conversation] else { throw RelayError.http(401) }
        let me = try slot(box, credential)
        return box.rows.filter { $0.sender != me && $0.seq > after && $0.data != nil }.map {
            Envelope(conversation: conversation, seq: $0.seq, kind: $0.kind, base: $0.base, data: $0.data!, sender: RelayPort.peer)
        }
    }

    func ack(_ conversation: Data, credential: Data, through: UInt64) async throws {
        try up()
        guard var box = mailboxes[conversation] else { throw RelayError.http(401) }
        let me = try slot(box, credential)
        for index in box.rows.indices where box.rows[index].sender != me && box.rows[index].seq <= through {
            box.rows[index].data = nil
        }
        mailboxes[conversation] = box
    }

    func retire(_ conversation: Data, credential: Data) async throws {
        try up()
        guard var box = mailboxes[conversation] else { throw RelayError.http(401) }
        _ = try slot(box, credential)
        box.retired = true
        for index in box.rows.indices { box.rows[index].data = nil }
        mailboxes[conversation] = box
    }

    /// Everything the relay currently stores (payload bytes).
    var stored: [Data] { mailboxes.values.flatMap { $0.rows.compactMap(\.data) } }
}

/// A compromised relay. It never has MLS keys; it can only lie about, reorder,
/// drop, duplicate, replay or corrupt what passes through it.
final class AdversarialRelayAPI: RelayAPI {
    enum Mode: Hashable {
        case duplicate, reorder, dropAck, dropMessage, replayPrior, replayCommit, forgeFutureSeq, wrongBase, corrupt, truncate
        case randomBytes, forgedAccept, delay, ackFails
    }

    let inner: FakeRelayAPI
    var modes: Set<Mode> = []
    private var seen: [Envelope] = []

    init(_ inner: FakeRelayAPI) { self.inner = inner }

    func open(_ c: Data, credential: Data, claimVerifier: Data, claimExpires: Int64) async throws {
        try await inner.open(c, credential: credential, claimVerifier: claimVerifier, claimExpires: claimExpires)
    }

    func claim(_ c: Data, credential: Data, claim: Data) async throws {
        try await inner.claim(c, credential: credential, claim: claim)
    }

    func post(_ c: Data, credential: Data, kind: String, base: UInt64?, data: Data) async throws -> RelayStatus {
        if modes.contains(.dropMessage) && kind == "application" { return .ok(9_999) }  // lie: never stored
        if modes.contains(.forgedAccept) && kind == "commit" { return .accepted(9_999) }  // lie: never stored
        let status = try await inner.post(c, credential: credential, kind: kind, base: base, data: data)
        if modes.contains(.dropAck) { throw URLError(.timedOut) }  // stored, but the answer is lost
        return status
    }

    func fetch(_ c: Data, credential: Data, after: UInt64) async throws -> [Envelope] {
        if modes.contains(.delay) { return [] }
        var envelopes = try await inner.fetch(c, credential: credential, after: after)
        let fresh = envelopes
        func flip(_ data: Data) -> Data { var d = data; d[d.index(before: d.endIndex)] ^= 1; return d }
        envelopes = envelopes.map { envelope in
            var e = envelope
            if e.kind == "application" {
                if modes.contains(.corrupt) { e.data = flip(e.data) }
                if modes.contains(.truncate) { e.data = e.data.prefix(e.data.count / 2) }
                if modes.contains(.randomBytes) { e.data = Data((0..<e.data.count).map { _ in UInt8.random(in: 0...255) }) }
            }
            if e.kind == "commit", modes.contains(.wrongBase) { e.base = (e.base ?? 0) + 7 }
            if modes.contains(.forgeFutureSeq) { e.seq += 1_000 }
            return e
        }
        if modes.contains(.duplicate) { envelopes += envelopes }
        let replayKinds = (modes.contains(.replayPrior) ? ["application"] : []) + (modes.contains(.replayCommit) ? ["commit"] : [])
        if !replayKinds.isEmpty {
            let top = (envelopes.map(\.seq).max() ?? after) + 1
            envelopes += seen.filter { replayKinds.contains($0.kind) }.enumerated().map { index, old in
                var e = old; e.seq = top + UInt64(index); return e
            }
        }
        if modes.contains(.reorder) { envelopes.reverse() }
        seen += fresh
        return envelopes
    }

    func ack(_ c: Data, credential: Data, through: UInt64) async throws {
        if modes.contains(.ackFails) { throw URLError(.timedOut) }
        try await inner.ack(c, credential: credential, through: through)
    }

    func retire(_ c: Data, credential: Data) async throws { try await inner.retire(c, credential: credential) }
}

/// One installation: its own Keychain namespace, state directory, engine,
/// transport port, worker and UI store. Relaunch rebuilds everything from disk.
@MainActor
final class Endpoint {
    let service: String
    let directory: URL
    let api: any RelayAPI
    let clock: TestClock
    let engine: MLSCryptoEngine
    let port = RelayPort()
    let worker: TransportWorker
    let transport: LiveTransport
    let store: WatchlinkStore

    init(service: String, directory: URL, api: any RelayAPI, clock: TestClock) {
        self.service = service
        self.directory = directory
        self.api = api
        self.clock = clock
        engine = MLSCryptoEngine(service: service, directory: directory, transport: port, clock: { clock.now })
        worker = TransportWorker(engine: engine, api: api, port: port,
                                 memberships: MembershipStore(service: service + ".transport"))
        transport = LiveTransport(worker: worker)
        transport.kicks = false  // deterministic: tests run every delivery round explicitly
        store = WatchlinkStore(engine: engine)
        store.hooks = transport
        transport.store = store
    }

    func relaunch(api: (any RelayAPI)? = nil) -> Endpoint {
        Endpoint(service: service, directory: directory, api: api ?? self.api, clock: clock)
    }

    var device: Device { engine.device! }
    var received: [String] { store.messages.filter { !$0.isMine }.map(\.text) }

    func anchor() throws -> StateAnchor { try KeychainStateAnchorStore(service: service, account: "anchor").load() }
    func stateFile() throws -> Data { try Data(contentsOf: directory.appendingPathComponent("state.aead")) }

    func cleanup() {
        KeychainItem.delete(service: service, account: "anchor")
        KeychainItem.delete(service: service + ".identity", account: "identity")
        KeychainItem.delete(service: service + ".transport", account: "memberships")
    }
}
