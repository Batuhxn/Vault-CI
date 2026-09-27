import CryptoKit
import Foundation
import Security
import WatchlinkMLS

// M1.7 transport. Durability never depends on the network: every outbound
// byte string is first committed (sealed + anchored) inside the qualified MLS
// state; the worker only transmits committed bytes, caches the relay's answer,
// and lets the qualified code consume that answer. Retries resend the exact
// committed bytes and never rebuild a cryptographic message.

enum RelayError: Error, Equatable {
    case http(Int)
    case malformedResponse

    /// Permanent answers the worker must not hammer.
    var isPermanent: Bool {
        if case .http(let code) = self { return [400, 401, 403, 404, 409, 410].contains(code) }
        return true
    }
}

/// The relay's HTTPS API. Credentials authenticate "may use this mailbox" only;
/// peer identity stays with MLS + the mutual QR pins.
protocol RelayAPI: AnyObject {
    func open(_ conversation: Data, credential: Data, claimVerifier: Data, claimExpires: Int64) async throws
    func claim(_ conversation: Data, credential: Data, claim: Data) async throws
    func post(_ conversation: Data, credential: Data, kind: String, base: UInt64?, data: Data) async throws -> RelayStatus
    func fetch(_ conversation: Data, credential: Data, after: UInt64) async throws -> [Envelope]
    func ack(_ conversation: Data, credential: Data, through: UInt64) async throws
    func retire(_ conversation: Data, credential: Data) async throws
}

final class HTTPRelayAPI: RelayAPI {
    private let base: URL
    private let session: URLSession

    init(base: URL) {
        self.base = base
        let configuration = URLSessionConfiguration.ephemeral  // no cookies, cache or credential storage
        configuration.timeoutIntervalForRequest = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    private struct Body: Encodable {
        var credential: Data?
        var claim: Data?
        var claimVerifier: String?
        var claimExpires: Int64?
        var kind: String?
        var base: UInt64?
        var data: Data?
        var through: UInt64?
    }

    private struct Answer: Decodable {
        var status: String?
        var seq: UInt64?
        var envelopes: [Item]?
        struct Item: Decodable { var seq: UInt64; var kind: String; var base: UInt64?; var data: Data }
    }

    private func request(_ conversation: Data, _ op: String, query: String = "", token: Data? = nil,
                         body: Body? = nil) async throws -> Answer {
        let path = "v1/c/\(conversation.base64URL)/\(op)\(query)"
        guard let url = URL(string: path, relativeTo: base) else { throw RelayError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token { request.setValue("Bearer \(token.base64EncodedString())", forHTTPHeaderField: "authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayError.malformedResponse }
        guard http.statusCode == 200 else { throw RelayError.http(http.statusCode) }
        do { return try JSONDecoder().decode(Answer.self, from: data) } catch { throw RelayError.malformedResponse }
    }

    func open(_ conversation: Data, credential: Data, claimVerifier: Data, claimExpires: Int64) async throws {
        _ = try await request(conversation, "open", body: Body(credential: credential,
            claimVerifier: claimVerifier.hex, claimExpires: claimExpires))
    }

    func claim(_ conversation: Data, credential: Data, claim: Data) async throws {
        _ = try await request(conversation, "claim", body: Body(credential: credential, claim: claim))
    }

    func post(_ conversation: Data, credential: Data, kind: String, base: UInt64?, data: Data) async throws -> RelayStatus {
        let answer = try await request(conversation, "envelopes", token: credential,
                                       body: Body(kind: kind, base: base, data: data))
        switch (answer.status, answer.seq) {
        case ("accepted", let seq?): return .accepted(seq)
        case ("stale", let seq?): return .stale(seq)
        case ("ok", let seq?): return .ok(seq)
        case ("reject", _): return .reject
        default: throw RelayError.malformedResponse
        }
    }

    func fetch(_ conversation: Data, credential: Data, after: UInt64) async throws -> [Envelope] {
        let answer = try await request(conversation, "envelopes", query: "?after=\(after)", token: credential)
        guard let items = answer.envelopes else { throw RelayError.malformedResponse }
        return items.map { Envelope(conversation: conversation, seq: $0.seq, kind: $0.kind, base: $0.base,
                                    data: $0.data, sender: RelayPort.peer) }
    }

    func ack(_ conversation: Data, credential: Data, through: UInt64) async throws {
        _ = try await request(conversation, "ack", token: credential, body: Body(through: through))
    }

    func retire(_ conversation: Data, credential: Data) async throws {
        _ = try await request(conversation, "retire", token: credential, body: Body())
    }
}

/// The synchronous RelaySequencer the qualified Device talks to. It answers
/// only from relay responses the worker already received; anything else is
/// "not delivered yet", which leaves the committed item in place for retry.
final class RelayPort: EnvelopeTransport {
    static let peer = "peer"
    private var answers: [Data: RelayStatus] = [:]  // SHA-256(bytes) -> relay answer
    private var inbox: [Envelope] = []
    /// Sequence numbers the engine rejected (no mutation); skipped, bounded by `trim`.
    var rejected: Set<UInt64> = []

    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    func record(_ status: RelayStatus, for data: Data) { answers[Self.digest(data)] = status }
    func answer(for data: Data) -> RelayStatus? { answers[Self.digest(data)] }

    func decisionSeq(for commit: Data) -> UInt64? {
        switch answer(for: commit) {
        case .accepted(let seq)?, .stale(let seq)?: return seq
        default: return nil
        }
    }

    func merge(_ envelopes: [Envelope]) {
        for envelope in envelopes where !inbox.contains(where: { $0.conversation == envelope.conversation
                                                                 && $0.seq == envelope.seq }) {
            inbox.append(envelope)
        }
        inbox.sort { $0.seq < $1.seq }
    }

    /// Drops everything the engine has consumed and answers no longer needed.
    func trim(through seq: UInt64, keeping pending: [Data]) {
        inbox.removeAll { $0.seq <= seq }
        rejected = rejected.filter { $0 > seq }
        let keep = Set(pending.map(Self.digest))
        answers = answers.filter { keep.contains($0.key) }
    }

    func reset() {
        answers = [:]
        inbox = []
        rejected = []
    }

    func post(_ conversation: Data, kind: String, base: UInt64?, data: Data, sender: String) throws -> RelayStatus {
        guard let status = answer(for: data) else { throw RelayUnavailable.deliveryFailed }
        return status
    }

    func entry(_ conversation: Data, seq: UInt64) throws -> Envelope {
        guard let envelope = inbox.first(where: { $0.conversation == conversation && $0.seq == seq }) else {
            throw RelayUnavailable.deliveryFailed
        }
        return envelope
    }

    func fetch(_ conversation: Data, recipient: String, after: UInt64) -> [Envelope] {
        inbox.filter { $0.conversation == conversation && $0.seq > after }
    }
}

/// Per-conversation transport credential. Never in the QR; the relay stores only its SHA-256.
struct Membership: Codable, Equatable {
    var conversation: Data
    var credential: Data
    var creator: Bool
    /// One-time slot-b capability (creator registers its hash, joiner presents it); dropped once registered.
    var claim: Data?
    var claimExpires: Int64?
    var registered = false
    var retiring = false
}

/// SHA-256("watchlink-relay-claim-v1" || conversation || QR nonce). A transport
/// capability only, exactly as short-lived and single-use as the creator's QR.
func relayClaim(conversation: Data, nonce: Data) -> Data {
    var input = Data("watchlink-relay-claim-v1".utf8)
    input.append(conversation)
    input.append(nonce)
    return Data(SHA256.hash(data: input))
}

/// Memberships live in one device-only Keychain item.
final class MembershipStore {
    private let service: String

    init(service: String) { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "memberships", kSecAttrSynchronizable as String: false]
    }

    func load() -> [Membership] {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return [] }
        return (try? JSONDecoder().decode([Membership].self, from: data)) ?? []
    }

    func save(_ memberships: [Membership]) throws {
        let data = try JSONEncoder().encode(memberships)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            attributes[kSecValueData as String] = data
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw TransportKeychainError(status: added) }
        } else if status != errSecSuccess {
            throw TransportKeychainError(status: status)
        }
    }

    /// Adopts the conversation named by a validated pairing code (no-op if known).
    func adopt(code: Data, creator: Bool) throws {
        let pairing = try JSONDecoder().decode(PairingCode.self, from: code)
        var memberships = load()
        guard !memberships.contains(where: { $0.conversation == pairing.cid }) else { return }
        var credential = Data(count: 32)
        let status = credential.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw TransportKeychainError(status: status) }
        memberships.append(Membership(conversation: pairing.cid, credential: credential, creator: creator,
                                      claim: relayClaim(conversation: pairing.cid, nonce: pairing.nonce),
                                      claimExpires: pairing.exp))
        try save(memberships)
    }

    func markRetiring(except conversation: Data?) throws {
        try save(load().map { var m = $0; if m.conversation != conversation { m.retiring = true }; return m })
    }
}

struct TransportKeychainError: Error { let status: OSStatus }

/// Foreground-only delivery loop. Correctness never depends on it staying alive:
/// everything it sends is already committed, so a kill at any point is resumed
/// by the next tick after relaunch.
@MainActor
final class TransportWorker {
    let engine: MLSCryptoEngine
    let api: any RelayAPI
    let port: RelayPort
    let memberships: MembershipStore
    /// Diagnostics (qualification builds): hold delivery to reproduce kill-before-ACK.
    var paused = false
    private(set) var lastError: RelayError?
    private(set) var lastSuccess: Date?
    private var running = false

    init(engine: MLSCryptoEngine, api: any RelayAPI, port: RelayPort, memberships: MembershipStore) {
        self.engine = engine
        self.api = api
        self.port = port
        self.memberships = memberships
    }

    /// One delivery round; returns authenticated plaintexts that became available.
    @discardableResult
    func tick() async -> [String] {
        guard !running, !paused else { return [] }
        running = true
        defer { running = false }
        await retireOld()
        guard let conversation = engine.device?.document.conversation,
              var membership = memberships.load().first(where: { $0.conversation == conversation && !$0.retiring })
        else { return [] }
        do {
            if !membership.registered {
                try await register(&membership)
            }
            try await deliver(conversation, membership.credential)
            let fetched = try await api.fetch(conversation, credential: membership.credential,
                                              after: engine.device?.document.lastSeq ?? 0)
            guard engine.device?.document.conversation == conversation else { return [] }  // reset meanwhile
            port.merge(fetched)
            var plaintexts = engine.pump(port)
            // A decided commit may have released more committed bytes (e.g. the Welcome).
            try await deliver(conversation, membership.credential)
            plaintexts += engine.pump(port)
            if let device = engine.device, device.document.lifecycle == .established {
                let through = device.document.lastSeq
                if through > 0 { try await api.ack(conversation, credential: membership.credential, through: through) }
                port.trim(through: through, keeping: device.store.committed.outbound.map(\.data))
            }
            lastError = nil
            lastSuccess = Date()
            return plaintexts
        } catch let error as RelayError {
            lastError = error
        } catch {
            lastError = .http(0)  // network unreachable/timeout: transient
        }
        return []
    }

    /// Transmits committed outbound bytes (commit first) that have no relay answer yet.
    private func deliver(_ conversation: Data, _ credential: Data) async throws {
        guard let committed = engine.device?.store.committed, committed.conversation == conversation else { return }
        // Qualified ordering: while a commit is unresolved only the commit itself
        // may leave; items committed with it (e.g. its Welcome) wait for the decision.
        let commits = committed.outbound.filter { $0.kind == "commit" }
        let ordered = committed.pendingCommit != nil ? commits : committed.outbound
        for item in ordered where port.answer(for: item.data) == nil {
            let status = try await api.post(conversation, credential: credential, kind: item.kind,
                                            base: item.base, data: item.data)
            port.record(status, for: item.data)
        }
    }

    private func register(_ membership: inout Membership) async throws {
        guard let claim = membership.claim else { throw RelayError.malformedResponse }
        if membership.creator {
            try await api.open(membership.conversation, credential: membership.credential,
                               claimVerifier: Data(SHA256.hash(data: claim)), claimExpires: membership.claimExpires ?? 0)
        } else {
            try await api.claim(membership.conversation, credential: membership.credential, claim: claim)
        }
        membership.registered = true
        membership.claim = nil
        membership.claimExpires = nil
        let registered = membership
        try memberships.save(memberships.load().map { $0.conversation == registered.conversation ? registered : $0 })
    }

    /// Best effort: tell the relay a reset conversation is retired, then forget its credential.
    private func retireOld() async {
        for old in memberships.load() where old.retiring {
            if old.registered {
                do {
                    try await api.retire(old.conversation, credential: old.credential)
                } catch let error as RelayError where error.isPermanent {
                    // Already gone or never completed: nothing left to retire.
                } catch {
                    continue  // offline: keep the credential and retry next tick
                }
            }
            try? memberships.save(memberships.load().filter { $0.conversation != old.conversation })
        }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Wires the worker to the UI store: the store gets plaintexts and status, never transport access.
@MainActor
final class LiveTransport: TransportHooks {
    let worker: TransportWorker
    weak var store: WatchlinkStore?

    init(worker: TransportWorker) { self.worker = worker }

    func adopt(code: Data, creator: Bool) throws { try worker.memberships.adopt(code: code, creator: creator) }
    func retireAll() throws { try worker.memberships.markRetiring(except: nil) }
    func kick() { Task { await round() } }

    func round() async {
        let plaintexts = await worker.tick()
        store?.connectionAvailable = worker.lastError == nil
        store?.ingest(plaintexts)
    }

    /// Foreground polling only; cancelled when the scene leaves the foreground.
    func run() async {
        while !Task.isCancelled {
            await round()
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// Production composition. Without a configured HTTPS relay the app has no
/// transport at all (fail closed), never a plaintext or local fallback.
@MainActor
enum WatchlinkComposition {
    static func make(bundle: Bundle = .main) -> (WatchlinkStore, LiveTransport?) {
        guard let value = bundle.object(forInfoDictionaryKey: "WatchlinkRelayURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else {
            return (WatchlinkStore(engine: MLSCryptoEngine()), nil)
        }
        let port = RelayPort()
        let engine = MLSCryptoEngine(transport: port)
        let worker = TransportWorker(engine: engine, api: HTTPRelayAPI(base: url), port: port,
                                     memberships: MembershipStore(service: "com.batuhxn.watchlink.transport"))
        #if WATCHLINK_QUALIFICATION
        worker.paused = DiagnosticsView.paused
        #endif
        let transport = LiveTransport(worker: worker)
        let store = WatchlinkStore(engine: engine)
        store.hooks = transport
        transport.store = store
        return (store, transport)
    }
}
