import Foundation

enum BuiltinPolestarSecrets {
    static var isConfigured: Bool {
        GeneratedPolestarSecrets.isConfigured && !imageApiKey.isEmpty
    }

    /// Static AppSync-style key used to authenticate `GetCarImages` against
    /// `pc-api.polestar.com/eu-north-1/mystar-public/`. Baked into the official Polestar app —
    /// not user-specific, but still a real credential, so it's build-injected the same way as
    /// the Volvo developer secrets rather than committed in plaintext. See
    /// `docs/api/polestar-backend-map.md` (Public render CDN API key).
    static var imageApiKey: String {
        GeneratedPolestarSecrets.imageApiKey
    }
}
