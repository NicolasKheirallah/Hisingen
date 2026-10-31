#if SWIFT_PACKAGE
import Foundation
import Testing
@testable import Hisingen

private let trailerCaptureEnabled = ProcessInfo.processInfo.environment["HISINGEN_ENABLE_TRAILER_CAPTURE"] == "1"

@MainActor
struct LivePolestarTrailerCaptureTests {
    @Test(.disabled(if: !trailerCaptureEnabled, "Explicit read-only trailer capture opt-in required"))
    func captureLatestReads() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let email = environment["HISINGEN_TEST_EMAIL"], !email.isEmpty,
              let password = environment["HISINGEN_TEST_PASSWORD"], !password.isEmpty,
              let requestedVIN = environment["HISINGEN_TEST_VIN"], !requestedVIN.isEmpty,
              let outputPath = environment["HISINGEN_TRAILER_CAPTURE_DIR"], !outputPath.isEmpty else {
            Issue.record("Read-only capture configuration is incomplete")
            return
        }
        let directory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let identifier = UUID().uuidString
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.trailer-capture.\(identifier)")
        let suite = "io.kheirallah.hisingen.trailer-capture.\(identifier)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Could not create isolated capture preferences")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let diagnostics = APIDiagnosticLogStore()
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        let api = PolestarAPI(keychain: keychain, preferences: preferences, diagnosticLog: diagnostics)
        let grpc = PolestarGRPC(defaultsSuiteName: suite, diagnosticLog: diagnostics,
                                transport: PolestarHTTP2Transport(timeout: .seconds(15)))
        var failed = false
        do {
            try await api.authenticate(email: email, password: password, preferredVIN: requestedVIN,
                                       features: FeatureSelection(enabled: []))
            guard await api.resolvedVIN(preferred: requestedVIN) == requestedVIN else {
                throw PolestarError.invalidResponse(operation: "capture vehicle selection")
            }
            let identity = await api.identity(for: requestedVIN)
            guard identity.modelYear == "2023", identity.modelName?.localizedCaseInsensitiveContains("polestar 2") == true,
                  let token = await api.captureAccessToken() else {
                throw PolestarError.invalidResponse(operation: "capture vehicle identity")
            }
            let reads: [(String, String, Data)] = [
                ("battery", "/services.vehiclestates.battery.BatteryService/GetLatestBattery",
                 PolestarGRPC.stateRequest(vin: requestedVIN)),
                ("location", "/dtlinternet.DtlInternetService/GetLastKnownLocation",
                 Protobuf.stringField(1, requestedVIN)),
                ("weather", "/weather.WeatherService/GetWeatherReport",
                 Protobuf.stringField(1, requestedVIN))
            ]
            for (name, path, request) in reads {
                do {
                    let response = try await grpc.firstMessage(path: path, message: request,
                                                               vin: requestedVIN, accessToken: token)
                    try writePrivate(response, to: directory.appendingPathComponent(name + ".protobuf"))
                } catch {
                    failed = true
                    try writePrivate(Data(DiagnosticRedaction.redact(String(describing: error)).utf8),
                                     to: directory.appendingPathComponent(name + ".error.txt"))
                    if error is CancellationError { break }
                }
            }
        } catch {
            failed = true
            try? writePrivate(Data(DiagnosticRedaction.redact(String(describing: error)).utf8),
                              to: directory.appendingPathComponent("capture.error.txt"))
        }
        do { try await api.signOut() }
        catch {
            failed = true
            try? writePrivate(Data(DiagnosticRedaction.redact(String(describing: error)).utf8),
                              to: directory.appendingPathComponent("signout.error.txt"))
        }
        do {
            let snapshot = await diagnostics.snapshot()
            try writePrivate(try JSONEncoder().encode(snapshot),
                             to: directory.appendingPathComponent("diagnostics.json"))
        } catch { failed = true }
        if failed { Issue.record("Read-only capture failed; details are in the private output directory") }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        if !manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) {
            throw CocoaError(.fileWriteUnknown)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: 0)
        try file.write(contentsOf: data)
    }
}

private extension PolestarAPI {
    func captureAccessToken() -> String? { accessToken }
}
#endif
