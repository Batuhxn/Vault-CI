import CryptoKit
import Foundation
import Security

struct MailDigest: Decodable {
    let ozet: String
    let yapilacak: String?
    let sonTarih: String?

    var shareText: String {
        var lines = [ozet]
        if let yapilacak { lines.append("Yapılacak: \(yapilacak)") }
        if let sonTarih { lines.append("Son tarih: \(sonTarih)") }
        return lines.joined(separator: "\n")
    }
}

@MainActor
struct MailDigestClient {
    private static let relay = URL(string: "https://watchlink-mail.watchlink-relay.workers.dev/v1")!
    /// The Apps Script web app (one project, everyone connects with their own MEF account).
    static let connectPageURL: URL? = nil

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

    func draft() async throws -> MailDigest? {
        let (data, status) = try await request("draft", expecting: [200, 204])
        guard status == 200 else { return nil }
        guard let key = try loadKey() else { throw ClientError.unavailableKey }
        return try Self.open(data, ownerID: ownerID, with: key)
    }

    func disconnect() async throws {
        _ = try await request("mailbox", method: "DELETE", expecting: [204])
    }

    private func request(_ resource: String, method: String = "GET", body: Data? = nil,
                         expecting: Set<Int>) async throws -> (Data, Int) {
        var request = URLRequest(url: Self.relay.appendingPathComponent(resource),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(try await idToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, expecting.contains(status) else {
            throw ClientError.requestFailed
        }
        return (data, status)
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
        return try open(Data(fixture.utf8), ownerID: "mail-demo", with: key)
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
