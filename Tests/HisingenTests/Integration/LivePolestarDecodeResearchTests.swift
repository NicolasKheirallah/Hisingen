#if SWIFT_PACKAGE
import Foundation
import Testing
@testable import Hisingen

private let decodeResearchEnabled = ProcessInfo.processInfo.environment["HISINGEN_ENABLE_DECODE_READS"] == "1"

@MainActor
struct LivePolestarDecodeResearchTests {
    @Test(.disabled(if: !decodeResearchEnabled, "Explicit read-only decoding research opt-in required"))
    func captureBatteryClimateAndCapabilities() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["HISINGEN_TEST_EMAIL"], !email.isEmpty,
              let password = env["HISINGEN_TEST_PASSWORD"], !password.isEmpty,
              let path = env["HISINGEN_RAW_CAPTURE_DIR"], !path.isEmpty else {
            Issue.record("Read-only research credentials or output directory missing")
            return
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.decode-research.\(UUID())")
        let suite = "io.kheirallah.hisingen.decode-research.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Could not create isolated research preferences")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = PolestarAPI(keychain: keychain, preferences: PreferencesStore(defaults: defaults),
                              diagnosticLog: APIDiagnosticLogStore())
        do {
            try await api.authenticate(email: email, password: password,
                                       preferredVIN: env["HISINGEN_TEST_VIN"],
                                       features: FeatureSelection(enabled: []))
            guard let vin = await api.resolvedVIN(preferred: env["HISINGEN_TEST_VIN"]) else {
                throw PolestarError.invalidResponse(operation: "decode research vehicle discovery")
            }
            try await api.captureDecodeResearchReads(vin: vin, directory: directory,
                                                     schemaOnly: env["HISINGEN_DECODE_SCHEMA_ONLY"] == "1")
            try await api.signOut()
        } catch {
            try? await api.signOut()
            let file = directory.appendingPathComponent("capture.error.txt")
            try DiagnosticRedaction.redact(String(describing: error)).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            Issue.record("Read-only capture failed; details are in the private output directory")
        }
    }
}

private extension PolestarAPI {
    func captureDecodeResearchReads(vin: String, directory: URL, schemaOnly: Bool) async throws {
        guard let token = accessToken else { throw PolestarError.invalidResponse(operation: "decode research session") }
        let request = Protobuf.stringField(1, UUID().uuidString) + Protobuf.stringField(2, vin)
        let reads = schemaOnly ? [
            ("reflection-v1", "/grpc.reflection.v1.ServerReflection/ServerReflectionInfo"),
            ("reflection-v1alpha", "/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo")
        ] : [
            ("mycars", "/car_information.CarInformation/GetMyCars"),
            ("battery", "/services.vehiclestates.battery.BatteryService/GetLatestBattery"),
            ("climate", "/services.vehiclestates.parkingclimatization.ParkingClimatizationService/GetLatestParkingClimatization"),
            ("availability", "/services.vehiclestates.availability.AvailabilityService/GetLatestAvailability")
        ]
        var statuses: [String: String] = [:]
        for (name, path) in reads {
            do {
                let body = schemaOnly ? Protobuf.stringField(4, "car_information.CarInformation") : request
                let bytes = try await grpc.firstMessage(path: path, message: body, vin: vin, accessToken: token)
                let file = directory.appendingPathComponent(name + ".protobuf")
                try bytes.write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                statuses[name] = "captured"
            } catch {
                let file = directory.appendingPathComponent(name + ".error.txt")
                try DiagnosticRedaction.redact(String(describing: error)).write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                statuses[name] = "failed"
                if Self.isGlobalFailure(error) { throw error }
            }
        }
        let file = directory.appendingPathComponent(schemaOnly ? "schema-status.json" : "status.json")
        try JSONEncoder().encode(statuses).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
#endif
