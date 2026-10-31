

import Foundation
import Testing
@testable import Hisingen

struct ResumePathTests {

    @Test
    func testCurrentLoginPageActionQuoted() {
        let html = #"<script>var flow = { action: "/as/abc123/resume/as/authorization.ping", other: 1 };</script>"#
        #expect(PolestarAPI.extractResumePath(from: html) == "/as/abc123/resume/as/authorization.ping")
    }

    @Test
    func testPingDotSuffixNotTruncated() {

        let html = "resume at /as/xY-9_z/resume/as/authorization.ping please"
        #expect(PolestarAPI.extractResumePath(from: html) == "/as/xY-9_z/resume/as/authorization.ping")
    }

    @Test
    func testResumePathAssignment() {
        let html = "var resumePath = '/idp/abc/resume';"
        #expect(PolestarAPI.extractResumePath(from: html) == "/idp/abc/resume")
    }

    @Test
    func testFormActionAttribute() {
        let html = #"<form method="POST" action="/as/form99/resume"><input name="pf.username"></form>"#
        #expect(PolestarAPI.extractResumePath(from: html) == "/as/form99/resume")
    }

    @Test
    func testAbsoluteURLNotMistakenForPath() {


        let html = #"config = { url: "https://polestarid.eu.polestar.com/x" }; go(/as/fall-back/resume)"#
        #expect(PolestarAPI.extractResumePath(from: html) == "/as/fall-back/resume")
    }

    @Test
    func testNoMatchReturnsNil() {
        #expect(PolestarAPI.extractResumePath(from: "<html><body>Maintenance</body></html>") == nil)
    }

    @Test
    func testSingleQuotedKeysAreRead() {
        #expect(PolestarAPI.extractResumePath(from: "go({ action: '/as/q1/resume' })") == "/as/q1/resume")
        #expect(PolestarAPI.extractResumePath(from: "go({ url: '/as/q2/resume/as/authorization.ping' })")
                == "/as/q2/resume/as/authorization.ping")
    }

    @Test
    func testQualifiedResumePathKey() {
        #expect(PolestarAPI.extractResumePath(from: #"pf.resumePath = "/as/p9/resume""#) == "/as/p9/resume")
    }

    @Test
    func testUnrelatedKeyedValueIsSkipped() {
        let html = #"<script>load({ url: "/static/app.js" })</script><form action="/as/z7/resume"></form>"#
        #expect(PolestarAPI.extractResumePath(from: html) == "/as/z7/resume")
    }

    @Test
    func testTraversalAndProtocolRelativePathsAreRejected() {
        #expect(PolestarAPI.extractResumePath(from: #"action="//evil.example/resume""#) == nil)
        #expect(PolestarAPI.extractResumePath(from: #"action="/as/../resume""#) == nil)
    }
}



struct OAuthErrorBodyTests {

    @Test func deadGrantCodesAreRecognised() {
        #expect(OAuthErrorBody.isDeadGrant(Data(#"{"error":"invalid_grant"}"#.utf8)))
        #expect(OAuthErrorBody.isDeadGrant(Data(#"{"error":"expired_token"}"#.utf8)))
        #expect(!OAuthErrorBody.isDeadGrant(Data(#"{"error":"invalid_client"}"#.utf8)))
    }

    @Test func nonJSONAndEmptyCodesAreIgnored() {
        #expect(OAuthErrorBody.code(in: Data("<html>".utf8)) == nil)
        #expect(OAuthErrorBody.code(in: Data(#"{"error":""}"#.utf8)) == nil)
        #expect(!OAuthErrorBody.isDeadGrant(Data()))
    }

    @Test func diagnosticFormIsPrefixedAndSharedByBothProviders() {
        let body = Data(#"{"error":"invalid_grant"}"#.utf8)
        #expect(OAuthErrorBody.diagnosticCode(in: body) == "oauth:invalid_grant")
        #expect(PolestarAPI.oauthErrorCode(in: body) == "oauth:invalid_grant")
        #expect(VolvoAPI.oauthErrorCode(in: body) == "oauth:invalid_grant")
    }
}

struct PolestarSignInPageTests {

    @Test func rejectedCredentialsAreDetected() {
        #expect(PolestarSignInPage.rejectsCredentials("<p class=\"error\">ERR001</p>"))
        #expect(!PolestarSignInPage.rejectsCredentials("<p>Welcome</p>"))
    }

    @Test func appIdentityPairStaysTogether() {
        // The version and the user agent are bumped as a pair; a half-bump is how a 426 returns.
        #expect(PolestarAppIdentity.userAgent.contains(PolestarAppIdentity.version))
    }
}
