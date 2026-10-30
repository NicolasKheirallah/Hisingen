import Foundation
import Testing
@testable import Hisingen

struct DiagnosticRedactionFormatsTests {
    @Test
    func jsonCredentialFieldsLoseTheirValues() {
        let input = #"{"refresh_token":"refresh-secret","access_token":"access-secret","client_secret":"client-secret","accessToken":"camel-secret"}"#
        let output = DiagnosticRedaction.redactSecrets(input)

        #expect(!output.contains("refresh-secret"))
        #expect(!output.contains("access-secret"))
        #expect(!output.contains("client-secret"))
        #expect(!output.contains("camel-secret"))
        #expect(output.contains(#""refresh_token":"<redacted>""#))
        #expect(output.contains(#""access_token":"<redacted>""#))
        #expect(output.contains(#""accessToken":"<redacted>""#))
    }

    @Test
    func spacedJSONKeepsSpacingAndRedactsQuotedValuesWithSpaces() {
        let output = DiagnosticRedaction.redactSecrets(#"{"access_token": "xyz987", "password" : "correct horse battery"}"#)

        #expect(output.contains(#""access_token": "<redacted>""#))
        #expect(output.contains(#""password" : "<redacted>""#))
        #expect(!output.contains("xyz987"))
        #expect(!output.contains("battery"))
    }

    @Test
    func colonAndEqualsFormsRedactUnquotedValues() {
        #expect(DiagnosticRedaction.redactSecrets("login password: hunter2 retry") == "login password: <redacted> retry")
        #expect(DiagnosticRedaction.redactSecrets("refresh failed token=super-secret ok") == "refresh failed token=<redacted> ok")
        #expect(DiagnosticRedaction.redactSecrets("token:abc123, next") == "token:<redacted>, next")
    }

    @Test
    func authorizationHeaderKeepsTheSchemeWord() {
        let output = DiagnosticRedaction.redactSecrets("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9")

        #expect(output == "Authorization: Bearer <redacted>")
    }

    @Test
    func redactionIsIdempotent() {
        let input = #"{"refresh_token":"abc","password": "x y"} token=zzz"#
        let once = DiagnosticRedaction.redactSecrets(input)

        #expect(DiagnosticRedaction.redactSecrets(once) == once)
    }
}
