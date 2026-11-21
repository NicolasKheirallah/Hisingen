#if SWIFT_PACKAGE
import Foundation
import Testing
@testable import Hisingen

/// Opt-in, read-only probe for M7: does the C3 backend expose a read for the charge-schedule
/// override? The Polestar ID path can write one and cannot read it back, so the app can only say
/// "sent". This asks the candidate RPCs the same way `GetTargetSoc` and `GetAmpLimit` are read; it
/// sends no command and spends no command-client grant.
///
/// Run:
///   HISINGEN_ENABLE_POLESTAR_READ_PROBE=1 POLESTAR_VIN=<vin> \
///     sh Scripts/test.sh --filter LivePolestarChargeNowProbe --no-parallel
///
/// An "unimplemented" answer for every candidate settles the question: keep the honest copy and
/// close the read-back idea. A successful answer names the RPC to wire.
private let readProbeEnabled: Bool = {
    ProcessInfo.processInfo.environment["HISINGEN_ENABLE_POLESTAR_READ_PROBE"] == "1"
}()

@MainActor
struct LivePolestarChargeNowProbeTests {
    @Test(.disabled(if: !readProbeEnabled, "Set HISINGEN_ENABLE_POLESTAR_READ_PROBE=1"))
    func probeChargeNowReads() async throws {
        let environment = ProcessInfo.processInfo.environment
        let preferredVIN = environment["POLESTAR_VIN"].flatMap { $0.isEmpty ? nil : $0 }
        let keychain = KeychainStore.app
        let api = PolestarAPI(keychain: keychain)

        var features = FeatureSelection.default
        for feature in AppFeature.allCases where !feature.isRemoteControl {
            features.set(feature, enabled: true)
        }

        let storedSession = try keychain.readSessionToken()
        let sessionToken = try #require(storedSession, "No stored Polestar session refresh token")
        try await api.restoreSession(token: sessionToken, preferredVIN: preferredVIN, features: features)
        let vin = try #require(await api.resolvedVIN(preferred: preferredVIN))
        try await api.refreshTokenIfNeeded()
        let token = try #require(await api.accessToken)

        // Candidate reads, widest plausible naming first. Reads use the web token, like the
        // target-SOC and amp-limit reads; nothing here can change vehicle state.
        let candidates = [
            "/pccs.chronos.services.v1.ChargeNowService/GetChargeNow",
            "/pccs.chronos.services.v1.ChargeNowService/GetChargeNowStatus",
            "/pccs.chronos.services.v1.ChargeNowService/GetOverrideChargeTimer",
            "/pccs.chronos.services.v2.GlobalChargeTimerService/GetOverrideChargeTimer",
            "/pccs.chronos.services.v1.GlobalChargeTimerService/GetOverrideChargeTimer"
        ]

        print("PROBE vin=\(vin)")
        for path in candidates {
            do {
                let body = try await api.grpc.firstMessage(
                    path: path,
                    message: PolestarGRPC.stateRequest(vin: vin),
                    vin: vin,
                    accessToken: token
                )
                print("PROBE \(path) OK bytes=\(body.count)")
            } catch {
                print("PROBE \(path) FAILED \(String(describing: error))")
            }
        }
    }
}
#endif
