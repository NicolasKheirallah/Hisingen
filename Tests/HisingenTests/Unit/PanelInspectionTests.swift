import AppKit
import SwiftUI
import Testing
@testable import Hisingen

@Suite(.serialized)
@MainActor
struct PanelInspectionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HISINGEN_PANEL_RENDERS"] != nil))
    func renderProductionPanel() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["HISINGEN_PANEL_RENDERS"])
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "io.kheirallah.hisingen.tests.panel.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = KeychainStore(service: suite)
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        preferences.hasSeenFirstLaunchWelcome = true
        preferences.activeBrand = .polestar
        preferences.vehicleLabelFormat = .modelOnly
        preferences.features = FeatureSelection(
            enabled: preferences.features.enabled.union([.remoteLocks, .remoteClimate, .remoteCharging, .remoteSchedules,
                                                         .remoteWindows, .remoteHonkFlash, .remotePreCleaning])
        )
        let database = VehicleDatabase.inMemory()
        let vin = "YSMTEST"
        let now = Date()
        let art = try environment["HISINGEN_PANEL_ARTWORK"].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        var reading = vehicle(
            vin: vin, battery: 72, rangeKm: 308, target: 90, odometerKm: 28416,
            exteriorStatus: ExteriorSnapshot(openings: [], isLocked: true, alarmTriggered: false),
            weather: VehicleWeather(temperatureCelsius: 3.3, condition: "Overcast",
                                    apparentTemperatureCelsius: 0.4, relativeHumidity: 98,
                                    timestamp: now.addingTimeInterval(-1_200)),
            reportedBatteryCapacityKwh: 78, imageData: art, fetchedAt: now, reportedAt: now
        )
        reading.climateStatus = VehicleClimateStatus(
            activity: .idle, timeRemainingMinutes: nil, timerTriggered: false,
            interiorTemperatureCelsius: nil, requestedTemperatureCelsius: nil,
            driverSeatHeatingLevel: nil, passengerSeatHeatingLevel: nil, steeringWheelHeatingLevel: nil
        )
        reading.energy.currentLimitAmps = 16
        reading.climateTimers = [VehicleSchedule(
            kind: .climate, startHour: nil, startMinute: nil, endHour: nil, endMinute: nil,
            isActive: true, oneShotDate: now.addingTimeInterval(12 * 3_600)
        )]
        for (day, start, end) in [(4, 22.0, 78.0), (12, 44.0, 86.0), (16, 35.0, 71.0), (21, 19.0, 90.0)] {
            let began = now.addingTimeInterval(Double(-day) * 86_400)
            let id = database.charging.startChargingSession(vin: vin, startSoc: start, startedAt: began)
            database.charging.completeChargingSession(
                id: id, endSoc: end, energyDeliveredKwh: (end - start) * 0.78,
                peakPowerKw: 11, averagePowerKw: 9, endedAt: began.addingTimeInterval(4 * 3_600)
            )
        }

        let shared = PreferencesStore.shared
        let originalSize = shared.panelSize
        let originalTheme = shared.appTheme
        let originalCustomSize = shared.customPanelSizeEnabled
        shared.appTheme = .polestar
        shared.customPanelSizeEnabled = false
        defer {
            shared.panelSize = originalSize
            shared.appTheme = originalTheme
            shared.customPanelSizeEnabled = originalCustomSize
        }

        let account = AccountConnectionModel(preferences: preferences, keychain: keychain, builtinCredentials: .init())
        let history = HistoryWorkspace(database: database, preferences: preferences)
        let cache = CarImageCache(database: database)
        let actions = PanelActions(
            onRefresh: {}, onSettings: {}, onClose: {}, onCheckForUpdates: {}, onOpenUpdate: {},
            onRemoteCommand: { _ in }, onSelectCar: { _ in }, onDismissCommandReceipt: { _ in },
            onSettingsChanged: { _ in }, onSignOut: {},
            onTestConnection: { _ in ConnectionCheck(success: false, message: "Fixture", failureKind: nil) },
            onCompleteSetup: {}
        )
        let tabs: [(String, TabRef)] = [("now", .vehicle), ("plan", .controls), ("log", .history), ("car", .info)]
        var arrangement = TabComposition()
        arrangement.setItems([.vehicleHero, .vehicleLocation, .vehicleOpenings, .vehicleTyres], for: .vehicle)
        arrangement.setItem(.vehicleHero, shown: false, on: .vehicle)
        arrangement.setItems([.controlsRoutines, .controlsReceipts, .vehicleWeather], for: .controls)
        arrangement.setItems([.historyPeriodPicker, .historyChargingSessions, .historyOverview], for: .history)
        arrangement.setItem(.historyPeriodPicker, shown: false, on: .history)
        arrangement.setItems([.infoNavBar, .infoWeather, .infoPowertrain, .infoOverview], for: .info)
        arrangement.setItem(.infoNavBar, shown: false, on: .info)
        arrangement.setItem(.infoOverview, shown: false, on: .info)
        let custom = arrangement.addCustomTab(name: "My cards")
        arrangement.setItems([.vehicleWeather, .vehicleLocation, .vehicleHero], for: custom)
        arrangement.setItem(.vehicleHero, shown: false, on: custom)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        var nowRenders: [Data] = []
        for (size, type, name) in [
            (PanelSize.standard, DynamicTypeSize.large, "standard"),
            (.compact, .large, "compact"),
            (.grand, .large, "grand"),
            (.compact, .accessibility5, "compact-accessibility"),
        ] {
            shared.panelSize = size
            preferences.panelSize = size
            for dark in [false, true] {
                let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
                window.appearance = appearance
                var screens = tabs
                if size == .standard {
                    screens += [("now-offline", .vehicle), ("now-active", .vehicle), ("now-limits", .vehicle), ("sign-in", .vehicle), ("sign-in-volvo", .vehicle), ("sign-in-error", .vehicle), ("settings", .settings)]
                    screens.append(("connecting", .vehicle))
                } else if size == .compact, type == .accessibility5 {
                    screens += [("sign-in", .vehicle), ("sign-in-volvo", .vehicle)]
                } else if size == .grand {
                    screens += tabs.map { ("layout-\($0.0)", $0.1) } + [("layout-custom", custom)]
                }
                for (title, tab) in screens {
                    var state = reading
                    preferences.tabComposition = title.hasPrefix("layout-") ? arrangement : .default
                    if title == "layout-plan" {
                        state.commandState.receipts = [
                            CommandReceipt(commandIdentifier: RemoteCommand.lock.identifier, issuedAt: now, command: .lock)
                        ]
                    }
                    if title == "now-offline" {
                        state.freshness.isCached = true
                        state.freshness.fetchedAt = now.addingTimeInterval(-3_600)
                        state.freshness.vehicleReportedAt = now.addingTimeInterval(-7_200)
                    }
                    let live = title == "now-active" || title == "now-limits"
                    if live {
                        state.climateStatus = VehicleClimateStatus(
                            activity: .heating, timeRemainingMinutes: 18, timerTriggered: false,
                            interiorTemperatureCelsius: nil, requestedTemperatureCelsius: nil,
                            driverSeatHeatingLevel: nil, passengerSeatHeatingLevel: nil, steeringWheelHeatingLevel: nil
                        )
                        state.energy.chargingState = .charging
                        state.energy.connection = .connected
                        state.energy.powerWatts = 7_200
                        state.energy.currentAmps = 16
                        state.freshness.readingDates = [
                            .battery: now, .range: now, .locks: now, .climateStatus: now, .charging: now
                        ]
                    }
                    preferences.nowQuickControls = title == "now-active" ? NowQuickControl.allCases
                        : title == "now-limits" ? [.climate, .chargeLimit, .currentLimit] : NowQuickControl.defaults
                    let signInRequired = title.hasPrefix("sign-in")
                    preferences.activeBrand = title == "sign-in-volvo" ? .volvo : .polestar
                    let model = PanelModel(
                        display: PanelDisplay(
                            state: signInRequired || title == "connecting" ? nil : state,
                            error: title == "sign-in-error" ? "Sign in failed. Check your Polestar ID and password." : nil,
                            signInRequired: signInRequired, activeVin: vin, fleet: FleetSnapshot(),
                            remoteCommandInProgress: false, commandBrand: .polestar, checkingForUpdates: false,
                            notificationPermission: .authorized, setupMode: false
                        ),
                        actions: actions, history: history, accountConnection: account,
                        reverseGeocoder: ReverseGeocoder(), imageCache: cache
                    )
                    let view = HisingenContentView(panel: model, selectedTab: .constant(tab))
                        .environment(\.preferencesStore, preferences)
                        .environment(\.dynamicTypeSize, type)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .defaultAppStorage(defaults)
                    let frame = NSRect(x: 0, y: 0, width: size.width, height: size.idealHeight)
                    let host = NSHostingView(rootView: view)
                    host.frame = frame
                    window.contentView = host
                    window.setContentSize(frame.size)
                    host.layoutSubtreeIfNeeded()
                    // Let startup transitions and history/art tasks settle on the AppKit run loop.
                    try await Task.sleep(for: .milliseconds(title.hasPrefix("now") ? 900 : 420))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: frame))
                    appearance.performAsCurrentDrawingAppearance {
                        host.cacheDisplay(in: frame, to: bitmap)
                    }
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: output.appendingPathComponent("\(title)-\(name)-\(dark ? "dark" : "light").png"))
                    if title == "now", name == "standard" { nowRenders.append(data) }
                    #expect(host.bounds.size == frame.size)
                }
            }
        }
        preferences.tabComposition = .default
        #expect(Set(nowRenders).count == 2, "Both appearances must produce different pixels")

        // Settings, Appearance: the Controls on Now tiles with three chosen and one blocked.
        preferences.nowQuickControls = [.climate, .locks, .windows]
        for dark in [false, true] {
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            window.appearance = appearance
            let card = SettingsAppearanceCard(
                state: reading, imageCache: cache,
                binder: PreferenceBinder(preferences: preferences, notify: { _ in }, bump: {})
            )
            .frame(width: 520)
            .environment(\.preferencesStore, preferences)
            .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: card)
            let size = host.fittingSize
            let frame = NSRect(origin: .zero, size: size)
            host.frame = frame
            window.contentView = host
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: frame))
            appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: frame, to: bitmap) }
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("settings-appearance-\(dark ? "dark" : "light").png"))
        }

        // The theme editor, with colours that need adjusting: a mid-grey light background and a
        // yellow accent that vanishes on white.
        let draft = CustomThemeDefinition(id: "render", name: "Fjord", accentHex: "#FFD400",
                                          lightBackgroundHex: "#9AA5B1", darkBackgroundHex: "#0B1E33")
        for dark in [false, true] {
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            window.appearance = appearance
            let editor = CustomThemeEditor(definition: draft, isNew: true, onSave: { _ in },
                                           onDelete: nil, onCancel: {})
                .environment(\.preferencesStore, preferences)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: editor)
            let size = host.fittingSize
            let frame = NSRect(origin: .zero, size: size)
            host.frame = frame
            window.contentView = host
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: frame))
            appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: frame, to: bitmap) }
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("theme-editor-\(dark ? "dark" : "light").png"))
        }
    }
}
