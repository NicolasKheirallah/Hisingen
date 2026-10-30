import Foundation

/// Parses a release's marketing and build versions so tests can assert ordering. Sparkle
/// compares CFBundleVersion during installation; the marketing version is display-only.
/// Production code never builds this type, so it lives with the test support.
struct HisingenReleaseVersion: Comparable, Equatable {
    let marketing: [Int]
    let build: Int

    init?(marketingVersion: String, build: String) {
        let values = marketingVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard values.count == 3, let parsedBuild = Int(build), parsedBuild >= 0 else { return nil }
        let parsedMarketing = values.compactMap { Int($0) }
        guard parsedMarketing.count == 3, parsedMarketing.allSatisfy({ $0 >= 0 }) else { return nil }
        marketing = parsedMarketing
        self.build = parsedBuild
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<3 where lhs.marketing[index] != rhs.marketing[index] {
            return lhs.marketing[index] < rhs.marketing[index]
        }
        return lhs.build < rhs.build
    }
}
