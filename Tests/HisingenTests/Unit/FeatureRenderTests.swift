import AppKit
import SwiftUI
import Testing
@testable import Hisingen

/// Renders the weather-driven views with sample data so a changelog or document can show them.
/// Off unless `HISINGEN_FEATURE_RENDERS` names an output folder, the same arrangement as
/// `PanelInspectionTests`. Every figure is invented for the render: the position, the forecast,
/// the trips and the tyre pressures are fixtures, and the air-quality answer is seeded into the
/// in-memory cache so nothing is requested from the network.
@Suite(.serialized)
@MainActor
struct FeatureRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HISINGEN_FEATURE_RENDERS"] != nil))
    func renderWeatherFeatures() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HISINGEN_FEATURE_RENDERS"])
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let suite = "io.kheirallah.hisingen.tests.features.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = KeychainStore(service: suite)
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        preferences.activeBrand = .polestar
        preferences.features = FeatureSelection(
            enabled: preferences.features.enabled.union([.vehicleWeather, .tyreAndWarnings]))

        let database = VehicleDatabase.inMemory()
        let vin = "YSMTEST"
        let now = Date()
        seedTrips(into: database, vin: vin, now: now)
        let history = HistoryWorkspace(database: database, preferences: preferences)

        // Air quality is asked of the network in the app; here the cache already holds the answer.
        let position = (latitude: 57.7089, longitude: 11.9746)
        let airURL = try #require(OutdoorAirQualityClient.url(latitude: position.latitude, longitude: position.longitude))
        _ = await OutdoorAirQualityCache.shared.reading(for: airURL.absoluteString, now: now) {
            OutdoorAirQuality(europeanAQI: 32, particulateMatter25: 8.4)
        }

        // The next 07:30, so every scenario reads as the morning commute.
        let calendar = Calendar.current
        let departure = try #require(calendar.nextDate(
            after: now, matching: DateComponents(hour: 7, minute: 30), matchingPolicy: .nextTime))
        let hourStart = try #require(calendar.date(bySetting: .minute, value: 0, of: departure))
        let schedule = VehicleSchedule(
            kind: .departure, startHour: 7, startMinute: 30, endHour: nil, endMinute: nil,
            weekdays: VehicleWeekday.allCases, isActive: true)

        func state(currentCelsius: Double, condition: String, rangeKm: Int, humidity: Int,
                   forecast: HourlyTemperature, withPosition: Bool = false) -> VehicleState {
            var reading = vehicle(
                vin: vin, battery: 72, rangeKm: rangeKm, target: 90, odometerKm: 28_416,
                weather: VehicleWeather(
                    temperatureCelsius: currentCelsius, condition: condition,
                    apparentTemperatureCelsius: currentCelsius < 10 ? currentCelsius - 3 : currentCelsius,
                    relativeHumidity: humidity,
                    windSpeedKmh: 14, windGustsKmh: 22, precipitationMm: 0,
                    timestamp: now.addingTimeInterval(-600), hourlyTemperatures: [forecast]),
                location: withPosition
                    ? VehicleLocation(latitude: position.latitude, longitude: position.longitude) : nil,
                reportedBatteryCapacityKwh: 78, fetchedAt: now, reportedAt: now)
            reading.energy.schedules = [schedule]
            return reading
        }

        let scenarios: [(String, VehicleState)] = [
            ("weather-icy-roads", state(
                currentCelsius: 2, condition: "Overcast", rangeKm: 300, humidity: 94,
                forecast: HourlyTemperature(time: hourStart, temperatureCelsius: -1,
                                            precipitationMm: 0.4, weatherCode: 61))),
            ("weather-snow", state(
                currentCelsius: -1, condition: "Snow", rangeKm: 300, humidity: 92,
                forecast: HourlyTemperature(time: hourStart, temperatureCelsius: -4,
                                            precipitationMm: 0.6, snowfallCm: 0.8, weatherCode: 71))),
            ("weather-heat", state(
                currentCelsius: 24, condition: "Clear", rangeKm: 340, humidity: 40,
                forecast: HourlyTemperature(time: hourStart, temperatureCelsius: 31))),
            ("weather-range-and-air", state(
                currentCelsius: 5, condition: "Overcast", rangeKm: 300, humidity: 88,
                forecast: HourlyTemperature(time: hourStart, temperatureCelsius: -5), withPosition: true)),
        ]

        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        for (name, scenario) in scenarios {
            for dark in [false, true] {
                // Trips and a position are only supplied where the shot is about the range line and
                // the air-quality row, so the other shots show their own advice line alone.
                let showsHistoryAndAir = name == "weather-range-and-air"
                let view = NowWeatherReadout(state: scenario)
                    .frame(width: 310)
                    .padding(16)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.preferencesStore, preferences)
                    .environment(\.historyWorkspace, showsHistoryAndAir ? history : nil)
                    .environment(\.colorScheme, dark ? .dark : .light)
                try await write(view, named: dark ? "\(name)-dark" : name, dark: dark,
                                window: window, output: output, settle: .milliseconds(1_200))
            }
        }

        let tyres = [
            TyrePressure(position: .frontLeft, kilopascals: 232, warning: .none, referenceKilopascals: 250),
            TyrePressure(position: .frontRight, kilopascals: 231, warning: .none, referenceKilopascals: 250),
            TyrePressure(position: .rearLeft, kilopascals: 238, warning: .none, referenceKilopascals: 250),
            TyrePressure(position: .rearRight, kilopascals: 239, warning: .none, referenceKilopascals: 250),
        ]
        for dark in [false, true] {
            let view = TireStatusCardView(tyres: tyres, model: nil, ambientCelsius: -10)
                .frame(width: 380)
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.preferencesStore, preferences)
                .environment(\.colorScheme, dark ? .dark : .light)
            try await write(view, named: dark ? "tyres-cold-dark" : "tyres-cold", dark: dark,
                            window: window, output: output, settle: .milliseconds(300))
        }
    }

    /// Twenty electric trips on the line consumption = 20 - 0.5 x temperature, spread over -5 to
    /// 20 °C, so the car's own history can back a range estimate. Each trip is two telemetry rows
    /// ten minutes apart, days apart from the next trip.
    private func seedTrips(into database: VehicleDatabase, vin: String, now: Date) {
        for index in 0..<20 {
            let temperature = -5 + 25 * Double(index) / 19
            let consumption = 20 - 0.5 * temperature
            let start = now.addingTimeInterval(-Double(index + 1) * 2 * 86_400)
            let base = 20_000 + Double(index) * 24
            for step in 0..<2 {
                _ = database.history.recordTelemetry(
                    vin: vin, odometerKm: base + Double(step) * 12, tripManualKm: nil, tripAutoKm: nil,
                    avgConsumption: consumption, consumptionUnit: "kwh", ambientTempC: temperature,
                    latitude: nil, longitude: nil,
                    timestamp: start.addingTimeInterval(Double(step) * 600))
            }
        }
    }

    private func write<V: View>(_ view: V, named name: String, dark: Bool, window: NSWindow,
                                output: URL, settle: Duration) async throws {
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        window.appearance = appearance
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let frame = NSRect(origin: .zero, size: size)
        host.frame = frame
        window.contentView = host
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: settle)
        // The range line and the air-quality row arrive after the first layout.
        let settled = host.fittingSize
        let finalFrame = NSRect(origin: .zero, size: settled)
        host.frame = finalFrame
        window.setContentSize(settled)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: finalFrame))
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: finalFrame, to: bitmap) }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent("\(name).png"))
    }
}
