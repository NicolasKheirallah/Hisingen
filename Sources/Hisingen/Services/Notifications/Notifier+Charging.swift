import AppKit

extension Notifier {
    func checkChargerConnection(previous: VehicleState?, current: VehicleState) {
        guard preferences.notifyChargerConnection,
              current.hasFreshReading(.charging),
              let previous, previous.identity.vin == current.identity.vin,
              [.connected, .disconnected].contains(previous.energy.connection),
              [.connected, .disconnected].contains(current.energy.connection) else { return }
        let wasConnected = previous.energy.connection == .connected
        let isConnected = current.energy.connection == .connected
        guard isConnected != wasConnected else { return }
        if isConnected {
            postNotice(identifier: "hisingen.\(current.identity.vin).cable-connected",
                       thread: "hisingen.charging.\(current.identity.vin)",
                       title: L10n.text("Cable connected"),
                       body: privateBody(cableBody(battery: current.energy.batteryPercentage)),
                       subtitle: displayName(for: current), vin: current.identity.vin)
        } else {
            postNotice(identifier: "hisingen.\(current.identity.vin).cable-disconnected",
                       thread: "hisingen.charging.\(current.identity.vin)",
                       title: L10n.text("Cable disconnected"),
                       body: privateBody(L10n.text("Charging cable disconnected.")),
                       subtitle: displayName(for: current), vin: current.identity.vin)
        }
    }

    func checkSlowCharging(current: VehicleState) {
        let condition = current.hasFreshReading(.charging) && current.isCharging
            && (current.energy.powerWatts.map { $0 > 0 && $0 < 2_000 } ?? false)
        trackSustained(condition: condition, key: "\(current.identity.vin).slow-charging", duration: 15 * 60, enabled: preferences.notifySlowCharging) {
            let power = current.energy.powerWatts.map(Format.kilowatts) ?? L10n.text("Unavailable")
            self.postNotice(identifier: "hisingen.\(current.identity.vin).slow-charging", thread: "hisingen.charging.\(current.identity.vin)",
                            title: L10n.text("Charging power is unusually low"), body: self.privateBody(power),
                            subtitle: self.displayName(for: current), vin: current.identity.vin,
                            urgency: .background)
        }
    }

    nonisolated static func plugInReminderCondition(_ state: VehicleState?, threshold: Int = 40) -> Bool {
        guard let state, state.powertrain.hasElectricRange,
              let battery = state.energy.batteryPercentage, battery <= Double(min(max(threshold, 10), 80)),
              state.energy.connection == .disconnected, !state.isCharging else { return false }
        return true
    }

    func checkLowBatteryPlugIn(previous: VehicleState?, current: VehicleState) {
        guard preferences.notifyPlugInReminder,
              current.hasFreshReading(.battery), current.hasFreshReading(.charging),
              Self.plugInReminderCondition(current, threshold: preferences.plugInReminderThreshold),
              !Self.plugInReminderCondition(previous, threshold: preferences.plugInReminderThreshold) else { return }

        let name = displayName(for: current)
        let detailedBody: String
        if preferences.privateNotificationDetails {
            detailedBody = L10n.text("Parked and unplugged. Connect to a charger to ensure departure range.")
        } else if let battery = current.energy.batteryPercentage {
            detailedBody = L10n.format("Parked at %.0f%% and unplugged. Connect to a charger to ensure departure range.", battery)
        } else {
            detailedBody = L10n.text("Parked and unplugged. Connect to a charger to ensure departure range.")
        }
        postNotice(identifier: "hisingen.\(current.identity.vin).plugin-reminder",
                   thread: "hisingen.charging.\(current.identity.vin)",
                   title: L10n.text("Plug-In Reminder"),
                   body: privateBody(detailedBody),
                   subtitle: name, vin: current.identity.vin)
    }

    func chargingBody(_ state: VehicleState) -> String {
        let brandName = displayName(for: state)
        // Private mode keeps the banner anonymous now that the subtitle carries the
        // vehicle name – repeating it here said the same thing twice.
        guard !preferences.privateNotificationDetails else { return L10n.text("Started charging.") }
        var values: [String] = []
        if let battery = state.energy.batteryPercentage { values.append(percentText(battery)) }
        if let minutes = state.energy.estimatedTimeToFullMinutes {
            values.append(L10n.format("full in %@", Format.shortDuration(minutes: minutes)))
        }
        return values.isEmpty ? L10n.format("Your %@ started charging.", brandName) : values.joined(separator: " · ")
    }

    func completionBody(_ state: VehicleState) -> String {
        let brandName = displayName(for: state)
        guard !preferences.privateNotificationDetails else { return L10n.text("Finished charging.") }
        var values: [String] = []
        if let battery = state.energy.batteryPercentage { values.append(percentText(battery)) }
        if let range = state.energy.rangeKm {
            values.append(L10n.format("%@ range", Format.distance(km: range, unit: preferences.distanceUnit)))
        }
        return values.isEmpty ? L10n.format("Your %@ finished charging.", brandName) : values.joined(separator: " · ")
    }

    func lowBatteryBody(_ state: VehicleState) -> String {
        preferences.privateNotificationDetails
            ? L10n.text("Battery is low.")
            : L10n.format("Your %@ battery is low.", displayName(for: state))
    }

    private func cableBody(battery: Double?) -> String {
        guard let battery else { return L10n.text("Charging cable connected.") }
        return L10n.format("Charging cable connected. %@", percentText(battery))
    }

    private func percentText(_ battery: Double) -> String {
        L10n.format("%.0f%%", battery)
    }

    func post(_ event: ChargingEvent, state: VehicleState, title: String,
                      body: String, urgency: Urgency = .info, category: String? = nil) {
        postNotice(
            identifier: "hisingen.\(state.identity.vin).\(event.identifierComponent)",
            thread: "hisingen.charging.\(state.identity.vin)",
            title: title,
            body: body,
            subtitle: displayName(for: state),
            vin: state.identity.vin,
            urgency: urgency,
            category: category
        )
    }

    /// Per-session anomaly banner. Location names are personal data, so the body goes
    /// through the same privacy gate as vehicle telemetry banners.
    func notifyChargingAnomaly(locationName: String, vin: String) {
        postNotice(
            identifier: "hisingen.notice.charging-anomaly.\(vin)",
            thread: "hisingen.charging.\(vin)",
            title: L10n.text("Unusually slow charging"),
            body: privateBody(L10n.format("Peak power at %@ was far below this location's usual level. The cable or charger may be derating.", locationName)),
            subtitle: displayName(forVIN: vin),
            vin: vin
        )
    }

    /// One-shot slow-charging anomaly check per completed session, run against a fresh
    /// telemetry snapshot. Location lives on the persisted DB session (domain sessions don't
    /// carry it), so detection runs here against the store.
    func notifyChargingAnomalyIfNeeded(for state: VehicleState) {
        let ledger = stateStore.database.charging
        guard available, authorized, preferences.features.contains(.notifications),
              !preferences.isMuted(vin: state.identity.vin),
              let last = ledger.recentChargingSessions(for: state.identity.vin, limit: 1).first,
              last.locationName?.isEmpty == false,
              let ended = last.endedAt,
              Date().timeIntervalSince(ended) < 600 else { return }
        // Keep one last-considered session per vehicle, rather than one key per charge.
        let lastCheckedKey = "notifier_anomaly_last_checked_by_vin_v1"
        var checked = (defaults.dictionary(forKey: lastCheckedKey) as? [String: String]) ?? [:]
        guard checked[state.identity.vin] != last.id else { return }
        checked[state.identity.vin] = last.id
        defaults.set(checked, forKey: lastCheckedKey)
        let priors = ledger.priorSessionPeaks(
            vin: state.identity.vin, locationName: last.locationName ?? "",
            excludingSessionID: last.id)
        guard HistoryInsights.sessionPeakAnomaly(currentPeakKw: last.peakPowerKw,
                                                 priorPeaksKwAtSameLocation: priors) else { return }
        notifyChargingAnomaly(locationName: last.locationName ?? "", vin: state.identity.vin)
    }
}
