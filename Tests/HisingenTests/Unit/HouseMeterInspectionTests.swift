import AppKit
import SwiftUI
import Testing
@testable import Hisingen

/// Renders the house meter on the charger card and its Settings card in the panel and settings
/// widths, light and dark. Off unless `HISINGEN_PANEL_RENDERS` names an output folder:
///
///     HISINGEN_PANEL_RENDERS=/tmp/hisingen-meter sh Scripts/test.sh --filter HouseMeterInspectionTests
@Suite(.serialized)
@MainActor
struct HouseMeterInspectionTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private struct Harness {
        var model: HomeChargingModel
        var preferences: PreferencesStore
        var defaults: UserDefaults
        var transport: MockHomeAssistantTransport
    }

    /// An Easee charger drawing `carKw` and a Perific monitor whose packets are `packetAge` seconds old.
    private func makeHarness(carKw: String, packetAge: TimeInterval = 10, connectMeter: Bool = true) async throws -> Harness {
        let suite = "io.kheirallah.hisingen.tests.meter-render.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let keychain = KeychainStore(service: suite)
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        preferences.features = FeatureSelection(enabled: [.smartChargingPlanner, .remoteCharging])
        let store = HomeChargingStore(defaults: defaults, keychain: keychain)
        try store.saveCredentials(DirectChargerCredentials(username: "owner@example.se", password: "render"), for: .easee)
        store.pairing = HomeChargingPairing(
            baseURL: "", chargerID: "EH1", chargerName: "Garage", entities: HomeChargerEntityMap(), vin: "YSMTEST",
            locationID: "home-loc", locationAlias: "Home", timeZoneIdentifier: "Europe/Stockholm", source: .easee)

        let transport = MockHomeAssistantTransport()
        transport.route({ $0.url?.path == "/api/accounts/login" }) { _ in .json(#"{"accessToken":"AT","expiresIn":3600}"#) }
        let rows = [(109, "3"), (120, carKw), (121, "12.42"), (96, "0"), (48, "16"), (250, "true")]
            .map { #"{"id":\#($0.0),"timestamp":"2026-11-10T08:00:00Z","dataType":3,"value":"\#($0.1)"}"# }
        transport.route({ ($0.url?.path ?? "").hasSuffix("/observations") }) { _ in .json(#"{"observations":[\#(rows.joined(separator: ","))]}"#) }
        transport.route("GET", "/api/sessions/", .json("[]"))

        let ms = Int(now.addingTimeInterval(-packetAge).timeIntervalSince1970 * 1_000)
        transport.route("PUT", "/createtoken", .json(
            #"{"TokenInfo":{"Token":"TK","Created":"2026-11-18T10:36:29.7829322Z","ValidTo":"2027-11-18T10:36:29.7829323Z"}}"#))
        transport.route("GET", "/getaccountoverview", .json(
            #"{"Items":[{"ItemId":1762080000000,"ItemType":"Phase","Name":"Huset","TimeZone":"Europe/Stockholm"}]}"#))
        transport.route({ $0.url?.path == "/getlatestpackets" }) { _ in
            .json(#"[{"ItemId":1762080000000,"LatestPackets":{"PhaseRealTime":{"ts":\#(ms),"data":{"hiavg":[4.8,5.4,4.6],"huavg":[227.3,229,229.3]}},"PhaseMinute":null}}]"#)
        }
        transport.route("PUT", "/getphasedata", .json(
            #"[{"dt":"x","data":[{"ts":"2026-05-28T01:00:00","data":{"hwi":100.0,"hwo":0}},{"ts":"2026-05-28T22:00:00","data":{"hwi":109.5,"hwo":0}}]}]"#))

        let date = now
        let model = HomeChargingModel(
            preferences: preferences, database: VehicleDatabase.inMemory(),
            dependencies: HomeChargingModel.Dependencies(
                transport: transport, socketConnector: nil, now: { date },
                wait: { _ in try await Task.sleep(for: .seconds(3_600)) }, spotPrices: { _ in [] }, observesWake: false))
        model.start()
        for _ in 0..<300 where model.link == .connecting || model.link == .notConfigured { try await Task.sleep(for: .milliseconds(10)) }
        if connectMeter {
            let meters = try await model.houseMeter.connect(credentials: DirectChargerCredentials(username: "owner@example.se", password: "render"))
            model.houseMeter.select(try #require(meters.first))
            for _ in 0..<300 where model.houseMeter.link == .connecting { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(100))
        }
        return Harness(model: model, preferences: preferences, defaults: defaults, transport: transport)
    }

    private func render<V: View>(_ view: V, width: CGFloat, name: String, dark: Bool, window: NSWindow, output: URL,
                                 harness: Harness) async throws {
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        window.appearance = appearance
        let host = NSHostingView(rootView: view
            .padding(16).frame(width: width).background(HisingenTheme.canvas)
            .environment(\.preferencesStore, harness.preferences)
            .environment(\.homeCharging, harness.model)
            .environment(\.colorScheme, dark ? .dark : .light)
            .defaultAppStorage(harness.defaults))
        let size = host.fittingSize
        let frame = NSRect(origin: .zero, size: NSSize(width: width, height: max(size.height, 60)))
        host.frame = frame
        window.contentView = host
        window.setContentSize(frame.size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: frame))
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: frame, to: bitmap) }
        let data = try #require(bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]))
        try data.write(to: output.appendingPathComponent("meter-\(name)-\(dark ? "dark" : "light").png"))
        #expect(size.width <= width + 0.5, "\(name) overflows its column")
        #expect(size.height > 60, "\(name) rendered nothing")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HISINGEN_PANEL_RENDERS"] != nil))
    func renderHouseMeterStates() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HISINGEN_PANEL_RENDERS"])
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let width = PanelLayout.resolve(from: PreferencesStore.shared).width

        var state = vehicle(vin: "YSMTEST", battery: 62, connection: .connected, target: 80)
        state.identity.modelName = "Polestar 2"
        state.chargeLocationPresence = ChargeLocationPresence(locationID: "home-loc", alias: "Home", since: nil, source: .proximity)

        // The card: car and house both live, so it splits; then the meter reading gone stale.
        for (name, age) in [("card-split", 10.0), ("card-stale", 900.0)] {
            let harness = try await makeHarness(carKw: "2.3", packetAge: age)
            for dark in [false, true] {
                try await render(HomeChargerSection(state: state, model: harness.model), width: width, name: name, dark: dark,
                                 window: window, output: output, harness: harness)
            }
            harness.model.stop(); harness.model.houseMeter.stop()
        }

        // Settings: signing in, connected and reading, and a login Perific stopped accepting.
        let setup = try await makeHarness(carKw: "0", connectMeter: false)
        let live = try await makeHarness(carKw: "0")
        let refused = try await makeHarness(carKw: "0")
        for dark in [false, true] {
            try await render(SettingsHouseMeterCard(meter: setup.model.houseMeter), width: 560, name: "settings-signin",
                             dark: dark, window: window, output: output, harness: setup)
            try await render(SettingsHouseMeterCard(meter: live.model.houseMeter), width: 560, name: "settings-connected",
                             dark: dark, window: window, output: output, harness: live)
        }
        // Perific stops accepting the saved login: the card asks for it again.
        refused.transport.route("PUT", "/createtoken", .json("{}", status: 401))
        refused.transport.route("PUT", "/getlatestpackets", .json("{}", status: 401))
        refused.model.houseMeter.refreshNow()
        for _ in 0..<300 where refused.model.houseMeter.link != .unauthorized { try await Task.sleep(for: .milliseconds(10)) }
        #expect(refused.model.houseMeter.link == .unauthorized)
        for dark in [false, true] {
            try await render(SettingsHouseMeterCard(meter: refused.model.houseMeter), width: 560, name: "settings-live-again",
                             dark: dark, window: window, output: output, harness: refused)
        }
        for harness in [setup, live, refused] { harness.model.stop(); harness.model.houseMeter.stop() }
    }
}
