import AppKit
import SwiftUI
import Testing
@testable import Hisingen

/// Renders the home charger section of the charging card at the panel's normal width, in every
/// state the card has, light and dark. Off unless `HISINGEN_PANEL_RENDERS` names an output folder:
///
///     HISINGEN_PANEL_RENDERS=/tmp/hisingen-home sh Scripts/test.sh --filter HomeChargingInspectionTests --no-parallel
@Suite(.serialized)
@MainActor
struct HomeChargingInspectionTests {
    private struct Scenario {
        var name: String
        var charger: (status: String, power: String, energy: String, ageSeconds: TimeInterval)
        var plan: PlanFixture?
        var unreachable = false
        var rejectSwitch = false
        var sendStart = false
    }

    private struct PlanFixture {
        var phase: String
        var hold = false
    }

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func planJSON(_ plan: PlanFixture) -> String {
        let start = HATimestamp.format(now.addingTimeInterval(3 * 3_600 + 15 * 60))
        let end = HATimestamp.format(now.addingTimeInterval(5 * 3_600 + 45 * 60))
        let deadline = HATimestamp.format(now.addingTimeInterval(8 * 3_600))
        let finish = HATimestamp.format(now.addingTimeInterval(5 * 3_600 + 45 * 60))
        return """
        {"entity_id":"\(HomeChargingPlanEntity.id(chargerID: "NX1234567"))","state":"\(plan.phase)",
         "attributes":{"plan_id":"p1","target":{"type":"reach_percent","value":80},"deadline":"\(deadline)",
         "windows":[{"start":"\(start)","end":"\(end)","avg_price":0.43}],"delivered_kwh":0.0,"remaining_kwh":14.8,
         "rate_kw":7.2,"expected_finish":"\(finish)","estimated_cost":14.6,"currency":"kr","hold":\(plan.hold),
         "override":false,"warnings":[]},
         "last_changed":"\(HATimestamp.format(now))","last_updated":"\(HATimestamp.format(now))"}
        """
    }

    private func stateJSON(_ id: String, _ state: String, unit: String? = nil, reported: Date) -> String {
        let attributes = unit.map { "{\"unit_of_measurement\":\"\($0)\"}" } ?? "{}"
        let stamp = HATimestamp.format(reported)
        return "{\"entity_id\":\"\(id)\",\"state\":\"\(state)\",\"attributes\":\(attributes),\"last_changed\":\"\(stamp)\",\"last_updated\":\"\(stamp)\",\"last_reported\":\"\(stamp)\"}"
    }

    private func makeModel(_ scenario: Scenario, output: URL) async throws -> (HomeChargingModel, PreferencesStore, UserDefaults) {
        let suite = "io.kheirallah.hisingen.tests.home-render.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let keychain = KeychainStore(service: suite)
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        preferences.features = FeatureSelection(enabled: [.smartChargingPlanner, .remoteCharging])
        let store = HomeChargingStore(defaults: defaults, keychain: keychain)
        try store.saveToken("render-token")
        store.address = "http://homeassistant.local:8123"
        store.pairing = NexBlueFixture.pairing()

        let reported = now.addingTimeInterval(-scenario.charger.ageSeconds)
        let map = NexBlueFixture.map
        let table: [String: String] = [
            map.chargingState!: stateJSON(map.chargingState!, scenario.charger.status, reported: reported),
            map.power!: stateJSON(map.power!, scenario.charger.power, unit: "kW", reported: reported),
            map.sessionEnergy!: stateJSON(map.sessionEnergy!, scenario.charger.energy, unit: "kWh", reported: reported),
            map.chargingSwitch!: stateJSON(map.chargingSwitch!, "off", reported: reported),
            map.chargingEnabled!: stateJSON(map.chargingEnabled!, "on", reported: reported),
            HomeChargingPlanEntity.id(chargerID: "NX1234567"): scenario.plan.map(planJSON) ?? ""
        ]
        let transport = MockHomeAssistantTransport()
        transport.route({ $0.httpMethod == "GET" && MockHomeAssistantTransport.encodedPath($0).hasPrefix("/api/states/") }) { request in
            let id = String(MockHomeAssistantTransport.encodedPath(request).dropFirst("/api/states/".count))
            guard let body = table[id], !body.isEmpty else { return .json("{\"message\":\"Entity not found.\"}", status: 404) }
            return .json(body)
        }
        if scenario.rejectSwitch {
            transport.route("POST", "/api/services/switch/", .text("Charger NX1234567 is offline", status: 500))
        } else {
            transport.route("POST", "/api/services/switch/", .json("[]"))
        }
        transport.route("POST", "/api/services/hisingen_home_charging/", .json("{\"message\":\"Service not found.\"}", status: 400))
        transport.route("GET", "/api/history/period/", .json("[]"))
        let date = now
        let model = HomeChargingModel(
            preferences: preferences, database: VehicleDatabase.inMemory(),
            dependencies: HomeChargingModel.Dependencies(
                transport: transport, socketConnector: nil, now: { date },
                wait: { _ in try await Task.sleep(for: .seconds(3_600)) }, spotPrices: { _ in [] }, observesWake: false))
        model.start()
        for _ in 0..<300 where model.lastContact == nil { try await Task.sleep(for: .milliseconds(10)) }
        if scenario.unreachable {
            transport.unreachable = true
            model.refreshNow()
            for _ in 0..<300 where model.link == .live { try await Task.sleep(for: .milliseconds(10)) }
        }
        if scenario.sendStart { await model.send(.start) }
        return (model, preferences, defaults)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HISINGEN_PANEL_RENDERS"] != nil))
    func renderHomeChargerStates() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HISINGEN_PANEL_RENDERS"])
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let scenarios: [Scenario] = [
            Scenario(name: "1-connected", charger: ("connected", "0", "0", 20)),
            Scenario(name: "2-charging", charger: ("charging", "7.31", "12.42", 20), plan: PlanFixture(phase: "charging")),
            Scenario(name: "3-scheduled", charger: ("connected", "0", "0", 20), plan: PlanFixture(phase: "scheduled")),
            Scenario(name: "4-waiting-for-power", charger: ("lb_waiting", "0", "3.2", 20), plan: PlanFixture(phase: "waiting_for_power")),
            Scenario(name: "5-unavailable", charger: ("charging", "7.31", "12.42", 3_600), unreachable: true),
            Scenario(name: "6-error-rejected", charger: ("connected", "0", "0", 20), rejectSwitch: true, sendStart: true),
            Scenario(name: "7-paused-plan", charger: ("connected", "0", "5.1", 20), plan: PlanFixture(phase: "holding", hold: true)),
            Scenario(name: "8-pending-command", charger: ("connected", "0", "0", 20), sendStart: true)
        ]

        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let layout = PanelLayout.resolve(from: PreferencesStore.shared)
        let width = layout.width

        for scenario in scenarios {
            let (model, preferences, defaults) = try await makeModel(scenario, output: output)
            var state = vehicle(vin: "YSMTEST", battery: 62, connection: .connected, target: 80)
            state.identity.modelName = "Polestar 2"
            state.chargeLocationPresence = ChargeLocationPresence(locationID: "home-loc", alias: "Home", since: nil, source: .proximity)
            for dark in [false, true] {
                let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
                window.appearance = appearance
                let view = HomeChargerSection(state: state, model: model)
                    .padding(16)
                    .frame(width: width)
                    .background(HisingenTheme.canvas)
                    .environment(\.preferencesStore, preferences)
                    .environment(\.homeCharging, model)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .defaultAppStorage(defaults)
                let host = NSHostingView(rootView: view)
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
                try data.write(to: output.appendingPathComponent("home-\(scenario.name)-\(dark ? "dark" : "light").png"))
                #expect(frame.width == width)
                // The section must not overflow the panel's width or collapse to nothing.
                #expect(size.width <= width + 0.5, "\(scenario.name) overflows the panel width")
                #expect(size.height > 60, "\(scenario.name) rendered no card")
            }
            model.stop()
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HISINGEN_PANEL_RENDERS"] != nil))
    func renderSettingsCard() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HISINGEN_PANEL_RENDERS"])
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        var state = vehicle(vin: "YSMTEST", battery: 62, connection: .connected, target: 80)
        state.identity.modelName = "Polestar 2"
        let fleet = FleetSnapshot(configuredVINs: ["YSMTEST"], activeState: state)

        for (name, paired) in [("unpaired", false), ("paired", true)] {
            let scenario = Scenario(name: name, charger: ("charging", "7.31", "12.42", 20), plan: PlanFixture(phase: "charging"))
            let (model, preferences, defaults) = try await makeModel(scenario, output: output)
            if !paired { model.unpair() }
            for dark in [false, true] {
                let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
                window.appearance = appearance
                let binder = PreferenceBinder(preferences: preferences, notify: { _ in }, bump: {})
                let view = SettingsHomeChargingCard(model: model, state: state, fleet: fleet, binder: binder)
                    .padding(16)
                    .frame(width: 560)
                    .background(HisingenTheme.canvas)
                    .environment(\.preferencesStore, preferences)
                    .environment(\.homeCharging, model)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .defaultAppStorage(defaults)
                let host = NSHostingView(rootView: view)
                let size = host.fittingSize
                let frame = NSRect(origin: .zero, size: NSSize(width: 560, height: max(size.height, 80)))
                host.frame = frame
                window.contentView = host
                window.setContentSize(frame.size)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: frame))
                appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: frame, to: bitmap) }
                let data = try #require(bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]))
                try data.write(to: output.appendingPathComponent("settings-home-\(name)-\(dark ? "dark" : "light").png"))
                #expect(size.width <= 560.5, "\(name) overflows the settings column")
            }
            model.stop()
        }
    }
}
