import Foundation

struct PolestarBrowserFlow {
    let authorizeURL: URL
    let redirectURI: URL
    private(set) var resumedWebsiteLogin = false

    func accepts(_ url: URL) -> Bool {
        guard url.scheme == redirectURI.scheme, url.host == redirectURI.host,
              PolestarAPI.normalizedPath(url) == PolestarAPI.normalizedPath(redirectURI),
              let state = PolestarAPI.queryValue("state", from: authorizeURL), !state.isEmpty,
              PolestarAPI.queryValue("state", from: url) == state else { return false }
        return PolestarAPI.queryValue("code", from: url) != nil
            || PolestarAPI.queryValue("error", from: url) != nil
    }

    mutating func resumeAfterWebsiteLogin(at url: URL) -> URL? {
        guard !resumedWebsiteLogin, url.scheme == "https", url.host == redirectURI.host,
              !accepts(url) else { return nil }
        // Some website flows finish their own login instead of our OAuth request.
        // Reuse its cookies, but keep the original PKCE challenge and state.
        resumedWebsiteLogin = true
        return authorizeURL
    }
}
