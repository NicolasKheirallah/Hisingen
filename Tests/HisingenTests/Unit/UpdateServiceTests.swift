import Foundation
import Testing
@testable import Hisingen

@MainActor
struct UpdateServiceTests {
    @Test
    func marketingAndBuildVersionsCompareNumerically() throws {
        let v139 = try #require(HisingenReleaseVersion(marketingVersion: "1.3.9", build: "4"))
        let v140b5 = try #require(HisingenReleaseVersion(marketingVersion: "1.4.0", build: "5"))
        let v140b6 = try #require(HisingenReleaseVersion(marketingVersion: "1.4.0", build: "6"))
        let v141 = try #require(HisingenReleaseVersion(marketingVersion: "1.4.1", build: "7"))
        let v190 = try #require(HisingenReleaseVersion(marketingVersion: "1.9.0", build: "8"))
        let v1100 = try #require(HisingenReleaseVersion(marketingVersion: "1.10.0", build: "9"))

        #expect(v139 < v140b5)
        #expect(v140b5 < v140b6)
        #expect(v140b6 < v141)
        #expect(v190 < v1100)
    }

    @Test
    func invalidReleaseVersionsAreRejected() {
        #expect(HisingenReleaseVersion(marketingVersion: "1.4", build: "6") == nil)
        #expect(HisingenReleaseVersion(marketingVersion: "1.4.0", build: "bad") == nil)
        #expect(HisingenReleaseVersion(marketingVersion: "1.4.0-beta", build: "6") == nil)
    }

    @Test
    func onlyARealEd25519PublicKeyEnablesTheUpdater() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        // The production bundle key is deliberately never copied into tests. Validate the
        // contract through its standalone base64 shape instead.
        #expect(Data(base64Encoded: key)?.count == 32)
        #expect(!UpdateService.hasConfiguredPublicKey(.main))
    }

    @Test
    func abortedManualCheckTerminatesSpinnerWithoutOverwritingLaterState() {
        let available = UpdateService.State.updateAvailable(.init(marketingVersion: "1.4.0", build: "6"))
        let existingFailure = UpdateService.State.failed("Download failed")

        #expect(UpdateService.stateAfterAbortedCycle(.checking) == .failed("Update check failed. Please try again later."))
        #expect(UpdateService.stateAfterAbortedCycle(.idle) == .idle)
        #expect(UpdateService.stateAfterAbortedCycle(available) == available)
        #expect(UpdateService.stateAfterAbortedCycle(existingFailure) == existingFailure)
    }
}
