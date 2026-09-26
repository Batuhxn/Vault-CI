import CryptoKit
import Foundation
import MLSBridge

let suite = CipherSuite.curve25519Aes128

/// One Watchlink device in the M1.4 lifecycle + peer-trust model.
/// Mirrors m14_lifecycle.py; synthetic identities and messages only.
public final class Device {
    public let name: String
    public let service: String
    public let directory: URL
    public let relay: Relay
    public let store: QualificationStore
    public private(set) var client: Client?
    public internal(set) var group: Group?
    public private(set) var ownPin = Data()
    private var credentialId = Data()

    public var document: StateDocument { store.view }
    var identityService: String { service + ".identity" }

    public init(name: String, service: String, directory: URL, relay: Relay, clock: @escaping () -> Int64) {
        self.name = name
        self.service = service
        self.directory = directory
        self.relay = relay
        store = QualificationStore(service: service, fileURL: directory.appendingPathComponent("state.aead"), clock: clock)
    }

    // MARK: setup, open, wipe

    public static func setup(name: String, service: String, directory: URL, relay: Relay,
                             clock: @escaping () -> Int64) throws -> Device {
        let device = Device(name: name, service: service, directory: directory, relay: relay, clock: clock)
        let keypair = try generateSignatureKeypair(cipherSuite: suite)
        let item = IdentityItem(credentialId: Data(name.utf8), publicKey: keypair.publicKey.bytes,
                                secretKey: keypair.secretKey.bytes)
        try KeychainItem.add(service: device.identityService, account: "identity", data: JSONEncoder().encode(item))
        try device.store.create()
        try device.open()
        return device
    }

    public func open() throws {
        group = nil
        client = nil
        let keypair: SignatureKeypair
        do {
            let item = try JSONDecoder().decode(
                IdentityItem.self, from: KeychainItem.read(service: identityService, account: "identity"))
            keypair = SignatureKeypair(cipherSuite: suite, publicKey: SignaturePublicKey(bytes: item.publicKey),
                                       secretKey: SignatureSecretKey(bytes: item.secretKey))
            guard try validateSignatureKeypair(keypair: keypair) else { throw Closed(reason: "identity mismatch") }
            credentialId = item.credentialId
        } catch {
            throw Closed(reason: "local identity unavailable")
        }
        ownPin = identityPin(credentialId: credentialId, signaturePublicKey: keypair.publicKey.bytes)
        try store.load()
        client = Client(id: credentialId, signatureKeypair: keypair, clientConfig: ClientConfig(
            groupStateStorage: GroupCallbacks(store), useRatchetTreeExtension: true,
            keyPackageStorage: KeyPackageCallbacks(store)))
        let document = store.committed
        guard document.security == .ok else { return }
        if document.pendingCommit != nil, !document.outbound.contains(where: { $0.kind == "commit" }) {
            try halt(Violation(security: .halted, reason: "pending commit without its outbound bytes"))
        }
        try reload()
        if document.lifecycle == .established, let group {
            do {  // F1: the Keychain identity must be the restored group's own leaf.
                try checkRoster(group, established: true, security: .halted)
            } catch let violation as Violation {
                try halt(violation)
            }
        }
    }

    /// Explicit wipe: anchor first (crypto-shred), then identity, then state.
    public func wipe() {
        KeychainItem.delete(service: service, account: "anchor")
        KeychainItem.delete(service: identityService, account: "identity")
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("state.aead"))
        group = nil
        client = nil
    }

    // MARK: transactions

    func require(_ lifecycles: Lifecycle...) throws {
        let document = store.committed
        guard document.security == .ok else {
            throw Violation(security: document.security, reason: "blocked")
        }
        guard lifecycles.isEmpty || lifecycles.contains(document.lifecycle) else {
            throw Rejected(reason: "operation not allowed in \(document.lifecycle)")
        }
    }

    func reload() throws {
        group = nil
        let document = store.committed
        if let conversation = document.conversation, !document.groups.isEmpty, let client {
            group = try client.loadGroup(groupId: conversation)
        }
    }

    @discardableResult
    func transact<T>(_ operation: () throws -> T) throws -> T {
        try store.begin()
        let result: T
        do {
            result = try operation()
        } catch {
            if store.faults.crashed { throw error }  // process death: no cleanup runs
            guard !(error is Closed), store.releasable() else {
                store.abandon()  // keep the fail-closed marker
                group = nil
                client = nil
                throw Closed(reason: "operation not provably read-only; session closed")
            }
            try store.release()
            try reload()  // rebuild MLS objects from unchanged durable state
            if let violation = error as? Violation { try halt(violation) }
            throw Rejected(reason: String(describing: error))
        }
        do {
            try store.commit()
        } catch {
            if store.faults.crashed { throw error }
            store.abandon()
            group = nil
            client = nil
            throw error
        }
        return result
    }

    func halt(_ violation: Violation) throws -> Never {
        group = nil
        try store.begin()
        try store.stage { $0.security = violation.security }
        try store.commit()
        throw violation
    }

    public func checkRoster(_ group: Group, established: Bool,
                            security: SecurityState = .identityChanged) throws {
        let pins = try group.roster().map(memberPin)
        if established {
            guard let peer = document.peerPin, peer != ownPin, pins.count == 2,
                  Set(pins) == [ownPin, peer] else {
                throw Violation(security: security, reason: "roster is not exactly {own, pinned peer}")
            }
        } else if pins != [ownPin] {
            throw Violation(security: security, reason: "roster before peer join is not exactly {own}")
        }
    }

    func liveClient() throws -> Client {
        guard let client else { throw Closed(reason: "session closed") }
        return client
    }

    func liveGroup() throws -> Group {
        guard let group else { throw Closed(reason: "no live group") }
        return group
    }

    // MARK: pairing

    public func startPairing() throws -> Data {
        try require(.unpaired)
        let conversation = randomID(), nonce = randomID()
        let expires = store.clock() + qrTTL
        try transact {
            try store.stage { document in
                document.lifecycle = .offered
                document.conversation = conversation
                document.ownNonce = nonce
                document.qrExpires = expires
                document.consumedNonces.append(nonce)
            }
        }
        return try makeQR(conversation: conversation, nonce: nonce, pin: ownPin, expires: expires)
    }

    public func scanInitiator(_ qr: Data) throws -> Data {
        try require(.unpaired)
        let code = try parseQR(qr, now: store.clock(), consumed: document.consumedNonces)
        let ownNonce = randomID()
        let expires = store.clock() + qrTTL
        try transact {
            try store.stage { document in
                document.lifecycle = .joinPending
                document.conversation = code.cid
                document.peerPin = code.pin
                document.ownNonce = ownNonce
                document.qrExpires = expires
                document.consumedNonces += [code.nonce, ownNonce]
            }
            let keyPackage = try liveClient().generateKeyPackageMessage().toBytes()
            guard document.keyPackages.count == 1 else { throw Closed(reason: "key package not persisted") }
            try store.stage { $0.outbound = [Outbound(kind: "keypackage", base: nil, data: keyPackage)] }
        }
        try releaseOutbound()  // published only after it is durable
        return try makeQR(conversation: code.cid, nonce: ownNonce, pin: ownPin, expires: expires)
    }

    public func scanResponder(_ qr: Data) throws {
        try require(.offered)
        let code = try parseQR(qr, now: store.clock(), consumed: document.consumedNonces)
        guard code.cid == document.conversation, let expires = document.qrExpires, expires > store.clock() else {
            throw Rejected(reason: "pairing code is for another or expired conversation")
        }
        try transact {
            try store.stage { document in
                document.lifecycle = .pinned
                document.peerPin = code.pin
                document.qrExpires = nil
                document.consumedNonces.append(code.nonce)
            }
        }
    }

    public func abortPairing() throws {
        try require(.offered, .joinPending, .pinned)
        try transact {
            try store.stage { document in
                document.lifecycle = .unpaired
                document.conversation = nil
                document.peerPin = nil
                document.ownNonce = nil
                document.qrExpires = nil
                document.outbound = []
                document.keyPackages = [:]
            }
        }
    }

    // MARK: establishment

    public func addPeer() throws -> RelayStatus {
        try require(.pinned)
        guard let conversation = document.conversation, let peerPin = document.peerPin else {
            throw Rejected(reason: "not pinned")
        }
        let packages = relay.fetch(conversation, recipient: name, after: 0).filter { $0.kind == "keypackage" }
        guard packages.count == 1 else { throw Rejected(reason: "expected exactly one peer key package") }
        let keyPackage: Message
        do { keyPackage = try Message.fromBytes(bytes: packages[0].data) } catch {
            throw Rejected(reason: "malformed key package")
        }
        guard let identity = keyPackage.keyPackageSigningIdentity() else { throw Rejected(reason: "not a key package") }
        guard try memberPin(identity) == peerPin else {
            try halt(Violation(security: .identityChanged, reason: "key package does not match the pinned peer"))
        }
        try transact {
            let group = try liveClient().createGroup(groupId: conversation)
            try checkRoster(group, established: false)
            let output = try group.addMembers(keyPackages: [keyPackage])
            try group.writeToStorage()
            let commit = try output.commitMessage.toBytes()
            guard let welcome = try output.welcomeMessage?.toBytes() else { throw Closed(reason: "no welcome") }
            try store.stage { document in
                document.lifecycle = .creating
                document.lastSeq = packages[0].seq
                document.pendingCommit = PendingCommit(base: 0, commitId: Data(SHA256.hash(data: commit)))
                document.outbound = [Outbound(kind: "commit", base: 0, data: commit),
                                     Outbound(kind: "welcome", base: nil, data: welcome)]
            }
            self.group = group
        }
        return try sendPending()
    }

    public func acceptWelcome(_ envelope: Envelope) throws {
        try require(.joinPending)
        guard envelope.kind == "welcome", envelope.conversation == document.conversation else {
            throw Rejected(reason: "welcome for another conversation")
        }
        let welcome: Message
        do { welcome = try Message.fromBytes(bytes: envelope.data) } catch {
            throw Rejected(reason: "malformed welcome")
        }
        try transact {
            let group = try liveClient().joinGroup(ratchetTree: nil, welcomeMessage: welcome).group
            try checkRoster(group, established: true)
            try group.writeToStorage()  // also deletes the consumed key package (P1)
            guard document.keyPackages.isEmpty, group.currentEpoch() >= 1 else {
                throw Closed(reason: "consumed key package still present")
            }
            try store.stage { document in
                document.lifecycle = .established
                document.outbound = []
                document.lastSeq = envelope.seq
            }
            self.group = group
        }
    }

    // MARK: commits

    public func update() throws -> RelayStatus {
        try require(.established)
        guard document.pendingCommit == nil else { throw Rejected(reason: "a commit is already unresolved") }
        try transact {
            let group = try liveGroup()
            let base = group.currentEpoch()
            let commit = try group.commit().commitMessage.toBytes()
            try group.writeToStorage()
            try store.stage { document in
                document.pendingCommit = PendingCommit(base: base, commitId: Data(SHA256.hash(data: commit)))
                document.outbound = [Outbound(kind: "commit", base: base, data: commit)]
            }
        }
        return try sendPending()
    }

    /// (Re)sends the exact persisted commit bytes and resolves the relay decision.
    public func sendPending() throws -> RelayStatus {
        guard let pending = document.pendingCommit, let conversation = document.conversation,
              let commit = document.outbound.first(where: { $0.kind == "commit" }), let base = commit.base else {
            throw Rejected(reason: "no pending commit")
        }
        guard Data(SHA256.hash(data: commit.data)) == pending.commitId else {
            try halt(Violation(security: .halted, reason: "outbound bytes do not match the pending commit"))
        }
        let status = try relay.post(conversation, kind: "commit", base: base, data: commit.data, sender: name)
        switch status {
        case .accepted(let seq):
            try applyCommit(Envelope(conversation: conversation, seq: seq, kind: "commit", base: base,
                                     data: commit.data, sender: name))
            try releaseOutbound()
        case .stale(let seq):
            try applyCommit(relay.entry(conversation, seq: seq))
        case .reject, .ok:
            throw Rejected(reason: "relay rejected the commit")
        }
        return status
    }

    /// Processes a relay-accepted commit. Metadata is checked, never trusted.
    func applyCommit(_ envelope: Envelope) throws {
        try require(.creating, .established)
        let group = try liveGroup()
        guard let base = envelope.base, group.currentEpoch() == base else {
            try halt(Violation(security: .halted, reason: "accepted commit base does not match local epoch"))
        }
        guard let message = try? Message.fromBytes(bytes: envelope.data) else {
            try halt(Violation(security: .halted, reason: "accepted commit is malformed"))
        }
        try transact {
            let result: ReceivedMessage
            do {
                result = try group.processIncomingMessage(message: message)
            } catch {
                if store.callbackFailed || store.faults.crashed { throw error }
                throw Violation(security: .halted, reason: "accepted commit failed MLS processing")
            }
            guard case .commit = result, group.currentEpoch() == base + 1 else {
                throw Violation(security: .halted, reason: "accepted commit did not advance exactly one epoch")
            }
            try checkRoster(group, established: true)
            try group.writeToStorage()
            try store.stage { document in
                document.lifecycle = .established
                document.pendingCommit = nil
                document.lastSeq = max(document.lastSeq, envelope.seq)
                document.outbound.removeAll { $0.kind == "commit" }
            }
        }
    }

    /// Publishes persisted non-commit outbound bytes, then drops them.
    func releaseOutbound() throws {
        guard let conversation = document.conversation else { return }
        let pending = document.outbound.filter { $0.kind != "commit" }
        guard !pending.isEmpty else { return }
        for item in pending {
            _ = try relay.post(conversation, kind: item.kind, base: item.base, data: item.data, sender: name)
        }
        try transact {
            try store.stage { $0.outbound.removeAll { $0.kind != "commit" } }
        }
    }

    // MARK: application messages

    @discardableResult
    public func send(_ plaintext: Data) throws -> Data {
        try require(.established)
        guard document.pendingCommit == nil else {
            throw Rejected(reason: "no application messages while a commit is unresolved")
        }
        let wire = try transact {
            let group = try liveGroup()
            let wire = try group.encryptApplicationMessage(message: plaintext).toBytes()
            try group.writeToStorage()
            return wire
        }
        _ = try relay.post(document.conversation!, kind: "application", base: group?.currentEpoch(),
                           data: wire, sender: name)
        return wire
    }

    public func receive(_ envelope: Envelope) throws -> Data? {
        try require(.established)
        guard envelope.conversation == document.conversation else {
            throw Rejected(reason: "envelope for another conversation")
        }
        guard envelope.seq > document.lastSeq else { return nil }  // duplicate delivery
        if envelope.kind == "commit" {
            guard document.pendingCommit == nil else {
                throw Rejected(reason: "resolve the local pending commit through the relay first")
            }
            try applyCommit(envelope)
            return nil
        }
        guard envelope.kind == "application" else { throw Rejected(reason: "unexpected envelope kind") }
        let message: Message
        do { message = try Message.fromBytes(bytes: envelope.data) } catch {
            throw Rejected(reason: "malformed MLS message")  // before any transaction
        }
        return try transact {
            let group = try liveGroup()
            guard case .applicationMessage(let sender, let data) = try group.processIncomingMessage(message: message)
            else { throw Rejected(reason: "not an application message") }
            guard try memberPin(sender) == document.peerPin else {
                throw Violation(security: .identityChanged, reason: "application sender is not the pinned peer")
            }
            try group.writeToStorage()  // persists prior-epoch secret updates too
            try store.stage { $0.lastSeq = envelope.seq }
            return data
        }
    }

    /// Delivers everything new from the relay, in relay order.
    public func sync() throws -> [Data?] {
        try require(.established)
        guard let conversation = document.conversation else { return [] }
        return try relay.fetch(conversation, recipient: name, after: document.lastSeq)
            .filter { $0.kind != "keypackage" && $0.kind != "welcome" }
            .map { try receive($0) }
    }
}

func randomID() -> Data {
    Data((0..<idBytes).map { _ in UInt8.random(in: 0...255) })
}
