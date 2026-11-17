import AppKit
import SwiftUI
import Testing
@testable import Hisingen

/// Renders the direct (Easee) charger card and its setup in the panel and settings widths, light and
/// dark. Off unless `HISINGEN_PANEL_RENDERS` names an output folder:
///
///     HISINGEN_PANEL_RENDERS=/tmp/hisingen-direct sh Scripts/test.sh --filter DirectChargingInspectionTests
@Suite(.serialized)
@MainActor
struct DirectChargingInspectionTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeModel(opMode: Int, power: String, reason: String = "0", loginStatus: Int = 200,
                           paired: Bool = true) async throws -> (HomeChargingModel, PreferencesStore, UserDefaults) {
        let suite = "io.kheirallah.hisingen.tests.direct-render.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let keychain = KeychainStore(service: suite)
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        preferences.features = FeatureSelection(enabled: [.smartChargingPlanner, .remoteCharging])
        let store = HomeChargingStore(defaults: defaults, keychain: keychain)
        try store.saveCredentials(DirectChargerCredentials(username: "owner@example.se", password: "render"), for: .easee)
        if paired {
            store.pairing = HomeChargingPairing(
                baseURL: "", chargerID: "EH1", chargerName: "Garage", entities: HomeChargerEntityMap(), vin: "YSMTEST",
                locationID: "home-loc", locationAlias: "Home", timeZoneIdentifier: "Europe/Stockholm", source: .easee)
        }
        let transport = MockHomeAssistantTransport()
        transport.route({ $0.url?.path == "/api/accounts/login" }) { _ in
            loginStatus == 200 ? .json(#"{"accessToken":"AT","expiresIn":3600}"#) : .json(#"{"title":"Bad"}"#, status: loginStatus)
        }
        let rows = [(109, "\(opMode)"), (120, power), (121, "12.42"), (96, reason), (48, "16"), (250, "true")]
            .map { #"{"id":\#($0.0),"timestamp":"2026-11-10T08:00:00Z","dataType":3,"value":"\#($0.1)"}"# }
        transport.route({ ($0.url?.path ?? "").hasSuffix("/observations") }) { _ in
            .json(#"{"observations":[\#(rows.joined(separator: ","))]}"#)
        }
        transport.route("GET", "/api/sessions/", .json("[]"))
        let date = now
        let model = HomeChargingModel(
            preferences: preferences, database: VehicleDatabase.inMemory(),
            dependencies: HomeChargingModel.Dependencies(
                transport: transport, socketConnector: nil, now: { date },
                wait: { _ in try await Task.sleep(for: .seconds(3_600)) }, spotPrices: { _ in [] }, observesWake: false))
        model.start()
        for _ in 0..<300 where model.link == .connecting || model.link == .notConfigured { try await Task.sleep(for: .milliseconds(10)) }
        return (model, preferences, defaults)
    }

    private func render<V: View>(_ view: V, width: CGFloat, name: String, dark: Bool, window: NSWindow, output: URL,
                                 preferences: PreferencesStore, defaults: UserDefaults, model: HomeChargingModel) async throws {
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        window.appearance = appearance
        let host = NSHostingView(rootView: view
            .padding(16).frame(width: width).background(HisingenTheme.canvas)
            .environment(\.preferencesStore, preferences)
            .environment(\.homeCharging, model)
            .environment(\.colorScheme, dark ? .dark : .light)
            .defaultAppStorage(defaults))
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
        try data.write(to: output.appendingPathComponent("direct-\(name)-\(dark ? "dark" : "light").png"))
        #expect(size.width <= width + 0.5, "\(name) overflows its column")
        #expect(size.height > 60, "\(name) rendered nothing")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HISINGEN_PANEL_RENDERS"] != nil))
    func renderDirectStates() async throws {
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
        let fleet = FleetSnapshot(configuredVINs: ["YSMTEST"], activeState: state)

        let cards: [(String, Int, String, String, Int)] = [
            ("1-charging", 3, "7.31", "0", 200),
            ("2-waiting-for-power", 2, "0", "5", 200),
            ("3-held", 2, "0", "0", 200),
            ("4-login-rejected", 3, "7.31", "0", 400)
        ]
        for (name, opMode, power, reason, login) in cards {
            let (model, preferences, defaults) = try await makeModel(opMode: opMode, power: power, reason: reason, loginStatus: login)
            for dark in [false, true] {
                try await render(HomeChargerSection(state: state, model: model), width: width, name: "card-\(name)", dark: dark,
                                 window: window, output: output, preferences: preferences, defaults: defaults, model: model)
            }
            model.stop()
        }

        // Settings: the sign-in form, the charger choice after signing in, and a paired charger.
        let chargers = [DirectChargerSummary(id: "EH1", name: "Garage", siteName: nil, isOnline: true)]
        let binderFor = { (preferences: PreferencesStore) in PreferenceBinder(preferences: preferences, notify: { _ in }, bump: {}) }
        let (unpaired, uPrefs, uDefaults) = try await makeModel(opMode: 1, power: "0", paired: false)
        for dark in [false, true] {
            try await render(SettingsHomeChargingCard(model: unpaired, state: state, fleet: fleet, binder: binderFor(uPrefs), source: .easee),
                             width: 560, name: "settings-signin", dark: dark, window: window, output: output,
                             preferences: uPrefs, defaults: uDefaults, model: unpaired)
            try await render(SettingsHomeChargingCard(model: unpaired, state: state, fleet: fleet, binder: binderFor(uPrefs), source: .easee,
                                                      account: "owner@example.se", directChargers: chargers, directSelection: "EH1"),
                             width: 560, name: "settings-pick", dark: dark, window: window, output: output,
                             preferences: uPrefs, defaults: uDefaults, model: unpaired)
        }
        unpaired.stop()
        let (paired, pPrefs, pDefaults) = try await makeModel(opMode: 3, power: "7.31")
        for dark in [false, true] {
            try await render(SettingsHomeChargingCard(model: paired, state: state, fleet: fleet, binder: binderFor(pPrefs)),
                             width: 560, name: "settings-paired", dark: dark, window: window, output: output,
                             preferences: pPrefs, defaults: pDefaults, model: paired)
        }
        paired.stop()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HISINGEN_PANEL_RENDERS"] != nil))
    func renderTibberCard() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HISINGEN_PANEL_RENDERS"])
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let (supplier, prefs, defaults) = try await makeModel(opMode: 1, power: "0", paired: false)
        let home = TibberHome(id: "h1", name: "Villa", timeZone: nil, currency: "SEK")
        for dark in [false, true] {
            try await render(SettingsTibberCard(model: supplier, homes: [home], selection: "h1"), width: 560, name: "tibber-pick",
                             dark: dark, window: window, output: output, preferences: prefs, defaults: defaults, model: supplier)
        }
        try supplier.connectTibber(token: "t", home: home)
        for dark in [false, true] {
            try await render(SettingsTibberCard(model: supplier), width: 560, name: "tibber-connected", dark: dark,
                             window: window, output: output, preferences: prefs, defaults: defaults, model: supplier)
        }
        supplier.stop()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HISINGEN_PANEL_RENDERS"] != nil))
    func renderNexBlueSheets() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HISINGEN_PANEL_RENDERS"])
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scoped = ScopedPreferences(label: "nexblue-sheet")
        let model = HomeChargingModel(preferences: scoped.store, database: VehicleDatabase.inMemory())
        let timeZone = try #require(TimeZone(identifier: "Europe/Stockholm"))
        for dark in [false, true] {
            try await render(NexBlueTimerSheet(model: model), width: 432, name: "nexblue-timer", dark: dark,
                             window: window, output: output, preferences: scoped.store, defaults: scoped.defaults, model: model)
            try await render(NexBlueHistorySheet(model: model, timeZone: timeZone), width: 432, name: "nexblue-history", dark: dark,
                             window: window, output: output, preferences: scoped.store, defaults: scoped.defaults, model: model)
        }
    }
}
