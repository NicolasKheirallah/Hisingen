import Foundation
import Testing
@testable import Hisingen

struct PolestarBrowserFlowTests {
    private let authorization = URL(string: "https://polestarid.eu.polestar.com/authorize?state=current&code_challenge=original")!
    private let redirect = URL(string: "https://www.polestar.com/sign-in-callback")!

    @Test func websiteLoginResumesOriginalRequestOnlyOnce() {
        var flow = PolestarBrowserFlow(authorizeURL: authorization, redirectURI: redirect)
        #expect(flow.resumeAfterWebsiteLogin(at: URL(string: "https://www.polestar.com/se/account")!) == authorization)
        #expect(flow.resumeAfterWebsiteLogin(at: URL(string: "https://www.polestar.com/error")!) == nil)
        #expect(flow.accepts(URL(string: "https://www.polestar.com/sign-in-callback?code=code&state=current")!))
    }

    @Test func foreignAndIdentityProviderPagesDoNotRestartTheLogin() {
        var flow = PolestarBrowserFlow(authorizeURL: authorization, redirectURI: redirect)
        for url in ["https://polestarid.eu.polestar.com/login", "https://evil.example/account", "http://www.polestar.com/account"] {
            #expect(flow.resumeAfterWebsiteLogin(at: URL(string: url)!) == nil)
        }
        #expect(!flow.resumedWebsiteLogin)
    }

    @Test func staleCallbacksAndWebsiteOwnLoginCannotCompleteTheActiveRequest() {
        let flow = PolestarBrowserFlow(authorizeURL: authorization, redirectURI: redirect)
        for url in [
            "https://www.polestar.com/sign-in-callback?code=old&state=old",
            "https://www.polestar.com/sign-in-callback?error=access_denied",
            "https://www.polestar.com/sign-in-callback?state=current",
            "https://evil.example/sign-in-callback?code=code&state=current",
            "https://www.polestar.com/wrong-path?code=code&state=current"
        ] { #expect(!flow.accepts(URL(string: url)!)) }
        #expect(flow.accepts(URL(string: "https://www.polestar.com/sign-in-callback?error=access_denied&state=current")!))
    }
}
