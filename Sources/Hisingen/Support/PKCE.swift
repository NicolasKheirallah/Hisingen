import CryptoKit
import Foundation
import Security


enum PKCE {
    static func randomURLSafeString() throws -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer) == errSecSuccess else {
            throw URLError(.unknown)
        }
        return base64URLEncode(Data(buffer))
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

