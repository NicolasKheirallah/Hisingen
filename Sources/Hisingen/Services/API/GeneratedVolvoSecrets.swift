// Default public fallback with no embedded secrets
import Foundation

enum GeneratedVolvoSecrets {
    static let isConfigured: Bool = false
    static var clientID: String { "" }
    static var clientSecret: String { "" }
    static var vccApiKey: String { "" }
}
