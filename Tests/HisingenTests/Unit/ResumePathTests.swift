

import Testing
@testable import Hisingen

struct ResumePathTests {

    @Test
    func testCurrentLoginPageActionQuoted() {
        let html = #"<script>var flow = { action: "/as/abc123/resume/as/authorization.ping", other: 1 };</script>"#
        XCTAssertEqual(PolestarAPI.extractResumePath(from: html),
                       "/as/abc123/resume/as/authorization.ping")
    }

    @Test
    func testPingDotSuffixNotTruncated() {

        let html = "resume at /as/xY-9_z/resume/as/authorization.ping please"
        XCTAssertEqual(PolestarAPI.extractResumePath(from: html),
                       "/as/xY-9_z/resume/as/authorization.ping")
    }

    @Test
    func testResumePathAssignment() {
        let html = "var resumePath = '/idp/abc/resume';"
        XCTAssertEqual(PolestarAPI.extractResumePath(from: html), "/idp/abc/resume")
    }

    @Test
    func testFormActionAttribute() {
        let html = #"<form method="POST" action="/as/form99/resume"><input name="pf.username"></form>"#
        XCTAssertEqual(PolestarAPI.extractResumePath(from: html), "/as/form99/resume")
    }

    @Test
    func testAbsoluteURLNotMistakenForPath() {


        let html = #"config = { url: "https://polestarid.eu.polestar.com/x" }; go(/as/fall-back/resume)"#
        XCTAssertEqual(PolestarAPI.extractResumePath(from: html), "/as/fall-back/resume")
    }

    @Test
    func testNoMatchReturnsNil() {
        XCTAssertNil(PolestarAPI.extractResumePath(from: "<html><body>Maintenance</body></html>"))
    }
}


