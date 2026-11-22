import Foundation
import Testing
@testable import Hisingen

/// Reading Freshness now names the transport that answered, but only when that transport is
/// not the usual one. These pins hold both halves of that rule: portal-mode rows explain
/// themselves, Polestar ID rows stay quiet.
@MainActor
struct FreshnessSourceWordTests {

    private func value(source: VehicleReadingSource?) -> String {
        let now = Date()
        return InfoTabView.freshnessValue(
            reportedAt: now.addingTimeInterval(-120),
            receivedAt: now.addingTimeInterval(-90),
            now: now,
            source: source
        )
    }

    @Test("The usual Polestar app transport adds no word")
    func appTransportStaysQuiet() {
        #expect(!value(source: .polestarGraphQL).contains("App"))
    }

    @Test("A nil observation adds no word, so pre-feature snapshots read as before")
    func missingObservationStaysQuiet() {
        let now = Date()
        let reported = now.addingTimeInterval(-120)
        let withoutParameter = InfoTabView.freshnessValue(reportedAt: reported, receivedAt: now.addingTimeInterval(-90), now: now)
        #expect(value(source: nil) == withoutParameter)
    }

    @Test("Portal, live stream and weather readings get their word")
    func otherTransportsAreNamed() {
        #expect(value(source: .polestarPortal).hasSuffix("Portal"))
        #expect(value(source: .liveStream).hasSuffix("Live"))
        #expect(value(source: .weather).hasSuffix("Weather"))
    }

    @Test("The word rides after the age and the portal queue lag")
    func wordComesLast() {
        let line = value(source: .polestarGRPC)
        #expect(line.hasSuffix("gRPC"))
        #expect(line.contains("·"))
    }
}
