import Foundation

/// Times shown for the home charger are the home's, whatever zone the Mac is in.
enum HomeChargingTime {
    static func time(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.displayLocale
        formatter.timeZone = zone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// `02:15–04:45`, with the day named when the window is not today in the home's zone.
    static func window(_ start: Date, _ end: Date, in zone: TimeZone, now: Date) -> String {
        let span = "\(time(start, in: zone))–\(time(end, in: zone))"
        guard let day = dayLabel(for: start, in: zone, now: now) else { return span }
        return "\(day) \(span)"
    }

    static func deadline(_ date: Date, in zone: TimeZone, now: Date) -> String {
        guard let day = dayLabel(for: date, in: zone, now: now) else { return time(date, in: zone) }
        return "\(day) \(time(date, in: zone))"
    }

    static func dateTime(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.displayLocale
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func range(_ range: DateInterval, in zone: TimeZone) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = L10n.displayLocale
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: range.start, to: range.end)
    }

    private static func dayLabel(for date: Date, in zone: TimeZone, now: Date) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if calendar.isDate(date, inSameDayAs: now) { return nil }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return L10n.text("tomorrow")
        }
        let formatter = DateFormatter()
        formatter.locale = L10n.displayLocale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter.string(from: date)
    }
}

/// Everything the home charger section of the charging card needs, resolved to words and actions.
struct HomeChargingCardInput {
    var pairing: HomeChargingPairing
    var telemetry: HomeChargerTelemetry
    var now: Date
    var link: HomeChargingModel.Link
    var lastContact: Date?
    var vehicleName: String
    var vehicleBatteryPercent: Double?
    var vehicleTargetPercent: Int?
    var vehicleConnection: ChargerConnection?
    var plan: HomeChargingPlanStatus?
    var command: HomeChargerCommandTracker.Phase
    /// The vehicle's own finish estimate, used when no plan supplies one.
    var vehicleFinish: Date?
    var currency: String
    /// Highest power seen in the current session, to tell reduced charging from steady charging.
    var sessionPeakKw: Double?
    var canEditPlan: Bool

    static func nexBlueControlsAvailable(link: HomeChargingModel.Link, telemetry: HomeChargerTelemetry, now: Date) -> Bool {
        guard link == .live else { return false }
        switch telemetry.activity(now: now) {
        case .stale, .unavailable, .fault, .noCable: return false
        default: return true
        }
    }
}

struct HomeChargingCardModel: Equatable {
    enum Tone: Equatable {
        case connected, charging, scheduled, waiting, unavailable, error
    }

    struct Action: Equatable, Identifiable {
        enum Kind: Equatable { case chargeNow, pause, resume, editPlan }
        var kind: Kind
        var title: String
        var isProminent: Bool
        var isEnabled: Bool
        /// Shown instead of the title while this action's command is in flight.
        var pendingTitle: String?
        var id: String { "\(kind)" }
    }

    struct Notice: Equatable {
        enum Level: Equatable { case info, warning, error }
        var level: Level
        var text: String
        var detail: String?
    }

    var tone: Tone
    var title: String
    var vehicleLine: String
    /// During a session: wall power, delivered energy and expected finish.
    var sessionLine: String?
    /// False when the session line shows the last readings received rather than live ones.
    var sessionIsLive = true
    var planLine: String?
    var costLine: String?
    var notice: Notice?
    var freshnessLine: String?
    var actions: [Action]
    var accessibilitySummary: String

    static func make(_ input: HomeChargingCardInput) -> HomeChargingCardModel {
        let zone = input.pairing.timeZone
        let now = input.now
        let telemetry = input.telemetry
        let activity = telemetry.activity(now: now)
        let (connected, evidence) = telemetry.connectorEvidence(now: now, vehicleConnection: input.vehicleConnection)

        // Title: "Home · NexBlue".
        let brand: String
        if input.pairing.source.isDirect {
            brand = input.pairing.source.providerName
        } else {
            brand = input.pairing.chargerName.localizedCaseInsensitiveContains("nexblue") ? "NexBlue" : input.pairing.chargerName
        }
        let title = L10n.format("%@ · %@", input.pairing.locationAlias, brand)

        // Vehicle line: name, battery, connector state with who said so.
        var vehicleParts = [input.vehicleName]
        if let battery = input.vehicleBatteryPercent {
            let planActive = input.plan.map { !$0.phase.isTerminal } ?? false
            if !planActive, let target = input.vehicleTargetPercent, Double(target) > battery {
                vehicleParts.append(L10n.format("%@ of %@", Format.percent(battery), Format.percent(Double(target))))
            } else {
                vehicleParts.append(Format.percent(battery))
            }
        }
        vehicleParts.append(connectorText(connected: connected, evidence: evidence, activity: activity))
        let vehicleLine = vehicleParts.joined(separator: " · ")

        // Session line: what matters while energy is moving. When the readings are stale they are
        // still shown, labelled as the last known ones, and never as live figures.
        var sessionLine: String?
        var sessionIsLive = true
        switch activity {
        case .charging(let power):
            sessionLine = sessionText(power: power, telemetry: telemetry, finish: input.plan?.expectedFinish ?? input.vehicleFinish, zone: zone)
        case .enabledNoDraw, .waitingForPower, .waitingForVehicle:
            sessionLine = sessionText(power: nil, telemetry: telemetry, finish: nil, zone: zone)
        case .stale, .unavailable:
            if let kept = sessionText(power: nil, telemetry: telemetry, finish: nil, zone: zone), telemetry.status?.value != .unavailable {
                sessionLine = L10n.format("Last known: %@", kept)
                sessionIsLive = false
            }
        default:
            break
        }

        // Plan line.
        let plan = input.plan.flatMap { $0.phase.isTerminal ? nil : $0 }
        let planLine = plan.flatMap { planText($0, zone: zone, now: now) }

        var costLine: String?
        if let plan, let cost = plan.estimatedCost, cost > 0 {
            costLine = L10n.format("Estimated electricity cost %@", Format.currency(cost, symbol: plan.currency ?? input.currency))
        }

        let notice = noticeFor(input, activity: activity, plan: plan)

        // Tone.
        let tone: Tone
        switch (activity, notice?.level) {
        case (_, .error?): tone = .error
        case (.charging, _): tone = .charging
        case (.fault, _): tone = .error
        case (.unavailable, _), (.stale, _): tone = .unavailable
        case (.waitingForPower, _), (.waitingForVehicle, _), (.enabledNoDraw, _), (.delayedStart, _): tone = .waiting
        default: tone = plan != nil && connected == true ? .scheduled : .connected
        }

        let freshness = freshnessLine(input, activity: activity, zone: zone)
        let actions = actionsFor(input, activity: activity, plan: plan)
        let summary = [title, vehicleLine, sessionLine, planLine, notice?.text, costLine].compactMap { $0 }.joined(separator: ". ")
        return HomeChargingCardModel(tone: tone, title: title, vehicleLine: vehicleLine, sessionLine: sessionLine,
                                     sessionIsLive: sessionIsLive, planLine: planLine, costLine: costLine, notice: notice,
                                     freshnessLine: freshness, actions: actions, accessibilitySummary: summary)
    }

    // MARK: - Pieces

    private static func connectorText(connected: Bool?, evidence: HomeConnectorEvidence, activity: HomeChargerActivity) -> String {
        switch (connected, evidence) {
        case (true?, .confirmedByCharger):
            switch activity {
            case .charging: return L10n.text("Charging")
            case .finished: return L10n.text("Charged")
            default: return L10n.text("Plugged in")
            }
        case (true?, .reportedByVehicle): return L10n.text("Plugged in, per the car")
        case (true?, .inferred): return L10n.text("Probably plugged in")
        case (false?, .confirmedByCharger): return L10n.text("Not plugged in")
        case (false?, _): return L10n.text("Not plugged in, per the car")
        default: return L10n.text("Plug state unknown")
        }
    }

    private static func sessionText(power: Double?, telemetry: HomeChargerTelemetry, finish: Date?, zone: TimeZone) -> String? {
        var parts: [String] = []
        if let power { parts.append(Format.powerKw(power)) }
        else if let reading = telemetry.powerKw?.value { parts.append(Format.powerKw(max(0, reading))) }
        if let energy = telemetry.sessionEnergyKwh?.value {
            parts.append(L10n.format("%@ delivered", Format.energyKwh(energy)))
        }
        if let finish, finish > Date(timeIntervalSince1970: 0) {
            parts.append(L10n.format("Ready about %@", HomeChargingTime.time(finish, in: zone)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func planText(_ plan: HomeChargingPlanStatus, zone: TimeZone, now: Date) -> String? {
        switch plan.phase {
        case .holding:
            return L10n.text("Paused. The plan waits until you resume.")
        case .override:
            return L10n.text("Charge now is running and replaces the plan windows.")
        default:
            break
        }
        var parts: [String] = []
        if let window = plan.windows.first(where: { $0.end > now }) {
            parts.append(L10n.format("Planned %@", HomeChargingTime.window(window.start, window.end, in: zone, now: now)))
        }
        if let target = plan.target, let deadline = plan.deadline {
            parts.append(L10n.format("%@ by %@", target.summary, HomeChargingTime.deadline(deadline, in: zone, now: now)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func noticeFor(_ input: HomeChargingCardInput, activity: HomeChargerActivity,
                                  plan: HomeChargingPlanStatus?) -> Notice? {
        let direct = input.pairing.source.isDirect
        let provider = input.pairing.source.providerName
        // The reader's last action comes first: it is what they are waiting on.
        switch input.command {
        case .sending(let kind, _):
            if direct {
                return Notice(level: .info, text: kind == .start ? L10n.format("Sending the start command to %@", provider) : L10n.format("Sending the pause command to %@", provider))
            }
            return Notice(level: .info, text: kind == .start ? L10n.text("Sending the start command to Home Assistant") : L10n.text("Sending the pause command to Home Assistant"))
        case .awaitingCharger(let kind, _, _):
            return Notice(level: .info,
                          text: direct ? L10n.format("%@ accepted the command. Waiting for the charger to confirm.", provider)
                                       : L10n.text("Home Assistant accepted the command. Waiting for the charger to confirm."),
                          detail: kind == .start ? L10n.text("The charger reports about once a minute.") : nil)
        case .rejected(_, let reason, _):
            return Notice(level: .error, text: L10n.text("The charger command was rejected"), detail: reason.isEmpty ? nil : reason)
        case .unconfirmed(_, _, let reason):
            return Notice(level: .warning, text: L10n.text("The charger has not confirmed the command"), detail: unconfirmedDetail(reason, direct: direct))
        case .confirmed(_, _, let outcome):
            if outcome == .enabledNoDraw { return noDrawNotice() }
        case .idle:
            break
        }

        switch input.link {
        case .unauthorized:
            if direct {
                return Notice(level: .error, text: L10n.format("%@ did not accept the saved login", provider),
                              detail: L10n.text("Sign in again in Settings."))
            }
            return Notice(level: .error, text: L10n.text("Home Assistant rejected the access token"),
                          detail: L10n.text("Add a new long-lived token in Settings."))
        case .unreachable, .reconnecting:
            return Notice(level: .warning, text: direct ? L10n.format("%@ is unreachable", provider) : L10n.text("Home Assistant is unreachable"),
                          detail: L10n.text("Readings are the last values received and may be out of date."))
        default:
            break
        }

        switch activity {
        case .stale:
            return Notice(level: .warning, text: L10n.text("The charger has not reported recently"))
        case .unavailable:
            return Notice(level: .warning, text: direct ? L10n.format("The charger is unavailable in %@", provider)
                                                        : L10n.text("The charger is unavailable in Home Assistant"))
        case .fault:
            return Notice(level: .error, text: L10n.text("The charger reports an error"))
        case .waitingForPower:
            return Notice(level: .info, text: L10n.text("Waiting for available power"),
                          detail: L10n.text("Load balancing is holding the charger. It continues when power is free."))
        case .delayedStart:
            if direct {
                return Notice(level: .warning, text: L10n.format("%@ is delaying the start", provider),
                              detail: L10n.text("A charging schedule is active on the charger."))
            }
            return Notice(level: .warning, text: L10n.text("NexBlue is delaying the start"),
                          detail: L10n.text("A delayed start or EcoPilot is active on the charger."))
        case .waitingForVehicle:
            return Notice(level: .info, text: L10n.text("Waiting for the car to start drawing power"))
        case .enabledNoDraw:
            return noDrawNotice()
        case .charging(let power):
            if let peak = input.sessionPeakKw, peak >= 2, power > 0, power < peak * 0.6 {
                return Notice(level: .info, text: L10n.text("Charging at reduced power"),
                              detail: L10n.text("Load balancing can limit the charger when the house uses more power."))
            }
        default:
            break
        }
        if let plan, plan.phase == .unlikely {
            return Notice(level: .warning, text: L10n.text("The target is unlikely by the deadline"),
                          detail: plan.warnings.first.map(plan.warningText))
        }
        if let plan, plan.phase == .attention {
            return Notice(level: .warning, text: plan.message ?? L10n.text("The plan needs attention"),
                          detail: plan.warnings.first.map(plan.warningText))
        }
        if let plan, let code = plan.warnings.first {
            return Notice(level: .info, text: plan.warningText(code))
        }
        return nil
    }

    private static func noDrawNotice() -> Notice {
        Notice(level: .warning, text: L10n.text("Charging is enabled but the car is drawing no power"),
               detail: L10n.text("Check the car's own charging schedule and charge limit."))
    }

    private static func unconfirmedDetail(_ reason: HomeChargerCommandTracker.UnconfirmedReason, direct: Bool) -> String {
        switch reason {
        case .timedOut: return L10n.text("The charger kept its previous state. Try again, or check the charger.")
        case .delayedStartActive:
            return direct ? L10n.text("A charging schedule is active on the charger.") : L10n.text("A delayed start or EcoPilot is active on the charger.")
        case .chargerError: return L10n.text("The charger reported an error after the command.")
        case .noFreshReading: return L10n.text("No new reading arrived from the charger.")
        }
    }

    private static func freshnessLine(_ input: HomeChargingCardInput, activity: HomeChargerActivity, zone: TimeZone) -> String? {
        switch input.link {
        case .unreachable, .reconnecting, .unauthorized:
            guard let contact = input.lastContact else { return nil }
            if input.pairing.source.isDirect {
                return L10n.format("Last update from %@ %@", input.pairing.source.providerName, HomeChargingTime.time(contact, in: zone))
            }
            return L10n.format("Last update from Home Assistant %@", HomeChargingTime.time(contact, in: zone))
        default:
            break
        }
        guard let stamp = input.telemetry.status?.timestamp else { return nil }
        let age = max(0, input.now.timeIntervalSince(stamp))
        if age >= 120 { return L10n.format("Charger updated %@ ago", Format.shortDuration(minutes: max(1, Int(age / 60)))) }
        return nil
    }

    private static func actionsFor(_ input: HomeChargingCardInput, activity: HomeChargerActivity,
                                   plan: HomeChargingPlanStatus?) -> [Action] {
        let pending = input.command.isPendingPhase
        let canSend = !pending && (input.pairing.source != .nexBlue ||
            HomeChargingCardInput.nexBlueControlsAvailable(link: input.link, telemetry: input.telemetry, now: input.now))
        var actions: [Action] = []
        switch activity {
        case .charging, .waitingForPower, .waitingForVehicle, .enabledNoDraw:
            actions.append(Action(kind: .pause, title: L10n.text("Pause"), isProminent: false, isEnabled: canSend,
                                  pendingTitle: input.command.kindIs(.pause) && pending ? L10n.text("Pausing…") : nil))
        case .pluggedIn, .finished, .delayedStart:
            if let plan, plan.isHeld {
                actions.append(Action(kind: .resume, title: L10n.text("Resume"), isProminent: true, isEnabled: !pending, pendingTitle: nil))
            }
            actions.append(Action(kind: .chargeNow, title: L10n.text("Charge now"), isProminent: plan?.isHeld != true, isEnabled: canSend,
                                  pendingTitle: input.command.kindIs(.start) && pending ? L10n.text("Starting…") : nil))
        case .noCable, .unavailable, .stale, .fault:
            break
        }
        if let plan, plan.isHeld, !actions.contains(where: { $0.kind == .resume }) {
            actions.insert(Action(kind: .resume, title: L10n.text("Resume"), isProminent: true, isEnabled: !pending, pendingTitle: nil), at: 0)
        }
        if input.canEditPlan {
            actions.append(Action(kind: .editPlan, title: L10n.text("Edit plan"), isProminent: false, isEnabled: true, pendingTitle: nil))
        }
        return actions
    }
}

extension HomeChargerCommandTracker.Phase {
    var isPendingPhase: Bool {
        switch self {
        case .sending, .awaitingCharger: return true
        default: return false
        }
    }

    func kindIs(_ expected: HomeChargerCommandKind) -> Bool {
        switch self {
        case .sending(let kind, _), .awaitingCharger(let kind, _, _), .confirmed(let kind, _, _),
             .rejected(let kind, _, _), .unconfirmed(let kind, _, _):
            return kind == expected
        case .idle:
            return false
        }
    }
}

/// What could fight the plan for the charger, gathered while the reader sets it up.
struct HomeChargingConflict: Equatable, Identifiable {
    enum Kind: Equatable {
        case vehicleSchedule, vehicleOptimisedCharging, vehicleChargeNow, chargerDelayedStart, homeAssistantAutomation
    }

    var kind: Kind
    var title: String
    var detail: String
    var id: String { "\(kind)-\(title)" }
}

enum HomeChargingConflicts {
    static func evaluate(vehicle energy: EnergyAndChargingSnapshot?, pairing: HomeChargingPairing,
                         telemetry: HomeChargerTelemetry, now: Date, automations: [String]) -> [HomeChargingConflict] {
        var found: [HomeChargingConflict] = []
        if let energy {
            let location = pairing.locationID.flatMap { id in energy.locations.first { $0.id == id } }
            let global = energy.schedules.filter(\.isActive).count
            let atLocation = (location?.chargeTimers ?? []).filter(\.isActive).count
            let total = global + atLocation
            if total > 0 {
                found.append(HomeChargingConflict(
                    kind: .vehicleSchedule, title: L10n.text("The car has charging schedules"),
                    detail: L10n.format("%d active. A car schedule can hold charging back outside its own hours, so planned windows may not match.", total)))
            }
            if location?.optimisedChargingEnabled == true {
                found.append(HomeChargingConflict(
                    kind: .vehicleOptimisedCharging, title: L10n.text("The car uses optimised charging here"),
                    detail: L10n.text("The car may delay charging on its own. Turn it off for this location, or the plan and the car decide separately.")))
            }
            if energy.chargeNowActive == true {
                found.append(HomeChargingConflict(
                    kind: .vehicleChargeNow, title: L10n.text("Charge now is on in the car"),
                    detail: L10n.text("The car ignores its own schedule while this is on.")))
            }
        }
        if telemetry.activity(now: now) == .delayedStart {
            found.append(HomeChargingConflict(
                kind: .chargerDelayedStart, title: L10n.text("NexBlue is holding a delayed start"),
                detail: L10n.text("A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start.")))
        }
        for name in automations.sorted() {
            found.append(HomeChargingConflict(
                kind: .homeAssistantAutomation, title: L10n.format("Automation: %@", name),
                detail: L10n.text("This Home Assistant automation uses the charger and may start or stop it.")))
        }
        return found
    }
}
