import CryptoKit
import Foundation
import Security

/// One mail (or a few on the same subject) as Gemini sorted it.
struct MailItem: Codable, Hashable {
    let onem: String
    let baslik: String
    let detay: String?
    let yapilacak: String?
    let sonTarih: String?
    let kaynak: String?

    var important: Bool { onem == "yuksek" }

    var shareText: String {
        var line = (kaynak.map { "\($0): " } ?? "") + baslik
        if let sonTarih { line += " (\(sonTarih))" }
        if let yapilacak { line += "\n  Yapılacak: \(yapilacak)" }
        return line
    }
}

/// The latest sorted digest: important items, the rest, and how many were skipped.
/// Also reads the first version (a single summary) as one item.
struct MailDigest: Decodable {
    let items: [MailItem]
    let atlanan: Int

    init(items: [MailItem], atlanan: Int) {
        self.items = items
        self.atlanan = atlanan
    }

    private enum Keys: String, CodingKey { case items, atlanan, ozet, yapilacak, sonTarih }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let items = try container.decodeIfPresent([MailItem].self, forKey: .items) {
            self.items = items
            atlanan = (try? container.decode(Int.self, forKey: .atlanan)) ?? 0
        } else {
            items = [MailItem(onem: "normal", baslik: try container.decode(String.self, forKey: .ozet), detay: nil,
                              yapilacak: try container.decodeIfPresent(String.self, forKey: .yapilacak),
                              sonTarih: try container.decodeIfPresent(String.self, forKey: .sonTarih), kaynak: nil)]
            atlanan = 0
        }
    }

    var important: [MailItem] { items.filter(\.important) }
    var other: [MailItem] { items.filter { !$0.important } }

    /// What goes to the chat: the important items (or everything when none is).
    var shareText: String {
        let list = important.isEmpty ? items : important
        return "📬 Okul mailleri\n" + list.map { "• " + $0.shareText }.joined(separator: "\n")
    }
}

@MainActor
struct MailDigestClient {
    private static let relay = URL(string: "https://watchlink-mail.watchlink-relay.workers.dev/v1")!
    /// The Apps Script web app (one project, everyone connects with their own MEF account).
    static let connectPageURL = URL(string: "https://script.google.com/a/macros/mef.edu.tr/s/AKfycbzaR3MQHJW68mIqaRkEuYOOBXrLucciqLXwNOxsPqa7RCtA8kE7fOimX_Xm1wxsVzgS9g/exec")

    /// The page that stores a fresh ingest code for whoever opens it. The code can only write a digest.
    static func connectPage(token: String) -> URL? {
        guard let base = connectPageURL, var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = [URLQueryItem(name: "t", value: token)]
        return parts.url
    }
    let ownerID: String
    let idToken: () async throws -> String

    private struct Registration: Decodable { let ingestToken: String }
    private struct Envelope: Decodable {
        let id: String
        let ephemeralPublicKey: String
        let salt: String
        let nonce: String
        let ciphertext: String
    }

    private enum ClientError: Error { case requestFailed, unavailableKey, invalidEnvelope }

    func register() async throws -> String {
        let key = try loadKey() ?? makeKey()
        let publicKey = key.publicKey.x963Representation.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let body = try JSONEncoder().encode(["publicKey": publicKey])
        let (data, _) = try await request("mailbox", method: "POST", body: body, expecting: [201])
        return try JSONDecoder().decode(Registration.self, from: data).ingestToken
    }

    /// The latest digest, and when the owner's script last checked in (nil when
    /// the relay holds no mailbox for this account).
    func draft() async throws -> (digest: MailDigest?, seen: Date?) {
        let (data, response) = try await request("draft", expecting: [200, 204])
        let seen = response.value(forHTTPHeaderField: "x-watchlink-seen")
            .flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
        guard response.statusCode == 200 else { return (nil, seen) }
        guard let key = try loadKey() else { throw ClientError.unavailableKey }
        return (try Self.open(data, ownerID: ownerID, with: key), seen)
    }

    /// What the summary should know: the owner's own rules, their courses, and
    /// where to send an alert for an important mail. Needs a connected mailbox.
    func savePrefs(rules: String, courses: [Course], push: String?) async throws {
        struct Prefs: Encodable {
            struct Entry: Encodable { let code: String; let name: String? }
            let rules: String
            let courses: [Entry]
            let push: String?
        }
        let entries = courses.prefix(40).map { Prefs.Entry(code: $0.code, name: $0.name.isEmpty ? nil : $0.name) }
        let body = try JSONEncoder().encode(Prefs(rules: rules, courses: Array(entries), push: push))
        _ = try await request("prefs", method: "PUT", body: body, expecting: [204])
    }

    func disconnect() async throws {
        _ = try await request("mailbox", method: "DELETE", expecting: [204])
    }

    private func request(_ resource: String, method: String = "GET", body: Data? = nil,
                         expecting: Set<Int>) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: Self.relay.appendingPathComponent(resource),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(try await idToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, expecting.contains(http.statusCode) else {
            throw ClientError.requestFailed
        }
        return (data, http)
    }

    private static func open(_ data: Data, ownerID: String, with key: P256.KeyAgreement.PrivateKey) throws -> MailDigest {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let publicKey = Self.decodeBase64url(envelope.ephemeralPublicKey),
              let salt = Self.decodeBase64url(envelope.salt), salt.count == 32,
              let nonce = Self.decodeBase64url(envelope.nonce), nonce.count == 12,
              let ciphertext = Self.decodeBase64url(envelope.ciphertext), ciphertext.count > 16 else {
            throw ClientError.invalidEnvelope
        }
        let sender = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
        let shared = try key.sharedSecretFromKeyAgreement(with: sender)
        let symmetricKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                           sharedInfo: Data("watchlink-mail-preview-v1".utf8),
                                                           outputByteCount: 32)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                        ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
        let aad = try JSONEncoder().encode([ownerID, envelope.id])
        let plaintext = try AES.GCM.open(box, using: symmetricKey, authenticating: aad)
        return try JSONDecoder().decode(MailDigest.self, from: plaintext)
    }

    #if DEBUG
    static func demoDraft() throws -> MailDigest {
        // Public test vector generated outside CryptoKit with synthetic keys.
        var bytes = Data(repeating: 0, count: 32)
        bytes[31] = 1
        let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes)
        let fixture = """
        {
          "id": "kurgu-v1",
          "ephemeralPublicKey": "BHzyexiNA09-ilI4AwS1GsPAiWnid_IbNaYLSPxHZpl4B3dVENuO0EApPZrGn3Qw27p9reY86YIpngS3nSJ4c9E",
          "salt": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
          "nonce": "ICEiIyQlJicoKSor",
          "ciphertext": "1q5RhIlqRKXjmbx0WOxDXUPeXwfWxaUqu5ZacYOdttIBOMBhZHeqqQjrs-iFkrf5lOvykkmjFhmByHFX3Y43TNYDbAiYkXLEj9iRc77RqNGIPEmSM97CXy4oTqZALsTNh1b958OSCN0NPXC432j0i2vBJHh2QHr93uF0vpkOCt6wsKqmB4xTH5oZssXJGHA"
        }
        """
        let legacy = try open(Data(fixture.utf8), ownerID: "mail-demo", with: key)
        guard let lab = legacy.items.first else { return legacy }
        return MailDigest(items: [
            MailItem(onem: "yuksek", baslik: lab.baslik, detay: "Laboratuvar saati değişti, salon aynı.",
                     yapilacak: lab.yapilacak, sonTarih: lab.sonTarih, kaynak: "EE 101"),
            MailItem(onem: "yuksek", baslik: "EE 303 vize salonu B201 oldu", detay: "Sınav saati değişmedi.",
                     yapilacak: nil, sonTarih: "Pazartesi 10:00", kaynak: "EE 303"),
            MailItem(onem: "normal", baslik: "Kütüphane final haftası 24 saat açık", detay: nil,
                     yapilacak: nil, sonTarih: nil, kaynak: "Kütüphane"),
            MailItem(onem: "normal", baslik: "Bahar dönemi ders seçimi takvimi yayınlandı", detay: "Ayrıntılar SIS'te.",
                     yapilacak: nil, sonTarih: nil, kaynak: "Öğrenci İşleri"),
        ], atlanan: 6)
    }
    #endif

    private var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.batuhxn.watchlink.mail-preview-key",
         kSecAttrAccount as String: ownerID,
         kSecAttrSynchronizable as String: false]
    }

    private func loadKey() throws -> P256.KeyAgreement.PrivateKey? {
        var query = keyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else { throw ClientError.unavailableKey }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    private func makeKey() throws -> P256.KeyAgreement.PrivateKey {
        let key = P256.KeyAgreement.PrivateKey()
        var query = keyQuery
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = key.rawRepresentation
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw ClientError.unavailableKey }
        return key
    }

    private static func decodeBase64url(_ text: String) -> Data? {
        let value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value + padding)
    }
}
