import CryptoKit
import XCTest
@testable import Vault_App

/// The pair key and its labels. Changing a label makes every stored blob unreadable,
/// so they are pinned here (AGENTS.md: never change the AAD strings).
final class PairCryptoTests: XCTestCase {
    override func tearDown() {
        PairCrypto.demoIdentities = [:]
    }

    private func sessions() throws -> (PairCrypto.Session, PairCrypto.Session) {
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
        PairCrypto.demoIdentities = ["a": a, "b": b]
        let keys = ["a": a.publicKey.rawRepresentation, "b": b.publicKey.rawRepresentation]
        return (try PairCrypto.session(pairID: "pair-1", myID: "a", partnerID: "b", publicKeys: keys),
                try PairCrypto.session(pairID: "pair-1", myID: "b", partnerID: "a", publicKeys: keys))
    }

    func testBothSidesDeriveTheSameKeyAndCode() throws {
        let (mine, theirs) = try sessions()
        XCTAssertEqual(mine.keyData, theirs.keyData)
        XCTAssertEqual(mine.safetyCode, theirs.safetyCode)
        XCTAssertEqual(mine.safetyCode.count, 7)

        let aad = mine.messageAAD(id: "m1", sender: "a")
        let sealed = try mine.seal(Data("merhaba".utf8), aad: aad)
        XCTAssertEqual(try theirs.open(sealed, aad: theirs.messageAAD(id: "m1", sender: "a")), Data("merhaba".utf8))
        // Moved to another message, sender or kind: refused.
        XCTAssertThrowsError(try theirs.open(sealed, aad: theirs.messageAAD(id: "m2", sender: "a")))
        XCTAssertThrowsError(try theirs.open(sealed, aad: theirs.messageAAD(id: "m1", sender: "b")))
        XCTAssertThrowsError(try theirs.open(sealed, aad: theirs.photoAAD(id: "m1", sender: "a")))
    }

    func testLabelsArePinned() throws {
        let session = PairCrypto.session(pairID: "P", myID: "a", keyData: Data(repeating: 7, count: 32))
        XCTAssertEqual(session.messageAAD(id: "i", sender: "s"), "wl1|msg|P|s|i")
        XCTAssertEqual(session.photoAAD(id: "i", sender: "s"), "wl1|photo|P|s|i")
        XCTAssertEqual(session.voiceAAD(id: "i", sender: "s"), "wl1|voice|P|s|i")
        XCTAssertEqual(session.profileAAD(of: "m"), "wl1|profile|P|m")
        XCTAssertEqual(session.presenceAAD(of: "m"), "wl1|presence|P|m")
        XCTAssertEqual(session.agendaAAD(of: "m"), "wl1|agenda|P|m")
        XCTAssertEqual(session.timetableAAD(of: "m"), "wl1|timetable|P|m")
    }
}

@MainActor
final class MailDigestTests: XCTestCase {
    func testListSplitsImportantFromOther() throws {
        let json = """
        {"items":[{"onem":"normal","baslik":"Kütüphane saatleri","detay":null,"yapilacak":null,"sonTarih":null,"kaynak":null},
                  {"onem":"yuksek","baslik":"EE 303 vize salonu B201 oldu","detay":null,"yapilacak":"Salona git",
                   "sonTarih":"Pazartesi 10:00","kaynak":"EE 303"}],"atlanan":6}
        """
        let digest = try JSONDecoder().decode(MailDigest.self, from: Data(json.utf8))
        XCTAssertEqual(digest.important.map(\.baslik), ["EE 303 vize salonu B201 oldu"])
        XCTAssertEqual(digest.other.count, 1)
        XCTAssertEqual(digest.atlanan, 6)
        // Sharing sends only the important ones when there are any.
        XCTAssertTrue(digest.shareText.contains("EE 303: EE 303 vize salonu B201 oldu (Pazartesi 10:00)"))
        XCTAssertFalse(digest.shareText.contains("Kütüphane"))
    }

    func testOlderSingleSummaryStillOpens() throws {
        let json = #"{"ozet":"EE101 laboratuvarı Cuma 14.00’e alındı.","yapilacak":null,"sonTarih":"Perşembe 18.00"}"#
        let digest = try JSONDecoder().decode(MailDigest.self, from: Data(json.utf8))
        XCTAssertEqual(digest.items.count, 1)
        XCTAssertEqual(digest.items.first?.sonTarih, "Perşembe 18.00")
    }

    func testDemoEnvelopeOpens() throws {
        // The published test vector: P-256 + HKDF + AES-GCM, as the relay seals it.
        XCTAssertFalse(try MailDigestClient.demoDraft().items.isEmpty)
    }
}
