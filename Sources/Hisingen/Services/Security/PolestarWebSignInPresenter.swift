import AppKit
import Foundation
import WebKit

/// Authorizes the Polestar web client (`l3oopkc_10`) through an in-app `WKWebView` window
/// when the headless scripted PingFederate form-fill is rejected with an interactive challenge
/// (such as CAPTCHA, 2FA/MFA verification, or Terms of Service updates).
///
/// Because `polestar.com/sign-in-callback` is an HTTPS URL on a domain Hisingen does not control,
/// `ASWebAuthenticationSession` cannot be used directly for this client. The embedded web view's
/// `WKNavigationDelegate` intercepts the redirect before the page navigates away, capturing the
/// authorization code and resuming the async flow.
@MainActor
final class PolestarWebSignInPresenter: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private var pendingContinuation: CheckedContinuation<URL, Error>?
    private var activeWindow: NSWindow?
    private var expectedRedirectURI: URL?

    func signIn(authorizeURL: URL, redirectURI: URL) async throws -> URL {
        expectedRedirectURI = redirectURI
        return try await withCheckedThrowingContinuation { continuation in
            if let existing = self.pendingContinuation {
                self.pendingContinuation = nil
                existing.resume(throwing: PolestarError.authenticationRequired(.callbackRejected))
            }
            self.pendingContinuation = continuation

            let window = self.createSignInWindow()
            let webView = self.createWebView(frame: window.contentView?.bounds ?? .zero)
            window.contentView?.addSubview(webView)
            self.activeWindow = window

            webView.load(URLRequest(url: authorizeURL))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func createSignInWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("Polestar Sign In")
        window.delegate = self
        window.isReleasedWhenClosed = false
        return window
    }

    private func createWebView(frame: NSRect) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        return webView
    }

    private func isRedirectCallback(_ url: URL) -> Bool {
        guard let expected = expectedRedirectURI else { return false }
        return url.scheme == expected.scheme && url.host == expected.host
            && PolestarAPI.normalizedPath(url) == PolestarAPI.normalizedPath(expected)
    }

    private func finish(with result: Result<URL, Error>) {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        expectedRedirectURI = nil
        if let window = activeWindow {
            self.activeWindow = nil
            window.delegate = nil
            window.close()
        }
        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func cancel(with error: Error? = nil) {
        finish(with: .failure(error ?? PolestarError.authenticationRequired(.callbackRejected)))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let target = navigationAction.request.url, isRedirectCallback(target) {
            decisionHandler(.cancel)
            finish(with: .success(target))
        } else {
            decisionHandler(.allow)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if pendingContinuation != nil {
            finish(with: .failure(PolestarError.authenticationRequired(.callbackRejected)))
        }
    }
}
