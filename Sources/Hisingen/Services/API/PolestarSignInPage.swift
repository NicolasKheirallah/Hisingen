import Foundation

/// What Hisingen reads from Polestar's PingFederate sign-in pages. Pure string handling, kept out
/// of `PolestarAPI` so it can be tested without an actor or a network.
enum PolestarSignInPage {
    /// Text the sign-in page shows when it rejects the e-mail or password.
    static let invalidCredentialsMarker = "ERR001"

    /// Keys under which the page can carry its resume path, in markup or in inline script.
    private static let resumePathKeys = ["url", "action", "resumePath", "pf.resumePath"]

    /// Where the page hands over its resume path, tried in order. A keyed value
    /// (`action="…"`, `url: '…'`, `resumePath = "…"`) is the most specific; a bare `/as/…` token
    /// is the fallback. `group` is the capture that holds the path.
    private static let resumePathSources: [(regex: NSRegularExpression, group: Int)] = {
        let keys = resumePathKeys.map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let keyed = #"(?:\#(keys))\s*[:=]\s*(["'])(.+?)\1"#
        let bare = #"/as/[\w\-./]+"#
        return [(keyed, 2), (bare, 0)].compactMap { pattern, group in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, group) }
        }
    }()

    /// The password is posted to this path, so every match is checked, not just the first per
    /// source: an unrelated `url: "/static/app.js"` earlier in the page is skipped instead of
    /// becoming the sign-in target.
    static func resumePath(in html: String) -> String? {
        let range = NSRange(html.startIndex..., in: html)
        for (regex, group) in resumePathSources {
            for match in regex.matches(in: html, range: range) {
                guard let matchRange = Range(match.range(at: group), in: html) else { continue }
                let value = String(html[matchRange])
                if isPlausibleResumePath(value) { return value }
            }
        }
        return nil
    }

    /// A same-host PingFederate resume path: absolute, not protocol-relative, no traversal,
    /// URL-path characters only, and containing a `/resume` segment.
    static func isPlausibleResumePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), !value.hasPrefix("//"), !value.contains(".."),
              value.contains("/resume") else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_./~%".contains($0)) }
    }

    /// Whether a response page reports rejected credentials.
    static func rejectsCredentials(_ html: String) -> Bool {
        html.contains(invalidCredentialsMarker)
    }
}
