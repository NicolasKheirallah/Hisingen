import Foundation

/// The rows the status-item menu can offer for timers, software updates and saved charge
/// locations.
///
/// This is deliberately a second entry point and not a smaller copy of the Controls tab. A menu
/// row has to be self-contained: pause a timer, install the update the car has already
/// downloaded, save this parking spot, or flip the optimised-charging switch at a known place.
/// Everything that needs a value from the reader (a charge target, an amp limit, a new schedule)
/// stays in the tab, where there is room to ask.
///
/// Rows are built from the same `ControlsCommandGate` the cards use, and the menu dispatches
/// through `gate.send`, so a row is refused for the reason a card would print and the command
/// takes the one capability path every other surface takes.
@MainActor
enum MenuBarQuickControls {
    /// A reported timer the app can write, as one switch-like row.
    struct TimerRow: Equatable, Identifiable {
        let id: String
        /// The timer's name and time, for example "Charging Window 22:00–06:00".
        let title: String
        /// The write that flips this timer's enabled state, preserving its identity.
        let command: RemoteCommand
        let availability: CommandAvailability
        let isOn: Bool
    }

    /// One software-update write the menu offers.
    struct SoftwareRow: Equatable, Identifiable {
        enum Kind: Equatable {
            case installNow
            case schedule(delayMinutes: Int)
            case cancel
        }

        let kind: Kind
        let title: String
        let command: RemoteCommand
        let availability: CommandAvailability
        var id: String {
            switch kind {
            case .installNow: return "install"
            case .schedule(let minutes): return "schedule-\(minutes)"
            case .cancel: return "cancel"
            }
        }
    }

    /// A saved location's optimised-charging switch.
    struct LocationRow: Equatable, Identifiable {
        let id: String
        let title: String
        let command: RemoteCommand
        let availability: CommandAvailability
        let isOn: Bool
    }

    /// The delays the OTA card offers. Kept here so the menu and the card cannot drift.
    static let softwareScheduleDelays = [120, 480, 720]

    /// Whether the menu should show a Timers section at all.
    ///
    /// Probed with the tab's own placeholder schedules, so a reader who has schedules switched
    /// off, or whose provider cannot write them, is not told "No timers reported." when the app
    /// never asked. Busy-blind: a section that is only blocked by a command in flight must still
    /// appear, because its rows stay visible and disabled.
    static func canOfferTimers(gate: ControlsCommandGate) -> Bool {
        timerProbes.contains { gate.availability($0, ignoreBusy: true).isAvailable }
    }

    /// The charging-window and cabin-climate timer, in the shape the Controls tab probes with.
    private static let timerProbes: [RemoteCommand] = [
        .setGlobalChargeTimer(VehicleSchedule(
            kind: .globalCharging, startHour: 0, startMinute: 0,
            endHour: 6, endMinute: 0, weekdays: [], isActive: true
        )),
        .setClimateTimer(VehicleSchedule(
            kind: .climate, startHour: 7, startMinute: 30,
            endHour: nil, endMinute: nil, weekdays: [.monday], isActive: true
        ))
    ]

    /// Charging-window and cabin-climate timers, in the order the tab's plan lists them.
    ///
    /// Only the two kinds the app can write appear. A per-location timer or a departure time is
    /// read from the car but has no verified write payload, so a menu row for it could only
    /// schedule charging at the wrong time.
    static func timerRows(for state: VehicleState, gate: ControlsCommandGate) -> [TimerRow] {
        PlanTimeline.entries(for: state, includeInactive: true).compactMap { entry in
            let schedule = entry.schedule
            switch schedule.kind {
            case .globalCharging:
                break
            case .climate:
                // A timer without a backend row cannot be paused: writing it would create a
                // second timer instead of flipping this one. One-shot timers are history once
                // they fire, so the menu leaves both to the tab's editor.
                guard schedule.backendID != nil, schedule.oneShotDate == nil else { return nil }
            case .locationCharging, .departure:
                return nil
            }

            let toggled = toggledCopy(of: schedule)
            let command: RemoteCommand = schedule.kind == .climate
                ? .setClimateTimer(toggled)
                : .setGlobalChargeTimer(toggled)
            let availability = gate.availability(command)
            guard offersRow(availability) else { return nil }

            return TimerRow(
                id: PlanTimeline.scheduleIdentity(schedule),
                title: title(for: schedule),
                command: command,
                availability: availability,
                isOn: schedule.isActive
            )
        }
    }

    /// The software-update writes the car's current state allows.
    ///
    /// The rules are the card's (`OTAControlsCard.otaActions`): an update that has finished
    /// downloading can be installed now or scheduled, and a scheduled installation can still be
    /// brought forward or cancelled. Every other state is a status, not an action, and status
    /// lives in the tab.
    static func softwareRows(
        for software: VehicleSoftwareInfo?,
        gate: ControlsCommandGate
    ) -> [SoftwareRow] {
        guard let software else { return [] }

        var rows: [SoftwareRow] = []
        func append(_ kind: SoftwareRow.Kind, _ command: RemoteCommand, title: String) {
            let availability = gate.availability(command)
            guard offersRow(availability) else { return }
            rows.append(SoftwareRow(kind: kind, title: title, command: command, availability: availability))
        }

        switch software.state {
        case .downloaded, .deferred:
            append(.installNow, .installOTANow, title: L10n.text("Install Update Now"))
            for minutes in softwareScheduleDelays {
                append(.schedule(delayMinutes: minutes),
                       .scheduleOTA(delayMinutes: minutes),
                       title: L10n.format("In %d h", minutes / 60))
            }
        case .scheduled:
            append(.installNow, .installOTANow, title: L10n.text("Install Update Now"))
            append(.cancel, .cancelOTA, title: L10n.text("Cancel Scheduled Installation"))
        case .available, .downloading, .installing, .failed, .completed, .unknown:
            return []
        }
        return rows
    }

    /// Saved locations whose optimised-charging switch the car reports.
    ///
    /// A location that reports mode 0 has no optimised charging to switch, so it is left out
    /// rather than listed as a permanently inert row.
    static func locationRows(for state: VehicleState, gate: ControlsCommandGate) -> [LocationRow] {
        guard gate.features.contains(.chargeLocations) else { return [] }
        return state.savedChargeLocations.compactMap { location in
            // Mode 0 is `.unavailable`, so the mode name is the car's own answer to "is there
            // an optimised-charging switch here?"; the card draws its mode row from the same
            // value.
            guard location.optimisedChargingModeName != nil else { return nil }
            let command = RemoteCommand.setChargeLocationOptimisedCharging(
                id: location.id, enabled: !location.optimisedChargingEnabled
            )
            let availability = gate.availability(command)
            guard offersRow(availability) else { return nil }

            let name = gate.preferences.privacyRedactionEnabled || location.alias.isEmpty
                ? L10n.text("Saved charge location")
                : location.alias
            return LocationRow(
                id: location.id,
                title: L10n.text("Optimised charging") + " · " + name,
                command: command,
                availability: availability,
                isOn: location.optimisedChargingEnabled
            )
        }
    }

    /// Whether "Save Current Location…" can run. Probed with the card's own placeholder values,
    /// so the menu asks the gate the same question the card's "Add here" button asks.
    static func canSaveCurrentLocation(in state: VehicleState, gate: ControlsCommandGate) -> Bool {
        guard gate.features.contains(.chargeLocations) else { return false }
        let probe = RemoteCommand.createChargeLocationAtCar(
            alias: "", ampLimit: 0, minimumSoc: 0, optimisedCharging: false
        )
        return offersRow(gate.availability(probe))
    }

    /// A row appears when the vehicle, the account and the feature switches could ever allow it.
    /// Temporarily blocked rows stay visible and disabled with their reason; permanently refused
    /// ones are left out, the rule the status item's Actions rotor already follows.
    static func offersRow(_ availability: CommandAvailability) -> Bool {
        switch availability {
        case .available, .unavailableWhileBusy, .unavailableUntilRefresh:
            return true
        case .disabledBySettings, .unsupportedByVehicle, .unimplementedByProvider,
             .notVehicleOwner, .requiresAccountApproval, .invalidSettings:
            return false
        }
    }

    private static func toggledCopy(of schedule: VehicleSchedule) -> VehicleSchedule {
        VehicleSchedule(
            backendID: schedule.backendID,
            index: schedule.index,
            kind: schedule.kind,
            startHour: schedule.startHour,
            startMinute: schedule.startMinute,
            endHour: schedule.endHour,
            endMinute: schedule.endMinute,
            weekdays: schedule.weekdays,
            isActive: !schedule.isActive,
            locationName: schedule.locationName,
            oneShotDate: schedule.oneShotDate,
            syncStatus: schedule.syncStatus,
            repeatsWeekly: schedule.repeatsWeekly
        )
    }

    private static func title(for schedule: VehicleSchedule) -> String {
        // The tab's own summary, so a timer reads the same in both places.
        guard schedule.startHour != nil else { return schedule.kind.title }
        return "\(schedule.kind.title) \(Format.scheduleText(schedule))"
    }
}
