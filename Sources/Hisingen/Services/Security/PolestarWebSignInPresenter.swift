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
final class PolestarWebSignInPresenter: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private var pendingContinuation: CheckedContinuation<URL, Error>?
    private var activeWindow: NSWindow?
    private var flow: PolestarBrowserFlow?
    private var activeWebView: WKWebView?
    private var flowID: UUID?

    func signIn(authorizeURL: URL, redirectURI: URL) async throws -> URL {
        try Task.checkCancellation()
        cancel()
        let id = UUID()
        flowID = id
        flow = PolestarBrowserFlow(authorizeURL: authorizeURL, redirectURI: redirectURI)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingContinuation = continuation
                let window = createSignInWindow()
                let webView = createWebView(frame: window.contentView?.bounds ?? .zero)
                window.contentView?.addSubview(webView)
                activeWindow = window
                activeWebView = webView
                webView.load(URLRequest(url: authorizeURL))
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.flowID == id else { return }
                self?.cancel(with: CancellationError())
            }
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
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        return webView
    }

    private func finish(with result: Result<URL, Error>) {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        flow = nil
        flowID = nil
        activeWebView?.stopLoading()
        activeWebView?.navigationDelegate = nil
        activeWebView?.uiDelegate = nil
        activeWebView = nil
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
        guard webView === activeWebView else {
            decisionHandler(.cancel)
            return
        }
        if let target = navigationAction.request.url, flow?.accepts(target) == true {
            decisionHandler(.cancel)
            finish(with: .success(target))
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === activeWebView, let url = webView.url,
              let retry = flow?.resumeAfterWebsiteLogin(at: url) else { return }
        webView.load(URLRequest(url: retry))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === activeWebView else { return nil }
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === activeWindow {
            finish(with: .failure(PolestarError.authenticationRequired(.callbackRejected)))
        }
    }
}
