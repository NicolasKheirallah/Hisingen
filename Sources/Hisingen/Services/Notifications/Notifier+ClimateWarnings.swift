import Foundation

extension Notifier {
    /// Climate warnings that get a notice. The others only appear in the Needs Attention card.
    private static let noticeableClimateWarnings: Set<String> = ["RUN_TIME_NEARING_LIMIT", "BATTERY_LOW"]
    private static let climateWarningSessionsKey = "notifier_climate_warning_session_v1"

    /// Posts once per climate session when the car reports that the run time is nearly used up
    /// or that the battery is too low to keep climate running. The session start from the car
    /// identifies the session. Without one, the notice fires only on the reading that first
    /// shows the warning.
    func checkClimateWarnings(previous: VehicleState?, current: VehicleState) {
        guard preferences.notifyClimateChanges,
              current.hasFreshReading(.climateStatus),
              !current.freshness.isCached, !current.isStale(),
              !current.freshness.retainedDataCategories.contains(.climateStatus),
              let climate = current.climateStatus else { return }
        let noticed = (climate.climateWarnings ?? []).filter(Self.noticeableClimateWarnings.contains)
        guard !noticed.isEmpty else { return }

        let vin = current.identity.vin
        if let sessionStart = climate.sessionStartedAt {
            let sessionKey = String(Int(sessionStart.timeIntervalSince1970))
            var warnedSessions = defaults.dictionary(forKey: Self.climateWarningSessionsKey) as? [String: String] ?? [:]
            guard warnedSessions[vin] != sessionKey else { return }
            warnedSessions[vin] = sessionKey
            defaults.set(warnedSessions, forKey: Self.climateWarningSessionsKey)
        } else {
            let warnedBefore = previous?.climateStatus?.climateWarnings?
                .contains(where: Self.noticeableClimateWarnings.contains) ?? false
            guard !warnedBefore else { return }
        }

        let names = noticed.compactMap(VehicleClimateStatus.climateWarningName)
        guard !names.isEmpty else { return }
        postNotice(identifier: "hisingen.\(vin).climate-warning",
                   thread: "hisingen.climate.\(vin)",
                   title: L10n.text("Climate warning"),
                   body: privateBody(names.joined(separator: " · ")),
                   subtitle: displayName(for: current), vin: vin,
                   urgency: .attention)
    }
}
