import Foundation
import MLSBridge
@testable import MLSQualification
import XCTest

/// M1.4A lifecycle qualification through the generated Swift bindings.
final class LifecycleTests: XCTestCase {
    func testP1ForeignKeyPackageStorageCrossesRustToSwift() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let a = try h.device("alice", relay)
        var b = try h.device("bob", relay)
        let responderCode = try b.scanInitiator(a.startPairing())
        XCTAssertEqual(b.store.callbackLog.filter { $0 == "kp.insert" }.count, 1, "insert: Rust -> Swift")
        let stored = try XCTUnwrap(b.document.keyPackages.values.first).data
        let conversation = try XCTUnwrap(b.document.conversation)
        let published = try XCTUnwrap(relay.fetch(conversation, recipient: "alice", after: 0).first).data
        XCTAssertGreaterThan(stored.count, published.count, "opaque blob carries private material")
        try a.scanResponder(responderCode)
        _ = try a.addPeer()

        b = try h.reopen(b)  // process restart between KeyPackage publish and Welcome
        let welcome = try h.welcome(for: b)
        try b.acceptWelcome(welcome)
        XCTAssertTrue(b.store.callbackLog.contains("kp.get"), "get: Rust -> Swift")
        XCTAssertTrue(b.store.callbackLog.contains("kp.delete"), "delete: Rust -> Swift")
        XCTAssertTrue(b.document.keyPackages.isEmpty)
        XCTAssertEqual(b.document.lifecycle, .established)

        try a.send(Data("p1 probe".utf8))
        XCTAssertEqual(try b.sync(), [Data("p1 probe".utf8)])
        XCTAssertGreaterThanOrEqual(b.store.callbackLog.filter { $0 == "kp.delete" }.count, 2,
                                    "pinned core re-deletes; duplicate delete is harmless")
        XCTAssertThrowsError(try b.client!.joinGroup(ratchetTree: nil,
                                                     welcomeMessage: Message.fromBytes(bytes: welcome.data)),
                             "consumed KeyPackage cannot join again even bypassing policy")
    }

    func testP2ReadOnlyAccessors() throws {
        let h = try Harness(); defer { h.cleanup() }
        let (a, _) = try h.pair(Relay())
        let group = try XCTUnwrap(a.group)
        let roster = group.roster()
        XCTAssertEqual(roster.count, 2)
        XCTAssertTrue(roster.allSatisfy { $0.signaturePublicKey().count == 32 })
        XCTAssertEqual(Set(roster.compactMap { $0.basicIdentifier() }), [Data("alice".utf8), Data("bob".utf8)])
        XCTAssertEqual(group.currentEpoch(), 1)
        let solo = try a.client!.createGroup(groupId: randomID())
        XCTAssertEqual(solo.currentEpoch(), 0)
        XCTAssertEqual(solo.roster().count, 1)

        let keypair = try generateSignatureKeypair(cipherSuite: .curve25519Aes128)
        let carol = Client(id: Data("carol".utf8), signatureKeypair: keypair,
                           clientConfig: ClientConfig(groupStateStorage: MemoryGroupStorage(), useRatchetTreeExtension: true))
        let keyPackage = try carol.generateKeyPackageMessage()
        let identity = try XCTUnwrap(keyPackage.keyPackageSigningIdentity())
        XCTAssertEqual(try memberPin(identity),
                       identityPin(credentialId: Data("carol".utf8), signaturePublicKey: keypair.publicKey.bytes))
        XCTAssertNil(try Message.fromBytes(bytes: a.send(Data("x".utf8))).keyPackageSigningIdentity())
    }

    func testKeyPackageLifecycleRules() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let a = try h.device("alice", relay)
        let b = try h.device("bob", relay)
        try a.scanResponder(b.scanInitiator(a.startPairing()))
        _ = try a.addPeer()
        let welcome = try h.welcome(for: b)

        let one = try h.clone(b, relay: relay)
        try one.store.begin()
        XCTAssertThrowsError(try one.client!.generateKeyPackageMessage(), "exactly one outstanding KeyPackage")
        XCTAssertTrue(one.store.callbackFailed)

        let before = try h.versions(b)
        h.now += keyPackageTTL + 1
        XCTAssertThrows(Rejected.self, try b.acceptWelcome(welcome))
        XCTAssertTrue(try h.versions(b) == before, "expired package: rejected before durable change")
        XCTAssertEqual(b.document.lifecycle, .joinPending)
        try b.abortPairing()
        XCTAssertTrue(b.document.keyPackages.isEmpty, "abort deletes the package")

        h.now -= keyPackageTTL + 1
        let b2 = try h.device("bob", relay)
        let a2 = try h.device("alice", relay)
        _ = try b2.scanInitiator(a2.startPairing())
        let foreign = try h.rawClient("alice").createGroup(groupId: b2.document.conversation!)
            .addMembers(keyPackages: [h.rawClient("bob").generateKeyPackageMessage()])
        let unchanged = try h.versions(b2)
        XCTAssertThrows(Rejected.self, try b2.acceptWelcome(Envelope(
            conversation: b2.document.conversation!, seq: 99, kind: "welcome", base: nil,
            data: foreign.welcomeMessage!.toBytes(), sender: "alice")))
        XCTAssertTrue(try h.versions(b2) == unchanged, "unknown package: no durable change")
    }

    func testJoinFailureWindowsFailClosed() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let a = try h.device("alice", relay)
        let b = try h.device("bob", relay)
        try a.scanResponder(b.scanInitiator(a.startPairing()))
        _ = try a.addPeer()
        let welcome = try h.welcome(for: b)

        let deleteError = try h.clone(b, relay: relay)
        let committed = try h.versions(deleteError).committed
        deleteError.store.faults.failAt = "kp-delete"
        XCTAssertThrows(Closed.self, try deleteError.acceptWelcome(welcome))
        XCTAssertTrue(try h.versions(deleteError) == (committed, committed + 1), "group write ok + delete error")
        XCTAssertThrows(Closed.self, try h.reopen(deleteError))

        for point in ["reserved", "group-written", "kp-delete", "sealed", "replaced", "anchored"] {
            let crashed = try h.clone(b, relay: relay)
            crashed.store.faults.crashAt = point
            XCTAssertThrows(SimulatedCrash.self, try crashed.acceptWelcome(welcome))
            if point == "anchored" {
                let restored = try h.reopen(crashed)
                XCTAssertEqual(restored.document.lifecycle, .established, point)
                XCTAssertTrue(restored.document.keyPackages.isEmpty, point)
            } else {
                XCTAssertThrows(Closed.self, try h.reopen(crashed))
                XCTAssertEqual(try h.versions(crashed).committed, committed, "no durable partial join at \(point)")
            }
        }
        // Explicit recovery from the abandoned marker: wipe and re-pair.
        deleteError.wipe()
        let (fresh, _) = try h.pair(relay)
        XCTAssertEqual(fresh.document.lifecycle, .established)
    }

    func testCrashReconstructionForCommit() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let (a, _) = try h.pair(relay)
        for point in ["reserved", "group-written", "sealed", "replaced", "anchored"] {
            let caseRelay = relay.copy()
            let device = try h.clone(a, relay: caseRelay)
            let committed = try h.versions(device).committed
            device.store.faults.crashAt = point
            XCTAssertThrows(SimulatedCrash.self, try device.update())
            if point == "anchored" {
                let restored = try h.reopen(device)
                let persisted = try XCTUnwrap(restored.document.outbound.first { $0.kind == "commit" }).data
                guard case .accepted(let seq) = try restored.sendPending() else { return XCTFail("resend") }
                XCTAssertEqual(caseRelay.entry(restored.document.conversation!, seq: seq).data, persisted)
            } else {
                XCTAssertThrows(Closed.self, try h.reopen(device))
                XCTAssertEqual(try h.versions(device).committed, committed, point)
            }
        }
    }

    func testPendingCommitResendIsByteIdentical() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let (a, b) = try h.pair(relay)
        relay.offline = true
        XCTAssertThrows(RelayUnavailable.self, try a.update())
        let persisted = try XCTUnwrap(a.document.outbound.first { $0.kind == "commit" }).data
        XCTAssertThrows(Rejected.self, try a.send(Data("blocked".utf8)))

        let missing = try h.clone(a, relay: relay)
        try missing.store.begin()
        try missing.store.stage { $0.outbound = [] }  // a bug losing the queue, validly re-sealed
        try missing.store.commit()
        XCTAssertThrows(Violation.self, try h.reopen(missing))
        XCTAssertEqual(try h.reopen(missing).document.security, .halted, "HARD STOP persisted")

        let restarted = try h.reopen(a)  // all live objects destroyed and recreated
        XCTAssertEqual(try XCTUnwrap(restarted.document.outbound.first { $0.kind == "commit" }).data, persisted)
        relay.offline = false
        guard case .accepted(let seq) = try restarted.sendPending() else { return XCTFail("not accepted") }
        let conversation = restarted.document.conversation!
        XCTAssertEqual(relay.entry(conversation, seq: seq).data, persisted, "byte-identical resend")
        XCTAssertEqual(try relay.post(conversation, kind: "commit", base: 1, data: persisted, sender: "alice"),
                       .accepted(seq), "idempotent retransmission")
        _ = try b.sync()
        XCTAssertEqual(b.group!.currentEpoch(), restarted.group!.currentEpoch())
    }

    func testConcurrentCommitsConverge() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let (a, b) = try h.pair(relay)
        let conversation = a.document.conversation!
        let epoch = a.group!.currentEpoch()
        guard case .accepted = try a.update() else { return XCTFail("winner") }
        let visible = relay.fetch(conversation, recipient: "alice", after: 0).count
        guard case .stale = try b.update() else { return XCTFail("loser must be STALE") }
        XCTAssertEqual(b.group!.currentEpoch(), epoch + 1)
        XCTAssertNil(b.document.pendingCommit, "mls-rs cleared the losing pending commit")
        XCTAssertEqual(relay.fetch(conversation, recipient: "alice", after: 0).count, visible, "no fork")
        guard case .accepted = try b.update() else { return XCTFail("fresh update from N+1") }
        _ = try a.sync()
        try a.send(Data("converged".utf8))
        XCTAssertEqual(try b.sync(), [Data("converged".utf8)])
        XCTAssertEqual(a.group!.currentEpoch(), epoch + 2)
        XCTAssertEqual(b.group!.currentEpoch(), epoch + 2)

        let duplicate = relay.fetch(conversation, recipient: "bob", after: 0).last!
        let before = try h.versions(b)
        XCTAssertNil(try b.receive(duplicate), "duplicate sequence delivery ignored")
        XCTAssertTrue(try h.versions(b) == before)
    }

    func testRelaySequencerRulesAndLies() throws {
        let h = try Harness(); defer { h.cleanup() }
        let rules = Relay()
        let id = randomID()
        XCTAssertEqual(try rules.post(id, kind: "commit", base: 0, data: Data("x".utf8), sender: "a"), .accepted(1))
        XCTAssertEqual(try rules.post(id, kind: "commit", base: 0, data: Data("x".utf8), sender: "a"), .accepted(1))
        XCTAssertEqual(try rules.post(id, kind: "commit", base: 0, data: Data("y".utf8), sender: "b"), .stale(1))
        XCTAssertEqual(try rules.post(id, kind: "commit", base: 5, data: Data("z".utf8), sender: "b"), .reject)
        rules.retire(id)
        XCTAssertEqual(try rules.post(id, kind: "commit", base: 1, data: Data("z".utf8), sender: "b"), .reject)

        let relay = Relay()
        let (a, b) = try h.pair(relay)
        _ = try a.update()
        var lie = relay.fetch(a.document.conversation!, recipient: "bob", after: b.document.lastSeq)
            .first { $0.kind == "commit" }!
        lie.base! += 1
        XCTAssertThrows(Violation.self, try b.receive(lie))
        XCTAssertEqual(try h.reopen(b).document.security, .halted, "relay lying about base_epoch")

        let relay2 = Relay()
        let (a2, b2) = try h.pair(relay2)
        _ = try a2.update()
        _ = try b2.sync()
        var replay = relay2.fetch(a2.document.conversation!, recipient: "bob", after: 0).last { $0.kind == "commit" }!
        replay.base = b2.group!.currentEpoch()
        replay.seq += 100
        XCTAssertThrows(Violation.self, try b2.receive(replay))
        XCTAssertEqual(try h.reopen(b2).document.security, .halted, "valid commit with wrong metadata")
    }

    func testEpochRetentionCurrentPlusOnePrior() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        var (a, b) = try h.pair(relay)
        let conversation = a.document.conversation!
        func held(_ plaintext: String) throws -> Data {  // durable encrypt, delayed delivery
            try a.transact {
                let wire = try a.group!.encryptApplicationMessage(message: Data(plaintext.utf8)).toBytes()
                try a.group!.writeToStorage()
                return wire
            }
        }

        let fromPrior = try held("from n-1")
        _ = try b.update()
        let n = b.group!.currentEpoch()
        let before = b.document.groups[conversation]!.epochs
        XCTAssertEqual(try b.receive(application(conversation, fromPrior, seq: 10_000)), Data("from n-1".utf8))
        let after = b.document.groups[conversation]!.epochs
        XCTAssertEqual(Set(after.keys), [n - 1])
        XCTAssertNotEqual(after, before, "delayed-message ratchet update persisted")
        XCTAssertThrows(Rejected.self, try h.reopen(b).receive(application(conversation, fromPrior, seq: 10_001)))

        let fromTwoBack = try held("from n-2")  // a is still at n-1
        b = try h.reopen(b)
        _ = try b.update()
        XCTAssertThrows(Rejected.self, try b.receive(application(conversation, fromTwoBack, seq: 10_002)))
        b = try h.reopen(b)
        XCTAssertThrows(Rejected.self, try b.receive(application(conversation, fromTwoBack, seq: 10_003)))
        let epochs = b.document.groups[conversation]!.epochs
        XCTAssertEqual(Set(epochs.keys), [b.group!.currentEpoch() - 1], "no record below n-1")
        let persisted = try JSONEncoder().encode(b.document)
        XCTAssertNil(persisted.range(of: Data(after[n - 1]!.base64EncodedString().utf8)), "trimmed secrets absent")

        a = try h.reopen(a)
        _ = try a.sync()
        let fresh = try held("n-1 again")
        _ = try b.update()
        XCTAssertEqual(try h.reopen(b).receive(application(conversation, fresh, seq: 10_004)),
                       Data("n-1 again".utf8), "policy preserved after restart")
    }

    func testRejectedInputReleasesReservationOnlyWhenReadOnly() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let (a, b) = try h.pair(relay)
        let conversation = a.document.conversation!
        let wire = try a.send(Data("real after garbage".utf8))
        let start = try h.versions(b)

        XCTAssertThrows(Rejected.self, try b.receive(application(conversation, Data("\u{0} not mls".utf8), seq: 1_000_000)))
        XCTAssertTrue(try h.versions(b) == start, "malformed input rejected before a transaction")
        var corrupt = wire
        corrupt[corrupt.index(before: corrupt.endIndex)] ^= 1
        XCTAssertThrows(Rejected.self, try b.receive(application(conversation, corrupt, seq: 1_000_001)))
        XCTAssertTrue(try h.versions(b) == start, "reservation released, stateVersion unchanged")
        XCTAssertNotNil(try h.reopen(b).group, "restart afterwards succeeds")
        for i in 0..<100 {
            XCTAssertThrows(Rejected.self, try b.receive(application(conversation, corrupt, seq: 1_000_002 + UInt64(i))))
        }
        XCTAssertTrue(try h.versions(b) == start)
        XCTAssertEqual(try b.sync(), [Data("real after garbage".utf8)], "100 invalid inputs did not brick it")

        let settled = try h.versions(b)
        let (x, _) = try h.pair(Relay())
        XCTAssertThrows(Rejected.self, try b.receive(application(conversation, x.send(Data("other".utf8)), seq: 2_000_000)))
        XCTAssertTrue(try h.versions(b) == settled, "wrong-group message leaves stateVersion unchanged")
        XCTAssertNil(try b.receive(application(conversation, wire, seq: 1)), "stale relay envelope ignored")
        XCTAssertTrue(try h.versions(b) == settled)

        XCTAssertThrows(Closed.self, try b.transact { () throws -> Void in
            try b.group!.writeToStorage()  // a mutation callback fires first
            throw Rejected(reason: "policy refusal after a mutation")
        })
        XCTAssertTrue(try h.versions(b) == (settled.committed, settled.committed + 1), "reservation NOT released")
        XCTAssertThrows(Closed.self, try h.reopen(b))
    }
}
