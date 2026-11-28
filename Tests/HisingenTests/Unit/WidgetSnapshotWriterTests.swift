import Foundation
import HisingenIntents
import Testing
@testable import Hisingen

/// The app side of the widget snapshot: which display values a completed refresh publishes.
/// The wire round trip with the widget target's reader lives in HisingenWidgetTests
/// (a separate test target that imports both binaries).
@Suite("Widget snapshot writer")
@MainActor
struct WidgetSnapshotWriterTests {
    /// A UUID-scoped preferences domain, mirroring the app suite's ScopedPreferences
    /// discipline without depending on that file (it belongs to the other test target).
    private final class ScopedDefaults {
        nonisolated(unsafe) let defaults: UserDefaults
        let keychain: KeychainStore
        private let suiteName: String

        init() {
            suiteName = "WidgetSnapshotWriterTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        }

        deinit { defaults.removePersistentDomain(forName: suiteName) }

        @MainActor func preferences() -> PreferencesStore {
            PreferencesStore(defaults: defaults, keychain: keychain)
        }
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)

    private func fixtureState(
        vin: String = "YSMWIDGET01",
        battery: Double? = 78.4,
        rangeKm: Int? = 213,
        charging: ChargingState = .charging,
        schedules: [VehicleSchedule] = [],
        fetchedAt: Date
    ) -> VehicleState {
        var energy = EnergyAndChargingSnapshot(
            batteryPercentage: battery, rangeKm: rangeKm, chargingState: charging)
        energy.schedules = schedules
        return VehicleState(
            energy: energy,
            identity: VehicleIdentitySnapshot(
                availability: .available, modelName: "Polestar 2", modelYear: "2023", vin: vin),
            freshness: SnapshotFreshness(isCached: false, fetchedAt: fetchedAt)
        )
    }

    @Test("battery, range and charging publish as the app's own surfaces format them")
    func displayValuesFollowAppFormatters() throws {
        let preferences = PreferencesStore(defaults: ScopedDefaults().defaults)
        let snapshot = WidgetSnapshotWriter.snapshot(
            from: fixtureState(fetchedAt: fixedNow), preferences: preferences, now: fixedNow)

        #expect(snapshot.schemaVersion == VehicleWidgetSnapshot.currentSchemaVersion)
        #expect(snapshot.vin == "YSMWIDGET01")
        #expect(snapshot.name == "Polestar 2 · 2023")
        #expect(snapshot.batteryText == "78%")
        #expect(snapshot.rangeText == "213 km")
        #expect(snapshot.chargingKind == "charging")
        #expect(snapshot.chargingText == "Charging")
        #expect(snapshot.departureText == nil)
        #expect(snapshot.fetchedAt == fixedNow)
        #expect(snapshot.writtenAt == fixedNow)
        #expect(snapshot.languageCode == nil)
    }

    @Test("privacy redaction publishes the model name only")
    func redactedTitleDropsRegistrationAndNickname() {
        let defaults = ScopedDefaults().defaults
        let preferences = PreferencesStore(defaults: defaults)
        preferences.privacyRedactionEnabled = true

        let state = fixtureState(fetchedAt: fixedNow)
        var identity = state.identity
        identity.registrationNo = "ABC123"
        var redacted = state
        redacted.identity = identity

        let snapshot = WidgetSnapshotWriter.snapshot(
            from: redacted, preferences: preferences, now: fixedNow)
        #expect(snapshot.name == "Polestar 2")
    }

    @Test("the reader's distance unit converts the range text")
    func milesReaderSeesMiles() {
        let preferences = PreferencesStore(defaults: ScopedDefaults().defaults)
        preferences.distanceUnit = .miles

        let snapshot = WidgetSnapshotWriter.snapshot(
            from: fixtureState(fetchedAt: fixedNow), preferences: preferences, now: fixedNow)
        #expect(snapshot.rangeText == "132 mi")
    }

    @Test("a chosen interface language travels with the snapshot")
    func languageChoiceTravels() {
        let preferences = PreferencesStore(defaults: ScopedDefaults().defaults)
        preferences.interfaceLanguage = .swedish

        let snapshot = WidgetSnapshotWriter.snapshot(
            from: fixtureState(fetchedAt: fixedNow), preferences: preferences, now: fixedNow)
        #expect(snapshot.languageCode == "sv")
    }

    @Test("every charging state maps to one stable token")
    func chargingTokensAreStable() {
        let pairs: [(ChargingState, String)] = [
            (.charging, "charging"), (.smartCharging, "smartCharging"), (.paused, "paused"),
            (.scheduled, "scheduled"), (.idle, "idle"), (.complete, "complete"),
            (.discharging, "discharging"), (.fault, "fault"), (.unknown("ODD_TOKEN"), "unknown"),
        ]
        for (state, token) in pairs {
            let snapshot = WidgetSnapshotWriter.snapshot(
                from: fixtureState(charging: state, fetchedAt: fixedNow),
                preferences: PreferencesStore(defaults: ScopedDefaults().defaults),
                now: fixedNow)
            #expect(snapshot.chargingKind == token)
        }
    }

    @Test("today's departure publishes as a clock time; a later day keeps its date")
    func departureTextFollowsTheDay() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 15
        components.hour = 12
        let noon = try #require(Calendar.current.date(from: components))
        var evening = components
        evening.hour = 19; evening.minute = 30
        let today = try #require(Calendar.current.date(from: evening))

        let departure = VehicleSchedule(
            kind: .departure, startHour: 19, startMinute: 30, endHour: nil, endMinute: nil,
            weekdays: [], isActive: true, oneShotDate: today)
        let state = fixtureState(schedules: [departure], fetchedAt: noon)
        let preferences = PreferencesStore(defaults: ScopedDefaults().defaults)

        let todaySnapshot = WidgetSnapshotWriter.snapshot(from: state, preferences: preferences, now: noon)
        #expect(todaySnapshot.departureText == Format.shortTime(date: today))

        let tomorrow = today.addingTimeInterval(86_400)
        var nextDayState = state
        nextDayState.energy.schedules = [
            VehicleSchedule(kind: .departure, startHour: 19, startMinute: 30, endHour: nil,
                            endMinute: nil, weekdays: [], isActive: true, oneShotDate: tomorrow)
        ]
        let nextDaySnapshot = WidgetSnapshotWriter.snapshot(
            from: nextDayState, preferences: preferences, now: noon)
        #expect(nextDaySnapshot.departureText != Format.shortTime(date: tomorrow))
        #expect(nextDaySnapshot.departureText?.contains("·") == true)
    }

    @Test("the write is atomic and decodes back unchanged")
    func writeDecodesBack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hisingen-widget-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let preferences = PreferencesStore(defaults: ScopedDefaults().defaults)
        let snapshot = WidgetSnapshotWriter.snapshot(
            from: fixtureState(fetchedAt: fixedNow), preferences: preferences, now: fixedNow)
        #expect(WidgetSnapshotWriter.write(snapshot, directory: directory))

        let url = directory.appendingPathComponent(VehicleWidgetSnapshot.fileName)
        let decoded = try JSONDecoder().decode(
            VehicleWidgetSnapshot.self, from: try Data(contentsOf: url))
        #expect(decoded == snapshot)
    }

    @Test
    func timelineReloadCoalescesUnchangedReadings() {
        let scoped = ScopedDefaults()
        let preferences = scoped.preferences()
        var gate = WidgetSnapshotWriter.ReloadGate()
        let first = WidgetSnapshotWriter.snapshot(
            from: fixtureState(fetchedAt: fixedNow), preferences: preferences, now: fixedNow)
        let later = fixedNow.addingTimeInterval(30)
        let unchanged = WidgetSnapshotWriter.snapshot(
            from: fixtureState(fetchedAt: later), preferences: preferences, now: later)
        let changed = WidgetSnapshotWriter.snapshot(
            from: fixtureState(battery: 75, fetchedAt: later), preferences: preferences, now: later)
        #expect(gate.shouldReload(cars: [first], now: fixedNow))
        #expect(!gate.shouldReload(cars: [unchanged], now: later))
        #expect(gate.shouldReload(cars: [changed], now: later))
        #expect(!gate.shouldReload(cars: [changed], now: later.addingTimeInterval(299)))
        #expect(gate.shouldReload(cars: [changed], now: later.addingTimeInterval(300)))
    }

    @Test("the writer disables itself outside the real app bundle")
    func bundleGateHoldsInTestRuns() {
        // The test runner's bundle id is not the app's, which is exactly the gate the
        // refresh coordinator relies on to keep test runs side-effect free.
        #expect(WidgetSnapshotWriter.isActive == false)
    }
}
