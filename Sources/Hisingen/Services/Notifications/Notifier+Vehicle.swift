import AppKit

extension Notifier {
    func updateWarningVehicleCount(state: VehicleState) {
        let hasWarning = !warningLabels(state).isEmpty || state.exteriorStatus?.alarmTriggered == true
        let changed: Bool
        if hasWarning {
            changed = warningVehicles.insert(state.identity.vin).inserted
        } else {
            changed = warningVehicles.remove(state.identity.vin) != nil
        }
        if changed { onWarningVehicleCountChanged?(warningVehicles.count) }
    }

    func checkClimateChanges(previous: VehicleState?, current: VehicleState) {
        let vin = current.identity.vin
        guard preferences.notifyClimateChanges,
              !current.freshness.isCached, !current.isStale(),
              !current.freshness.retainedDataCategories.contains(.climateStatus),
              current.hasFreshReading(.climateStatus),
              let readingDate = current.reportedDate(for: .climateStatus),
              let previousActivity = previous?.climateStatus?.activity,
              let currentActivity = current.climateStatus?.activity else {
            pendingClimateStopReadingDateByVIN[vin] = nil
            return
        }
        guard currentActivity != .unknown, previousActivity != .unknown else {
            pendingClimateStopReadingDateByVIN[vin] = nil
            return
        }
        let wasActive = previousActivity.isActiveClimate
        let isActive = currentActivity.isActiveClimate
        let startConfirmationPending = current.commandState.receipts.contains { receipt in
            guard receipt.status.isAwaiting else { return false }
            if case .startClimate = receipt.command { return true }
            return false
        }
        if startConfirmationPending, !isActive {
            pendingClimateStopReadingDateByVIN[vin] = nil
            return
        }
        if isActive {
            let cancelledPendingStop = pendingClimateStopReadingDateByVIN.removeValue(forKey: vin) != nil
            guard !wasActive, !cancelledPendingStop else { return }
            postNotice(identifier: "hisingen.\(current.identity.vin).climate-started",
                       thread: "hisingen.climate.\(current.identity.vin)",
                       title: L10n.text("Climate started"),
                       body: privateBody(L10n.text("Cabin climate is now active.")),
                       subtitle: displayName(for: current), vin: current.identity.vin)
        } else {
            if wasActive {
                pendingClimateStopReadingDateByVIN[vin] = readingDate
                return
            }
            guard let firstInactiveReading = pendingClimateStopReadingDateByVIN[vin],
                  readingDate > firstInactiveReading else { return }
            let evidenceDuration = readingDate.timeIntervalSince(firstInactiveReading)
            guard evidenceDuration <= 30 else {
                pendingClimateStopReadingDateByVIN[vin] = readingDate
                return
            }
            // Three consecutive 3-second observations are required: this prevents two
            // identical backend responses, each locally stamped at fetch time, from looking
            // like independent stop evidence.
            guard evidenceDuration >= 6 else { return }
            pendingClimateStopReadingDateByVIN[vin] = nil
            postNotice(identifier: "hisingen.\(current.identity.vin).climate-stopped",
                       thread: "hisingen.climate.\(current.identity.vin)",
                       title: L10n.text("Climate stopped"),
                       body: privateBody(L10n.text("Cabin climate has turned off.")),
                       subtitle: displayName(for: current), vin: current.identity.vin)
        }
    }

    func checkSoftwareUpdate(previous: VehicleState?, current: VehicleState) {
        guard preferences.notifySoftwareUpdates,
              let previousSoftware = previous?.softwareInfo,
              let software = current.softwareInfo,
              software.state != previousSoftware.state else { return }

        let title: String
        let body: String
        switch software.state {
        case .available, .downloaded:
            title = L10n.text("Vehicle software update available")
            body = software.version ?? software.title ?? L10n.text("Open Hisingen for details.")
        case .scheduled:
            title = L10n.text("Vehicle software update scheduled")
            body = software.scheduledAt.map { Format.dateTimeFormatter.string(from: $0) }
                ?? L10n.text("The vehicle has an install time scheduled.")
        case .downloading:
            title = L10n.text("Vehicle software downloading")
            body = software.version ?? L10n.text("The vehicle has started downloading a software update.")
        case .installing:
            title = L10n.text("Vehicle software installing")
            body = software.version.map { L10n.format("Installing version %@.", $0) }
                ?? L10n.text("The vehicle may be briefly unavailable while it installs the update.")
        case .completed:
            title = L10n.text("Vehicle software updated")
            body = software.version ?? L10n.text("The vehicle completed its software update.")
        case .failed:
            title = L10n.text("Vehicle software update failed")
            body = software.version.map { L10n.format("Update to %@ failed.", $0) }
                ?? L10n.text("Open Hisingen for details.")
        default:
            return
        }
        postNotice(identifier: "hisingen.\(current.identity.vin).software", thread: "hisingen.software.\(current.identity.vin)",
                   title: title, body: privateBody(body), subtitle: displayName(for: current),
                   vin: current.identity.vin, urgency: .background,
                   category: Self.vehicleAlertCategoryID)
    }

    func checkVehicleWarnings(previous: VehicleState?, current: VehicleState) {
        guard preferences.notifyVehicleWarnings, let previous else { return }
        let previousWarnings = warningLabels(previous)
        let currentWarnings = warningLabels(current)
        let added = currentWarnings.subtracting(previousWarnings).sorted()
        if current.hasFreshReading(.health), !added.isEmpty {
            postNotice(identifier: "hisingen.\(current.identity.vin).vehicle-warnings",
                       thread: "hisingen.warnings.\(current.identity.vin)",
                       title: L10n.text("Vehicle warning"),
                       body: privateBody(added.joined(separator: " · ")),
                       subtitle: displayName(for: current), vin: current.identity.vin,
                       urgency: .urgent, category: Self.vehicleAlertCategoryID)
        }
        if current.hasFreshReading(.openings), current.exteriorStatus?.alarmTriggered == true,
           previous.exteriorStatus?.alarmTriggered != true {
            postNotice(identifier: "hisingen.\(current.identity.vin).alarm",
                       thread: "hisingen.security.\(current.identity.vin)",
                       title: L10n.text("Vehicle alarm triggered"),
                       body: privateBody(L10n.text("Open Hisingen for details.")),
                       subtitle: displayName(for: current), vin: current.identity.vin,
                       urgency: .urgent, category: Self.vehicleAlertCategoryID)
        }
    }

    func warningLabels(_ state: VehicleState) -> Set<String> {
        var labels = Set(state.maintenance.details?.warnings.map(\.displayName) ?? [])
        labels.formUnion(state.maintenance.service.fluidWarnings)
        if state.maintenance.service.serviceWarning { labels.insert(L10n.text("Service warning")) }
        return labels
    }

    nonisolated static func rainWithWindowsOpenCondition(_ state: VehicleState?) -> Bool {
        guard let state, let weather = state.weather,
              let condition = weather.condition?.lowercased(),
              (condition.contains("rain") || condition.contains("drizzle") || condition.contains("shower") || condition.contains("snow")),
              let ext = state.exteriorStatus,
              ext.itemsNeedingAttention.contains(where: { $0.displayName.lowercased().contains("window") })
        else { return false }
        return true
    }

    func checkRainWithWindows(previous: VehicleState?, current: VehicleState) {
        guard preferences.notifyRainWithWindowsOpen,
              current.hasFreshReading(.openings),
              Self.rainWithWindowsOpenCondition(current),
              !Self.rainWithWindowsOpenCondition(previous) else { return }

        // Titles stay emoji-free across all notification builders for visual consistency;
        // the charging/security semantics live in the thread identifiers and actions.
        postNotice(identifier: "hisingen.\(current.identity.vin).rain-windows",
                   thread: "hisingen.weather.\(current.identity.vin)",
                   title: L10n.text("Rain Alert"),
                   body: privateBody(L10n.text("Rain detected near your vehicle with windows left open!")),
                   subtitle: displayName(for: current), vin: current.identity.vin,
                   urgency: .urgent, category: Self.vehicleAlertCategoryID)
    }

    nonisolated static func eveningUnlockedCondition(_ state: VehicleState?, startHour: Int = 21) -> Bool {
        guard let state, let ext = state.exteriorStatus, ext.isLocked == false else { return false }
        let hour = Calendar.current.component(.hour, from: state.freshness.fetchedAt)
        return hour >= min(max(startHour, 18), 23) || hour < 6
    }

    func checkEveningUnlocked(previous: VehicleState?, current: VehicleState) {
        guard preferences.notifyEveningUnlocked,
              current.hasFreshReading(.locks),
              Self.eveningUnlockedCondition(current, startHour: preferences.eveningUnlockedStartHour),
              !Self.eveningUnlockedCondition(previous, startHour: preferences.eveningUnlockedStartHour) else { return }

        let body: String
        if preferences.privateNotificationDetails {
            body = L10n.text("Parked and currently unlocked.")
        } else {
            body = L10n.format("Your %@ is parked and currently unlocked.", displayName(for: current))
        }
        postNotice(identifier: "hisingen.\(current.identity.vin).evening-unlocked",
                   thread: "hisingen.security.\(current.identity.vin)",
                   title: L10n.text("Security Reminder"),
                   body: privateBody(body),
                   subtitle: displayName(for: current), vin: current.identity.vin,
                   urgency: .urgent,
                   category: Self.unlockedCategoryID)
    }
}

private extension ClimateActivity {
    var isActiveClimate: Bool {
        switch self {
        case .heating, .cooling, .ventilating, .active, .starting: return true
        default: return false
        }
    }
}
