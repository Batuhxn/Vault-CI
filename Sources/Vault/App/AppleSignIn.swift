import AuthenticationServices
import CryptoKit
import Foundation

/// Nonce handling for Sign in with Apple -> Firebase Auth.
/// Apple gets the SHA-256 of the nonce; Firebase gets the raw nonce.
enum AppleSignIn {
    static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    struct Token {
        let idToken: String
        let fullName: PersonNameComponents?
    }

    static func token(from authorization: ASAuthorization) -> Token? {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken,
              let idToken = String(data: data, encoding: .utf8) else { return nil }
        return Token(idToken: idToken, fullName: credential.fullName)
    }
}
