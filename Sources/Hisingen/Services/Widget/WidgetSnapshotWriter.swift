import Foundation
import OSLog
import WidgetKit

/// Writes the desktop widget's snapshot into the App Group container after each completed
/// vehicle refresh, and asks WidgetKit to reload the timelines.
enum WidgetSnapshotWriter {
    /// Derived from the app's bundle id (`io.kheirallah.hisingen`), as the App Group rules
    /// require. Both the app and the appex entitlements declare it.
    static let appGroupID = "group.io.kheirallah.hisingen"

    private static let logger = AppLog.logger("widget")

    /// True only inside the real app bundle. The refresh coordinator keeps the publication
    /// hook below on by default, so it disables itself in test runs and `swift run` builds;
    /// the Notifier and the panel layout use the same bundle gate.
    static var isActive: Bool { Bundle.main.bundleIdentifier == "io.kheirallah.hisingen" }

    /// The publication hook the refresh coordinator holds. A state publishes the snapshot;
    /// `nil` removes the file, which the sign-out path uses to match the app dropping its
    /// own cached copy. The closure is MainActor-isolated because the display mapping reads
    /// the panel's own MainActor-isolated schedule resolver, and every call site (the
    /// refresh coordinator) is MainActor already.
    @MainActor static var publisher: @MainActor (VehicleState?) -> Void {
        { state in
            guard isActive else { return }
            guard let state else {
                remove()
                return
            }
            let preferences = PreferencesStore()
            publish(state, preferences: preferences, now: Date())
            publishGarage(activeState: state, preferences: preferences)
        }
    }

    /// Builds the snapshot for one authoritative refresh and writes it. Returns the
    /// written snapshot, or nil when the container was unavailable.
    @discardableResult
    @MainActor static func publish(
        _ state: VehicleState,
        preferences: PreferencesStore,
        now: Date = Date(),
        directory: URL? = nil
    ) -> VehicleWidgetSnapshot? {
        let snapshot = snapshot(from: state, preferences: preferences, now: now)
        return write(snapshot, directory: directory) ? snapshot : nil
    }

    /// Builds and writes the garage file the configurable widget reads to list the fleet.
    /// Runs beside the active-car write on every completed refresh, so a car the reader
    /// detached, disconnected or signed out drops out on the next refresh; the garage is
    /// the enumeration, never an independent source of fresh readings.
    @discardableResult
    @MainActor static func publishGarage(
        activeState: VehicleState,
        preferences: PreferencesStore,
        now: Date = Date(),
        directory: URL? = nil,
        stateStore: VehicleStateStore = VehicleStateStore(database: VehicleDatabase.shared)
    ) -> VehicleWidgetGarageSnapshot? {
        let cars = garageCars(
            activeState: activeState, preferences: preferences, stateStore: stateStore, now: now)
        guard !cars.isEmpty else { return nil }
        let garage = VehicleWidgetGarageSnapshot(
            schemaVersion: VehicleWidgetGarageSnapshot.currentSchemaVersion, cars: cars)
        // No timeline reload here: the active-car write already asked for one, and the
        // garage is only ever read through that same reload.
        return write(garage, directory: directory) ? garage : nil
    }

    /// Enumerates the garage the widget can render: the active car with its fresh state
    /// first, then every other known car's persisted reading. A VIN with no stored state
    /// (known but never refreshed) has nothing to show, so it stays out — the widget
    /// renders readings, and a placeholder entry per unscanned car would promise data the
    /// app does not have. Detached vehicles drop out because `knownVINs(for:)` already
    /// excludes them.
    @MainActor
    static func garageCars(
        activeState: VehicleState,
        preferences: PreferencesStore,
        stateStore: VehicleStateStore,
        now: Date = Date()
    ) -> [VehicleWidgetSnapshot] {
        var seen = Set<String>()
        var vins: [String] = []
        func push(_ vin: String) {
            let normalized = vin.normalizedVIN
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            vins.append(normalized)
        }
        push(activeState.identity.vin)
        for brand in VehicleBrand.allCases {
            preferences.knownVINs(for: brand).forEach(push)
        }
        return vins.compactMap { vin -> VehicleWidgetSnapshot? in
            guard let state = vin == activeState.identity.vin.normalizedVIN
                ? activeState
                : stateStore.snapshot(for: vin)
            else { return nil }
            return snapshot(from: state, preferences: preferences, now: now)
        }
    }

    static func remove(directory: URL? = nil) {
        for url in [fileURL(directory: directory), garageFileURL(directory: directory)] {
            guard let url else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Maps one authoritative state onto the widget's display values. The reading is the
    /// provider-authored state the panel persists, not the optimistic command overlay, so
    /// the widget never shows a command the car has not confirmed.
    @MainActor
    static func snapshot(
        from state: VehicleState,
        preferences: PreferencesStore,
        now: Date = Date()
    ) -> VehicleWidgetSnapshot {
        VehicleWidgetSnapshot(
            schemaVersion: VehicleWidgetSnapshot.currentSchemaVersion,
            vin: state.identity.vin,
            name: preferences.formattedVehicleTitle(
                vin: state.identity.vin,
                modelName: state.identity.modelName,
                modelYear: state.identity.modelYear,
                registrationNo: state.identity.registrationNo,
                fallbackBrand: state.model.brand
            ),
            batteryText: state.energy.batteryPercentage.map {
                String(format: "%.0f%%", locale: L10n.displayLocale, $0)
            },
            rangeText: state.primaryRangeKm.map {
                Format.distance(km: $0, unit: preferences.distanceUnit)
            },
            chargingKind: chargingKindToken(state.energy.chargingState),
            chargingText: state.energy.chargingState.displayName,
            departureText: departureText(for: state, now: now),
            fetchedAt: state.freshness.fetchedAt,
            writtenAt: now,
            languageCode: preferences.interfaceLanguage.languageCode
        )
    }

    /// Stable tokens the widget maps back to its own kinds. `unknown` covers every
    /// provider token the app does not recognise, so the widget's line stays honest there.
    private static func chargingKindToken(_ charging: ChargingState) -> String {
        switch charging {
        case .charging: return "charging"
        case .smartCharging: return "smartCharging"
        case .paused: return "paused"
        case .scheduled: return "scheduled"
        case .idle: return "idle"
        case .complete: return "complete"
        case .discharging: return "discharging"
        case .fault: return "fault"
        case .unknown: return "unknown"
        }
    }

    /// The next reported departure, resolved the way Plan resolves it. Today reads as a
    /// clock time; a later day keeps its date so the figure cannot pass for today's.
    @MainActor
    private static func departureText(for state: VehicleState, now: Date) -> String? {
        guard let next = PlanTimeline.entries(for: state, now: now)
            .first(where: { $0.schedule.kind == .departure })?.next
        else { return nil }
        if Calendar.current.isDate(next, inSameDayAs: now) {
            return Format.shortTime(date: next)
        }
        return "\(Format.shortDate(date: next)) · \(Format.shortTime(date: next))"
    }

    /// Atomic write, then a timeline reload. The reload is pointless in test processes (the
    /// bundle gate above already stops those) and is skipped when the widget extension is
    /// not installed; WidgetCenter logs that itself and nothing here fails a refresh.
    static func write(_ snapshot: VehicleWidgetSnapshot, directory: URL? = nil) -> Bool {
        guard let url = fileURL(directory: directory) else {
            logger.error("App Group container unavailable; widget snapshot not written")
            return false
        }
        guard encodeAndWrite(snapshot, to: url) else { return false }
        if isActive {
            WidgetCenter.shared.reloadAllTimelines()
        }
        return true
    }

    /// The garage twin of the active-car write, without the timeline reload: the reload is
    /// owned by the active-car write that always runs beside it.
    static func write(_ garage: VehicleWidgetGarageSnapshot, directory: URL? = nil) -> Bool {
        guard let url = garageFileURL(directory: directory) else {
            logger.error("App Group container unavailable; widget garage not written")
            return false
        }
        return encodeAndWrite(garage, to: url)
    }

    private static func encodeAndWrite(_ value: some Encodable, to url: URL) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Widget snapshot write failed: \(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    private static func fileURL(directory: URL?) -> URL? {
        let base = directory
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        return base?.appendingPathComponent(VehicleWidgetSnapshot.fileName)
    }

    private static func garageFileURL(directory: URL?) -> URL? {
        let base = directory
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        return base?.appendingPathComponent(VehicleWidgetGarageSnapshot.fileName)
    }
}
