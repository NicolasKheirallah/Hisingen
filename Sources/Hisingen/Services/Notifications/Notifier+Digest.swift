import AppKit

/// One vehicle's line in the daily summary. Readings the car did not report fresh are left
/// nil or false, and the copy says "not reported" rather than printing a zero.
struct DailySummaryVehicle: Equatable, Sendable {
    let name: String
    var batteryPercent: Double?
    var rangeKm: Int?
    var chargedKwh: Double?
    var chargedKwhIsEstimate = false
    var healthReported = false
    var warningCount = 0
    var alarmTriggered = false
    var serviceDueSoon = false
    var failedCommands = 0
}

extension Notifier {
    private static let dailySummaryLastSentKey = "notifier_daily_summary_last_sent_v1"
    private static let dailySummarySeenKey = "notifier_daily_summary_seen_v1"
    private static let dailySummaryWindow: TimeInterval = 24 * 60 * 60

    /// Driven by the one-minute recheck timer. Sends at most one summary per calendar day, at the
    /// first tick on or after the chosen hour, so a Mac that slept through the hour still gets it
    /// later that morning. Quiet hours hold it until they end.
    func dailySummaryTick(now: Date = Date()) {
        let calendar = Calendar.current
        guard preferences.notifyDailySummary else {
            if defaults.bool(forKey: Self.dailySummarySeenKey) {
                defaults.set(false, forKey: Self.dailySummarySeenKey)
            }
            return
        }
        let hour = calendar.component(.hour, from: now)
        if !defaults.bool(forKey: Self.dailySummarySeenKey) {
            defaults.set(true, forKey: Self.dailySummarySeenKey)
            // Switching the summary on after its hour waits for tomorrow instead of posting at once.
            if hour >= preferences.dailySummaryHour {
                defaults.set(now.timeIntervalSince1970, forKey: Self.dailySummaryLastSentKey)
            }
        }
        guard hour >= preferences.dailySummaryHour else { return }
        let startOfToday = calendar.startOfDay(for: now).timeIntervalSince1970
        if let lastSent = defaults.object(forKey: Self.dailySummaryLastSentKey) as? Double,
           lastSent >= startOfToday {
            return
        }
        if preferences.quietHoursEnabled,
           Self.isQuietHour(now: now, startHour: preferences.quietHoursStartHour,
                            endHour: preferences.quietHoursEndHour) {
            return
        }
        sendDailySummary(now: now)
    }

    private func sendDailySummary(now: Date) {
        // "Since the last summary" for charging. The first summary covers the last day.
        let lastSent = (defaults.object(forKey: Self.dailySummaryLastSentKey) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        let since = lastSent ?? now.addingTimeInterval(-Self.dailySummaryWindow)
        let vehicles = previousStateByVIN.values
            .filter { !preferences.isMuted(vin: $0.identity.vin) }
            .sorted { $0.identity.vin < $1.identity.vin }
            .map { dailySummaryVehicle(for: $0, chargedSince: since, now: now) }
        // Nothing to report (no cars, or every car muted): leave the day open for a later tick.
        guard !vehicles.isEmpty else { return }
        defaults.set(now.timeIntervalSince1970, forKey: Self.dailySummaryLastSentKey)
        postNotice(identifier: "hisingen.daily-summary",
                   thread: "hisingen.summary",
                   title: L10n.text("Daily summary"),
                   body: privateBody(Self.dailySummaryBody(vehicles, distanceUnit: preferences.distanceUnit)),
                   urgency: .info)
    }

    private func dailySummaryVehicle(for state: VehicleState, chargedSince: Date, now: Date) -> DailySummaryVehicle {
        let vin = state.identity.vin
        let batteryFresh = state.hasFreshReading(.battery, now: now)
        let sessions = stateStore.database.charging.recentChargingSessions(for: vin, limit: 50, since: chargedSince)
        let observed = sessions.filter { $0.energyDeliveredKwh > 0 }
        let kwh = observed.reduce(0) { $0 + $1.energyDeliveredKwh }
        let failed = stateStore.database.history
            .recentCommandAudits(for: vin, limit: 500, since: now.addingTimeInterval(-Self.dailySummaryWindow))
            .filter { $0.status == "failed" }
            .count
        return DailySummaryVehicle(
            name: displayName(for: state),
            batteryPercent: batteryFresh ? state.energy.batteryPercentage : nil,
            rangeKm: batteryFresh ? state.energy.rangeKm : nil,
            chargedKwh: kwh > 0 ? kwh : nil,
            chargedKwhIsEstimate: observed.contains { $0.energySource != .observedPowerIntegration },
            healthReported: state.hasFreshReading(.health, now: now),
            warningCount: warningLabels(state).count,
            alarmTriggered: state.hasFreshReading(.openings, now: now) && state.exteriorStatus?.alarmTriggered == true,
            serviceDueSoon: Self.serviceDueSoon(state.maintenance.service),
            failedCommands: failed
        )
    }

    /// One line per vehicle, each a short run of facts joined by middots. Zero warnings and a
    /// clean command log are stated, not left blank, because a blank could mean either.
    static func dailySummaryBody(_ vehicles: [DailySummaryVehicle], distanceUnit: DistanceUnit) -> String {
        vehicles.map { vehicle in
            var pieces: [String] = []
            pieces.append(vehicle.batteryPercent.map { L10n.format("%@ battery", Format.percent($0)) }
                          ?? L10n.text("Battery not reported"))
            pieces.append(vehicle.rangeKm.map { L10n.format("%@ range", Format.distance(km: $0, unit: distanceUnit)) }
                          ?? L10n.text("Range not reported"))
            if let kwh = vehicle.chargedKwh {
                let amount = Format.energyKwh(kwh)
                pieces.append(vehicle.chargedKwhIsEstimate
                              ? L10n.format("About %@ charged", amount)
                              : L10n.format("%@ charged", amount))
            }
            if vehicle.healthReported {
                switch vehicle.warningCount {
                case 0: pieces.append(L10n.text("No warnings"))
                case 1: pieces.append(L10n.text("1 warning"))
                default: pieces.append(L10n.format("%d warnings", vehicle.warningCount))
                }
                if vehicle.serviceDueSoon { pieces.append(L10n.text("Service due soon")) }
            } else {
                pieces.append(L10n.text("Warnings and service not reported"))
            }
            if vehicle.alarmTriggered { pieces.append(L10n.text("Alarm triggered")) }
            switch vehicle.failedCommands {
            case 0: break
            case 1: pieces.append(L10n.text("1 failed command in 24 h"))
            default: pieces.append(L10n.format("%d failed commands in 24 h", vehicle.failedCommands))
            }
            return "\(vehicle.name): " + pieces.joined(separator: " · ")
        }.joined(separator: "\n")
    }
}
