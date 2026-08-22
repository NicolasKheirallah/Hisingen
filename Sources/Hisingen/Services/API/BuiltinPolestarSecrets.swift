import Foundation

enum BuiltinPolestarSecrets {
    static var isConfigured: Bool { true }

    /// Static AppSync-style key used to authenticate `GetCarImages` against
    /// `pc-api.polestar.com/eu-north-1/mystar-public/`. Baked into the official Polestar app,
    /// not user-specific — the same value is published in plaintext by other open-source
    /// Polestar clients (e.g. `pypolestar/pypolestar`'s `const.py`), so it ships here as a
    /// working default rather than requiring every contributor to hunt it down or configure a
    /// build secret before vehicle images work. `POLESTAR_IMAGE_API_KEY` (via `.env.secrets` or
    /// CI) still overrides this default if Polestar ever rotates it. See
    /// `docs/api/polestar-backend-map.md` (Public render CDN API key).
    static var imageApiKey: String {
        GeneratedPolestarSecrets.isConfigured ? GeneratedPolestarSecrets.imageApiKey : "da2-js63uvc7c5hwpdudt657d5lyou"
    }
}
