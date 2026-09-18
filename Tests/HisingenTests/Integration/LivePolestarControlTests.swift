#if SWIFT_PACKAGE
import Foundation
import Testing
@testable import Hisingen

private let liveControlsEnabled = ProcessInfo.processInfo.environment["HISINGEN_LIVE_CONTROLS"] == "1"

private struct ControlFailure: Error, CustomStringConvertible {
    let description: String
}

private struct LiveControlSetupError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Explicitly opted-in live test of the consumer control path (C3 gRPC invocation) against
/// the real vehicle, authenticating with the HISINGEN_TEST_EMAIL / HISINGEN_TEST_PASSWORD
/// credentials (the same account the read-only live tests use). Never runs in ordinary
/// suites: it requires HISINGEN_LIVE_CONTROLS=1. Quit the Hisingen app first so the two
/// processes cannot rotate the single-use refresh token against each other.
///
/// Invocation-backed commands (locks, climate, cabin cleaning) additionally need the
/// command-client authorization from Settings → Remote Controls; results without it are
/// reported as rejected-by-authorization, which is itself the tested behavior.
@MainActor
struct LivePolestarControlTests {
    /// Fast single-control probe: answers "does an invocation command work right now?" in
    /// one round trip, without the full matrix.
    @Test(.disabled(if: !liveControlsEnabled, "Set HISINGEN_LIVE_CONTROLS=1 to run live control probes"))
    func liveClimateProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        let email = try #require(environment["HISINGEN_TEST_EMAIL"], "HISINGEN_TEST_EMAIL required")
        let password = try #require(environment["HISINGEN_TEST_PASSWORD"], "HISINGEN_TEST_PASSWORD required")
        let preferredVIN = environment["HISINGEN_TEST_VIN"]

        let keychain = KeychainStore(service: "io.kheirallah.hisingen.live-controls.\(UUID().uuidString)")
        // The command-client grant lives in the app's keychain (Settings authorized it);
        // copy it into this run's store so invocation commands can use it.
        if let commandToken = try? KeychainStore.app.readCommandSessionToken(), !commandToken.isEmpty {
            try? keychain.saveCommandSessionToken(commandToken)
        }
        let api = PolestarAPI(keychain: keychain, preferences: .shared)
        try await api.authenticate(email: email, password: password,
                                   preferredVIN: preferredVIN, features: preferencesFeatures())
        let vin = try #require(await api.resolvedVIN(preferred: preferredVIN), "no vehicle discovered")

        do {
            let result = try await api.executeRemoteCommand(
                .startClimate(temperatureCelsius: 21, frontLeftSeat: .off, frontRightSeat: .off,
                              rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .off),
                vin: vin)
            print("LIVE CONTROL | startClimate outcome: \(result.outcome.rawValue)\(result.message.map { " — \($0)" } ?? "")")
        } catch RemoteCommandError.rejected(let message) {
            print("LIVE CONTROL | startClimate REJECTED: \(message ?? "authorization required")")
            throw LiveControlSetupError(message: message ?? "authorization required")
        } catch {
            print("LIVE CONTROL | startClimate FAILED: \(error)")
            throw error
        }

        var confirmed = false
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if (try? await api.fetchVehicleState(vin: vin, features: .default))?.climateStatus?.activity == .active {
                confirmed = true
                break
            }
            try? await Task.sleep(for: .seconds(5))
        }
        print("LIVE CONTROL | climate \(confirmed ? "ACTIVE — telemetry confirms the car started preconditioning" : "did not confirm within 90s")")

        let stop = try await api.executeRemoteCommand(.stopClimate, vin: vin)
        print("LIVE CONTROL | stopClimate outcome: \(stop.outcome.rawValue)")
        #expect(confirmed)
    }

    @Test(.disabled(if: !liveControlsEnabled, "Set HISINGEN_LIVE_CONTROLS=1 to run live control probes"))
    func liveControlRoundTrip() async throws {
        var results: [String] = []
        func record(_ name: String, _ status: String, _ detail: String) {
            results.append("\(status)  \(name) — \(detail)")
            print("LIVE CONTROL | \(status) | \(name) | \(detail)")
        }

        let environment = ProcessInfo.processInfo.environment
        let email = try #require(environment["HISINGEN_TEST_EMAIL"], "HISINGEN_TEST_EMAIL required")
        let password = try #require(environment["HISINGEN_TEST_PASSWORD"], "HISINGEN_TEST_PASSWORD required")
        let preferredVIN = environment["HISINGEN_TEST_VIN"]

        let keychain = KeychainStore(service: "io.kheirallah.hisingen.live-controls.\(UUID().uuidString)")
        // The command-client grant lives in the app's keychain (Settings authorized it);
        // copy it into this run's store so invocation commands can use it.
        if let commandToken = try? KeychainStore.app.readCommandSessionToken(), !commandToken.isEmpty {
            try? keychain.saveCommandSessionToken(commandToken)
        }
        let api = PolestarAPI(keychain: keychain, preferences: .shared)
        do {
            try await api.authenticate(email: email, password: password,
                                       preferredVIN: preferredVIN, features: preferencesFeatures())
        } catch {
            throw LiveControlSetupError(message: "Polestar ID sign-in failed: \(error)")
        }
        let vin = try #require(await api.resolvedVIN(preferred: preferredVIN), "no vehicle discovered")
        record("signIn", "OK", "VIN \(vin)")

        // 1. Baseline read.
        let baseline = try await api.fetchVehicleState(vin: vin, features: .default)
        record("readState", "OK", "battery \(baseline.energy.batteryPercentage.map { Int($0) }.map(String.init) ?? "?")%")

        // 2. Charge target: write the value already set — provable write, no behavior change.
        let target = baseline.energy.targetPercentage ?? 80
        await probe("setChargeTarget(\(target))", record: record) {
            try await api.executeRemoteCommand(.setChargeTarget(target), vin: vin)
        }

        // 3. Amperage limit: same trick — write the reported limit back.
        if let amps = baseline.energy.currentLimitAmps {
            await probe("setAmpLimit(\(amps))", record: record) {
                try await api.executeRemoteCommand(.setAmpLimit(amps), vin: vin)
            }
        } else {
            record("setAmpLimit", "SKIP", "no current limit reported")
        }

        // 4. Climate start → verified start → stop.
        await probe("startClimate", record: record) {
            try await api.executeRemoteCommand(
                .startClimate(temperatureCelsius: 21, frontLeftSeat: .off, frontRightSeat: .off,
                              rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .off),
                vin: vin)
        }
        await poll("climateActive", record: record, seconds: 90) {
            try await api.fetchVehicleState(vin: vin, features: .default).climateStatus?.activity == .active
        }
        await probe("stopClimate", record: record) {
            try await api.executeRemoteCommand(.stopClimate, vin: vin)
        }

        // 5. Cabin cleaning start → stop (safe when idle).
        await probe("startPreCleaning", record: record) {
            try await api.executeRemoteCommand(.startPreCleaning, vin: vin)
        }
        await probe("stopPreCleaning", record: record) {
            try await api.executeRemoteCommand(.stopPreCleaning, vin: vin)
        }

        // 6. Lock → verify → unlock → verify (car is parked; the round trip restores state).
        await probe("lock", record: record) {
            try await api.executeRemoteCommand(.lock, vin: vin)
        }
        await poll("lockedVerified", record: record, seconds: 60) {
            try await api.fetchVehicleState(vin: vin, features: .default).exteriorStatus?.isLocked == true
        }
        await probe("unlock", record: record) {
            try await api.executeRemoteCommand(.unlock, vin: vin)
        }
        await poll("unlockedVerified", record: record, seconds: 60) {
            try await api.fetchVehicleState(vin: vin, features: .default).exteriorStatus?.isLocked == false
        }

        // 7. Charge-now override only while plugged in; otherwise a skip.
        let connected = (try? await api.fetchVehicleState(vin: vin, features: .default))?
            .energy.connection == .connected
        if connected {
            await probe("startChargingOverride", record: record) {
                try await api.executeRemoteCommand(.startChargingOverride, vin: vin)
            }
            await probe("stopChargingOverride", record: record) {
                try await api.executeRemoteCommand(.stopChargingOverride, vin: vin)
            }
        } else {
            record("startChargingOverride", "SKIP", "vehicle not connected to a charger")
        }

        // 8. Climate timer round trip: create, verify, delete (leaves no residue).
        await probe("setClimateTimer", record: record) {
            try await api.executeRemoteCommand(
                .setClimateTimer(VehicleSchedule(kind: .climate, startHour: 5, startMinute: 30,
                                                 endHour: nil, endMinute: nil, weekdays: [], isActive: true)),
                vin: vin)
        }
        let timerState = try? await api.fetchVehicleState(vin: vin, features: .default)
        let createdTimer = timerState?.climateTimers.first(where: { $0.startHour == 5 && $0.startMinute == 30 })
        record("climateTimerVisible", createdTimer != nil ? "OK" : "WARN",
               createdTimer != nil ? "timer \(createdTimer!.backendID ?? "?") reported by the car" : "created timer not in telemetry yet")
        if let id = createdTimer?.backendID {
            await probe("deleteClimateTimer", record: record) {
                try await api.executeRemoteCommand(.deleteClimateTimer(id: id), vin: vin)
            }
        }

        // 9. Honk/flash is disruptive — only with the extra opt-in.
        if environment["HISINGEN_LIVE_HONK"] == "1" {
            await probe("honkAndFlash", record: record) {
                try await api.executeRemoteCommand(.honkAndFlash, vin: vin)
            }
        } else {
            record("honkAndFlash", "SKIP", "set HISINGEN_LIVE_HONK=1 to include")
        }

        await api.resetSession()

        let failed = results.filter { $0.hasPrefix("FAIL") }
        print("LIVE CONTROL SUMMARY: \(results.count - failed.count)/\(results.count) settled, \(failed.count) failed")
        for failure in failed { Issue.record(ControlFailure(description: failure)) }
    }

    private func probe(_ name: String, record: (String, String, String) -> Void,
                       _ body: () async throws -> RemoteCommandResult) async {
        do {
            let result = try await body()
            record(name, "OK", "outcome \(result.outcome.rawValue)\(result.message.map { " — \($0)" } ?? "")")
        } catch RemoteCommandError.rejected(let message) {
            record(name, "REJECTED", message ?? "authorization required (Settings → Remote Controls)")
        } catch {
            record(name, "FAIL", String(describing: error))
        }
    }

    private func poll(_ name: String, record: (String, String, String) -> Void, seconds: TimeInterval,
                      _ condition: () async throws -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? await condition()) == true {
                record(name, "OK", "confirmed")
                return
            }
            try? await Task.sleep(for: .seconds(5))
        }
        record(name, "WARN", "not confirmed within \(Int(seconds))s (invocation may still be settling)")
    }

    private func preferencesFeatures() -> FeatureSelection {
        FeatureSelection(enabled: AppFeature.permittedFeatures)
    }
}
#endif
