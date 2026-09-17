#if SWIFT_PACKAGE
import Foundation
import Testing
@testable import Hisingen

/// Opt-in local diagnostic for the Polestar remote-command path. It is deliberately not part
/// of the default suite: it signs in with the stored session, spends a command-client grant,
/// and sends a real command to a real car. Set `HISINGEN_ENABLE_POLESTAR_COMMAND_PROBE=1`
/// and `POLESTAR_VIN` to run it.
private let commandProbeEnabled: Bool = {
    ProcessInfo.processInfo.environment["HISINGEN_ENABLE_POLESTAR_COMMAND_PROBE"] == "1"
}()

@MainActor
struct LivePolestarCommandDiagnosticTests {
    @Test(.disabled(if: !commandProbeEnabled, "Set HISINGEN_ENABLE_POLESTAR_COMMAND_PROBE=1"))
    func diagnoseClimateCommand() async throws {
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
        let webToken = try #require(try await api.validAccessToken())

        _ = try? await api.grpc.fetchMyCars(vin: vin, accessToken: webToken)
        let profile = await api.capabilityProfile(for: vin)
        let myCars = await api.cachedMyCars(for: vin)
        print("PROBE vin=\(vin)")
        print("PROBE model=\(profile.model) climateStartStop=\(profile.support(for: .climateStartStop)) climateTemperature=\(profile.support(for: .climateTemperature)) seatHeating=\(profile.support(for: .seatHeating)) steering=\(profile.support(for: .steeringWheelHeating))")
        print("PROBE hasSelectableClimateTemperature=\(profile.hasSelectableClimateTemperature)")
        print("PROBE advertised=\(String(describing: myCars?.advertisedCapabilities))")
        print("PROBE controlSettings tempRange=\(String(describing: myCars?.controlSettings?.temperatureRange)) frontSeat=\(String(describing: myCars?.controlSettings?.frontSeatSettings)) rearSeat=\(String(describing: myCars?.controlSettings?.rearSeatSettings)) steeringSetting=\(String(describing: myCars?.controlSettings?.steeringWheelSettings))")

        let adapted = RemoteCommand.startClimate(
            temperatureCelsius: 21,
            frontLeftSeat: .level2, frontRightSeat: .level1,
            rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .off
        ).adapted(to: profile, settings: myCars?.controlSettings)
        print("PROBE adaptedCommand=\(adapted)")

        let authorization = await api.commandClientAuthorization()
        guard case .authorized(let commandToken) = authorization else {
            print("PROBE command authorization unavailable: \(authorization)")
            return
        }
        print("PROBE commandClientAuthorized=true")

        await reportClimate(api: api, vin: vin, token: webToken, label: "before")

        // 1. Test auto climate (temperature 0): wire request automatically supplies the 22 °C comfort setpoint.
        await invokeClimate(api: api, vin: vin, token: commandToken, temperature: 0,
                            seats: .unspecified, label: "auto(22C comfort default)")
        await pollClimate(api: api, vin: vin, token: webToken, seconds: 90, label: "after-auto")

        // 2. Same start with an explicit setpoint (the documented "custom" shape).
        await invokeClimate(api: api, vin: vin, token: commandToken, temperature: 21,
                            seats: .off, label: "custom(21C)")
        await pollClimate(api: api, vin: vin, token: webToken, seconds: 90, label: "after-custom")

        // Clean up: stop climate so the probe does not leave the car preconditioning.
        await invokeStop(api: api, vin: vin, token: commandToken)
        try? await api.signOut()
    }

    private func invokeClimate(api: PolestarAPI, vin: String, token: String,
                               temperature: Float, seats: HeatingLevel, label: String) async {
        let request = PolestarGRPC.climateStartRequest(
            vin: vin, temperature: temperature,
            frontLeft: seats, frontRight: seats, rearLeft: seats, rearRight: seats, steeringWheel: seats
        )
        await invoke(api: api, vin: vin, token: token,
                     path: "/invocation.InvocationService/ClimatizationStart",
                     message: request, label: label)
    }

    private func invokeStop(api: PolestarAPI, vin: String, token: String) async {
        let request = Protobuf.messageField(1, Protobuf.stringField(1, vin))
        await invoke(api: api, vin: vin, token: token,
                     path: "/invocation.InvocationService/ClimatizationStop",
                     message: request, label: "stop")
    }

    private func invoke(api: PolestarAPI, vin: String, token: String,
                        path: String, message: Data, label: String) async {
        do {
            let body = try await api.grpc.lastMessage(path: path, message: message, vin: vin,
                                                      accessToken: token, host: .c3)
            print("PROBE \(label) responseBytes=\(body.count) hex=\(hex(body))")
            dumpFields(body, indent: "  ")
            if let nested = Protobuf.fields(body).first(where: { $0.number == 1 && $0.wire == 2 })?.data {
                print("PROBE \(label) nested:")
                dumpFields(nested, indent: "    ")
            }
        } catch {
            print("PROBE \(label) threw \(error)")
        }
    }

    private func pollClimate(api: PolestarAPI, vin: String, token: String,
                             seconds: Int, label: String) async {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        var last: String?
        while Date() < deadline {
            if let climate = try? await api.grpc.fetchClimate(vin: vin, accessToken: token) {
                let line = "\(climate.activity) remaining=\(String(describing: climate.timeRemainingMinutes)) interior=\(String(describing: climate.interiorTemperatureCelsius)) requested=\(String(describing: climate.requestedTemperatureCelsius))"
                if line != last {
                    print("PROBE \(label) \(line)")
                    last = line
                }
                if climate.activity.isActiveSession { return }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        print("PROBE \(label) still idle after \(seconds)s")
    }

    private func reportClimate(api: PolestarAPI, vin: String, token: String, label: String) async {
        if let climate = try? await api.grpc.fetchClimate(vin: vin, accessToken: token) {
            print("PROBE \(label) activity=\(climate.activity) remaining=\(String(describing: climate.timeRemainingMinutes)) interior=\(String(describing: climate.interiorTemperatureCelsius)) requested=\(String(describing: climate.requestedTemperatureCelsius)) unknown=\(String(describing: climate.unknownWireFields))")
        } else {
            print("PROBE \(label) climate read failed")
        }
    }

    private func dumpFields(_ data: Data, indent: String) {
        for field in Protobuf.fields(data) {
            let varint = field.wire == 0 ? String(field.varint) : "-"
            let bytes = field.wire == 2 ? hex(field.data) : "-"
            print("\(indent)field=\(field.number) wire=\(field.wire) varint=\(varint) data=\(bytes)")
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
