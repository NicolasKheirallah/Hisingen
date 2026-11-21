import Foundation
import Testing
@testable import Hisingen
@testable import HisingenWidget

/// Pins the wire pair no shared module can hold together: the app's snapshot writer
/// (Hisingen target) and the widget's snapshot reader (HisingenWidget target) exchange a
/// hand-shaped JSON file, so these tests write with one side and decode with the other.
///
/// The two targets both define `VehicleWidgetSnapshot`; qualified names keep the pairs
/// explicit instead of relying on the file's active import.
@Suite("Widget snapshot")
@MainActor
struct WidgetSnapshotRoundTripTests {
    private static let fixedNow = try! fixedDate(hour: 12, minute: 0)

    /// A UUID-scoped preferences domain, so no assertion here can read the developer's real
    /// defaults (the app suite's ScopedPreferences cannot cross test targets).
    private final class ScopedDefaults {
        nonisolated(unsafe) let defaults: UserDefaults
        private let suiteName: String

        init() {
            suiteName = "HisingenWidgetTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
        }

        deinit { defaults.removePersistentDomain(forName: suiteName) }
    }

    private func fixtureState(
        vin: String = "YSMWIDGET01",
        battery: Double? = 78.4,
        rangeKm: Int? = 213,
        charging: ChargingState = .charging,
        fetchedAt: Date
    ) -> VehicleState {
        VehicleState(
            energy: EnergyAndChargingSnapshot(batteryPercentage: battery, rangeKm: rangeKm, chargingState: charging),
            identity: VehicleIdentitySnapshot(availability: .available, modelName: "Polestar 2", modelYear: "2023", vin: vin),
            freshness: SnapshotFreshness(isCached: false, fetchedAt: fetchedAt)
        )
    }

    @Test("the app's writer and the widget's reader agree on the wire shape")
    func writerFeedReader() throws {
        let directory = try temporaryDirectory()
        let preferences = PreferencesStore(defaults: ScopedDefaults().defaults)
        let state = fixtureState(fetchedAt: Self.fixedNow)

        let written = Hisingen.WidgetSnapshotWriter.publish(
            state, preferences: preferences, now: Self.fixedNow, directory: directory)
        let appSide = try #require(written)

        let read = try #require(HisingenWidget.WidgetSnapshotStore.load(directory: directory))
        #expect(read.vin == appSide.vin)
        #expect(read.name == appSide.name)
        #expect(read.batteryText == appSide.batteryText)
        #expect(read.rangeText == appSide.rangeText)
        #expect(read.chargingKind == appSide.chargingKind)
        #expect(read.chargingText == appSide.chargingText)
        #expect(read.departureText == appSide.departureText)
        #expect(read.fetchedAt == appSide.fetchedAt)
        #expect(read.writtenAt == appSide.writtenAt)
        #expect(read.languageCode == appSide.languageCode)
        #expect(read.schemaVersion == HisingenWidget.VehicleWidgetSnapshot.currentSchemaVersion)

        // The display values themselves, not just agreement: the reader side renders them.
        #expect(read.name == "Polestar 2 · 2023")
        #expect(read.batteryText == "78%")
        #expect(read.rangeText == "213 km")
        #expect(read.chargingKind == "charging")
        #expect(read.chargingText == "Charging")
        #expect(read.languageCode == nil)
    }

    @Test("a state with no battery or range keeps them missing rather than zero")
    func missingReadingsStayMissing() throws {
        let directory = try temporaryDirectory()
        let preferences = PreferencesStore(defaults: ScopedDefaults().defaults)
        let state = fixtureState(battery: nil, rangeKm: nil, charging: .idle, fetchedAt: Self.fixedNow)

        let written = Hisingen.WidgetSnapshotWriter.publish(
            state, preferences: preferences, now: Self.fixedNow, directory: directory)
        #expect(try #require(written).batteryText == nil)
        #expect(try #require(written).rangeText == nil)

        let read = try #require(HisingenWidget.WidgetSnapshotStore.load(directory: directory))
        #expect(read.batteryText == nil)
        #expect(read.rangeText == nil)
        #expect(read.chargingKind == "idle")
    }

    @Test("the sign-out path removes the file, and the widget falls back to its placeholder")
    func removalIsVisibleToTheReader() throws {
        let directory = try temporaryDirectory()
        let preferences = PreferencesStore(defaults: ScopedDefaults().defaults)
        let state = fixtureState(fetchedAt: Self.fixedNow)
        #expect(Hisingen.WidgetSnapshotWriter.publish(
            state, preferences: preferences, now: Self.fixedNow, directory: directory) != nil)
        #expect(HisingenWidget.WidgetSnapshotStore.load(directory: directory) != nil)

        Hisingen.WidgetSnapshotWriter.remove(directory: directory)
        #expect(HisingenWidget.WidgetSnapshotStore.load(directory: directory) == nil)
    }

    @Test("a snapshot from a newer schema is refused, not half-read")
    func futureSchemaIsRefused() throws {
        let directory = try temporaryDirectory()
        let snapshot = HisingenWidget.VehicleWidgetSnapshot(
            schemaVersion: HisingenWidget.VehicleWidgetSnapshot.currentSchemaVersion + 1,
            vin: "YSMWIDGET01", name: "Polestar 2", batteryText: "78%", rangeText: "213 km",
            chargingKind: "charging", chargingText: "Charging", departureText: nil,
            fetchedAt: Self.fixedNow, writtenAt: Self.fixedNow, languageCode: nil)
        try JSONEncoder().encode(snapshot).write(
            to: directory.appendingPathComponent(HisingenWidget.VehicleWidgetSnapshot.fileName))

        #expect(HisingenWidget.WidgetSnapshotStore.load(directory: directory) == nil)
    }

    @Test("undecodable bytes are refused")
    func corruptFileIsRefused() throws {
        let directory = try temporaryDirectory()
        try Data("not a snapshot".utf8).write(
            to: directory.appendingPathComponent(HisingenWidget.VehicleWidgetSnapshot.fileName))

        #expect(HisingenWidget.WidgetSnapshotStore.load(directory: directory) == nil)
    }

    // MARK: age line

    @Test("the age line follows the app's thresholds")
    func ageLineThresholds() throws {
        let base = try Self.fixedDate(hour: 12, minute: 0)
        func snapshot(fetchedMinutesAgo: Int) -> HisingenWidget.VehicleWidgetSnapshot {
            HisingenWidget.VehicleWidgetSnapshot(
                schemaVersion: 1, vin: "YSMWIDGET01", name: "Polestar 2",
                batteryText: nil, rangeText: nil, chargingKind: "idle", chargingText: nil,
                departureText: nil, fetchedAt: base.addingTimeInterval(TimeInterval(-fetchedMinutesAgo * 60)),
                writtenAt: base, languageCode: nil)
        }

        #expect(snapshot(fetchedMinutesAgo: 0).checkedLine(now: base) == "Checked just now")
        #expect(snapshot(fetchedMinutesAgo: 5).checkedLine(now: base) == "Checked 5 min ago")
        #expect(snapshot(fetchedMinutesAgo: 180).checkedLine(now: base) == "Checked 3 hr ago")
        #expect(snapshot(fetchedMinutesAgo: 60 * 26).checkedLine(now: base) == "Checked 1 d ago")
        // A clock behind the reading clamps to "just now" rather than counting negative.
        #expect(snapshot(fetchedMinutesAgo: -10).checkedLine(now: base) == "Checked just now")
    }

    // MARK: timeline entries

    @Test("entries map snapshots to deep links and placeholder to the panel toggle")
    func entryMapping() throws {
        let directory = try temporaryDirectory()
        let preferences = PreferencesStore(defaults: ScopedDefaults().defaults)
        let state = fixtureState(fetchedAt: Self.fixedNow)
        #expect(Hisingen.WidgetSnapshotWriter.publish(
            state, preferences: preferences, now: Self.fixedNow, directory: directory) != nil)

        let filled = HisingenWidget.VehicleTimelineProvider.entry(now: Self.fixedNow, directory: directory)
        #expect(filled.snapshot != nil)
        #expect(filled.link.absoluteString == "hisingen://select-car?vin=YSMWIDGET01")
        #expect(filled.checkedLine == "Checked just now")

        Hisingen.WidgetSnapshotWriter.remove(directory: directory)
        let empty = HisingenWidget.VehicleTimelineProvider.entry(now: Self.fixedNow, directory: directory)
        #expect(empty.snapshot == nil)
        #expect(empty.link.absoluteString == "hisingen://status")
        #expect(empty.checkedLine == nil)
    }

    // MARK: helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hisingen-widget-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fixed mid-day date, so same-day departure formatting never straddles midnight.
    private static func fixedDate(hour: Int, minute: Int) throws -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 15
        components.hour = hour; components.minute = minute
        guard let date = Calendar.current.date(from: components) else {
            throw CocoaError(.userActivityConnectionUnavailable)
        }
        return date
    }
}
