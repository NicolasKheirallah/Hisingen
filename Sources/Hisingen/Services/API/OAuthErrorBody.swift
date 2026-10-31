import Foundation

/// The `error` member of an OAuth token-endpoint error body (RFC 6749 section 5.2). It
/// classifies a rejected grant without carrying a credential, so it is safe to log, and it is the
/// one field that separates a permanently dead grant from a misconfigured client.
enum OAuthErrorBody {
    /// Codes that mean the presented refresh token will never work again.
    static let deadGrantCodes: Set<String> = ["invalid_grant", "expired_token"]

    static func code(in data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = body["error"] as? String, !code.isEmpty else { return nil }
        return code
    }

    static func isDeadGrant(_ data: Data) -> Bool {
        code(in: data).map(deadGrantCodes.contains) ?? false
    }

    /// The form recorded in the diagnostic log.
    static func diagnosticCode(in data: Data) -> String? {
        code(in: data).map { "oauth:\($0)" }
    }
}
