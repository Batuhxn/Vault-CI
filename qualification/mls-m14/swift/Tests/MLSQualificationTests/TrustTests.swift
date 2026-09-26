import Foundation
import MLSBridge
@testable import MLSQualification
import Security
import XCTest

/// M1.4B peer-trust qualification through the generated Swift bindings.
final class TrustTests: XCTestCase {
    func testIdentityPinVectorMatchesLinux() throws {
        let pin = identityPin(credentialId: Data("ab".utf8), signaturePublicKey: Data("c".utf8))
        XCTAssertEqual(pin.map { String(format: "%02x", $0) }.joined(),
                       "4946c970783db26ca4d11c19ee2525a4ea4b93375cbc5b9d61359963f3f4acad")
        XCTAssertNotEqual(pin, identityPin(credentialId: Data("a".utf8), signaturePublicKey: Data("bc".utf8)))

        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let a = try h.device("alice", relay)
        let b = try h.device("bob", relay)
        _ = try b.scanInitiator(a.startPairing())
        let keyPackage = try Message.fromBytes(bytes: relay.fetch(b.document.conversation!, recipient: "alice",
                                                                  after: 0)[0].data)
        XCTAssertEqual(try memberPin(XCTUnwrap(keyPackage.keyPackageSigningIdentity())), b.ownPin)
    }

    func testMutualQRRules() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let a = try h.device("alice", relay)
        let b = try h.device("bob", relay)
        let initiatorCode = try a.startPairing()
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: initiatorCode) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["v", "cid", "nonce", "pin", "exp"])
        let secret = try JSONDecoder().decode(IdentityItem.self,
                                              from: KeychainItem.read(service: a.identityService, account: "identity")).secretKey
        XCTAssertNil(initiatorCode.range(of: Data(secret.base64EncodedString().utf8)), "no secret key in QR")

        h.now += qrTTL
        XCTAssertThrows(Rejected.self, try b.scanInitiator(initiatorCode))
        h.now -= qrTTL
        let responderCode = try b.scanInitiator(initiatorCode)
        try b.abortPairing()
        XCTAssertThrows(Rejected.self, try b.scanInitiator(initiatorCode))  // nonce single-use

        let code = try JSONDecoder().decode(PairingCode.self, from: responderCode)
        let initiatorNonce = try JSONDecoder().decode(PairingCode.self, from: initiatorCode).nonce
        XCTAssertThrows(Rejected.self, try a.scanResponder(makeQR(conversation: randomID(), nonce: code.nonce,
                                                                 pin: code.pin, expires: code.exp)))
        XCTAssertThrows(Rejected.self, try a.scanResponder(makeQR(conversation: code.cid, nonce: initiatorNonce,
                                                                 pin: code.pin, expires: code.exp)))
        XCTAssertThrows(Rejected.self, try a.scanResponder(Data(#"{"v":2}"#.utf8)))
        XCTAssertThrows(Rejected.self, try a.addPeer(), "A may add B only after scanning QR_B")
    }

    func testMutualPairingAndRosterStates() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let (a, b) = try h.pair(relay)
        XCTAssertEqual(a.document.lifecycle, .established)
        XCTAssertEqual(b.document.lifecycle, .established)
        XCTAssertEqual(a.document.peerPin, b.ownPin)
        XCTAssertEqual(b.document.peerPin, a.ownPin)

        let solo = try a.client!.createGroup(groupId: randomID())
        XCTAssertNoThrow(try a.checkRoster(solo, established: false), "CREATING: roster == {own}")
        XCTAssertThrows(Violation.self, try a.checkRoster(solo, established: true))
        XCTAssertNoThrow(try a.checkRoster(a.group!, established: true), "ESTABLISHED: {own, peer}")
        XCTAssertThrows(Violation.self, try a.checkRoster(a.group!, established: false))

        try a.send(Data("pinned sender".utf8))
        XCTAssertEqual(try b.sync(), [Data("pinned sender".utf8)], "sender resolves to the pinned peer")
        XCTAssertNoThrow(try h.reopen(b), "restore repeats the full roster validation")
    }

    func testImpostorKeyPackageHardStopsAndStaysBlocked() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let a = try h.device("alice", relay)
        let b = try h.device("bob", relay)
        try a.scanResponder(b.scanInitiator(a.startPairing()))
        let conversation = a.document.conversation!
        let entry = relay.fetch(conversation, recipient: "alice", after: 0)[0]
        relay.substitute(conversation, seq: entry.seq,  // malicious relay: same BasicCredential, other key
                         data: try h.rawClient("bob").generateKeyPackageMessage().toBytes())
        XCTAssertThrows(Violation.self, try a.addPeer())
        XCTAssertEqual(a.document.security, .identityChanged)
        XCTAssertTrue(a.document.groups.isEmpty, "no group state before the pin check")

        XCTAssertThrows(Violation.self, try a.send(Data("x".utf8)))
        XCTAssertThrows(Violation.self, try a.update())
        XCTAssertThrows(Violation.self, try a.sync())
        XCTAssertThrows(Violation.self, try a.startPairing())
        let restarted = try h.reopen(a)
        XCTAssertNil(restarted.group)
        XCTAssertThrows(Violation.self, try restarted.send(Data("x".utf8)), "still blocked after restart; no re-pin")
    }

    func testThirdMemberInjectionHardStops() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let (a, b) = try h.pair(relay)
        let base = b.group!.currentEpoch()
        let injected = try b.group!.addMembers(keyPackages: [h.rawClient("carol").generateKeyPackageMessage()])
        _ = try relay.post(a.document.conversation!, kind: "commit", base: base,
                           data: injected.commitMessage.toBytes(), sender: "bob")
        XCTAssertThrows(Violation.self, try a.sync())
        XCTAssertEqual(try h.reopen(a).document.security, .identityChanged)
    }

    func testKeychainIdentityCrossCheckOnRestore() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let (a, _) = try h.pair(relay)

        let swapped = try h.clone(a, relay: relay)
        let other = try generateSignatureKeypair(cipherSuite: .curve25519Aes128)
        KeychainItem.delete(service: swapped.identityService, account: "identity")
        try KeychainItem.add(service: swapped.identityService, account: "identity", data: JSONEncoder().encode(
            IdentityItem(credentialId: Data("alice".utf8), publicKey: other.publicKey.bytes,
                         secretKey: other.secretKey.bytes)))
        XCTAssertThrows(Violation.self, try h.reopen(swapped), "F1: Keychain identity != restored own leaf")
        XCTAssertEqual(try h.reopen(swapped).document.security, .halted)

        let missing = try h.clone(a, relay: relay)
        KeychainItem.delete(service: missing.identityService, account: "identity")
        XCTAssertThrows(Closed.self, try h.reopen(missing), "missing identity: fail closed, nothing regenerated")
    }

    func testWipeLeftoverKeychainAndFreshRepair() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let (a, b) = try h.pair(relay)
        let oldConversation = a.document.conversation!
        let oldWelcome = try h.welcome(for: b)
        let oldWire = try a.send(Data("old conversation".utf8))

        let shredded = try h.clone(b, relay: relay)
        KeychainItem.delete(service: shredded.service, account: "anchor")  // wipe interrupted after anchor
        XCTAssertThrows(Closed.self, try h.reopen(shredded))

        let leftover = try h.clone(b, relay: relay)
        try FileManager.default.removeItem(at: leftover.directory.appendingPathComponent("state.aead"))
        XCTAssertThrows(Closed.self, try h.reopen(leftover), "leftover Keychain without state fails closed")
        XCTAssertNoThrow(try KeychainItem.read(service: leftover.service, account: "anchor"))

        a.wipe()
        b.wipe()
        XCTAssertThrows(Closed.self, try h.reopen(b))
        let (a2, b2) = try h.pair(relay)
        XCTAssertNotEqual(a2.document.conversation, oldConversation, "fresh conversation_id")
        relay.retire(oldConversation)
        XCTAssertThrows(Rejected.self, try b2.acceptWelcome(oldWelcome))
        XCTAssertThrows(Rejected.self, try b2.receive(application(oldConversation, oldWire, seq: 1_000_000)))
        XCTAssertEqual(try relay.post(oldConversation, kind: "application", base: 1, data: oldWire, sender: "alice"),
                       .reject, "retired conversation_id")
    }

    func testTamperedOrRolledBackStateRejected() throws {
        let h = try Harness(); defer { h.cleanup() }
        let relay = Relay()
        let (a, _) = try h.pair(relay)
        let device = try h.clone(a, relay: relay)
        let file = device.directory.appendingPathComponent("state.aead")
        let old = try Data(contentsOf: file)
        try device.send(Data("advance".utf8))

        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var combined = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["combined"] as? String)))
        combined[combined.index(before: combined.endIndex)] ^= 1
        envelope["combined"] = combined.base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: file, options: [.atomic, .completeFileProtection])
        XCTAssertThrows(Closed.self, try h.reopen(device), "tampered pin/state")
        try old.write(to: file, options: [.atomic, .completeFileProtection])
        XCTAssertThrows(Closed.self, try h.reopen(device), "rolled-back state")
    }

    func testKeychainItemsAreDeviceOnly() throws {
        let h = try Harness(); defer { h.cleanup() }
        let a = try h.device("alice", Relay())
        let expected = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        XCTAssertEqual(KeychainItem.accessibility(service: a.service, account: "anchor"), expected)
        XCTAssertEqual(KeychainItem.accessibility(service: a.identityService, account: "identity"), expected)
    }
}
