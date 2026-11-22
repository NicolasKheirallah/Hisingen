import AppKit

/// What the URL router needs from the app shell. The router owns URL parsing and the dispatch
/// table; every actual effect (selecting a vehicle, toggling the popover, sending a command)
/// is a call back through here.
@MainActor
protocol URLCommandRouterContext: AnyObject {
    var activeBrand: VehicleBrand { get }
    /// Fallback climate temperature when `hisingen://climate/start` carries no `temp` query.
    var defaultRemoteClimateTemperatureCelsius: Double { get }

    /// Hand an OAuth redirect URL to whichever sign-in flow is awaiting it.
    func handleOAuthCallback(_ url: URL)
    func selectVehicle(vin: String)
    func selectVehicleByIndex(_ index: Int)
    func showSettings()
    func toggleSettings()
    func togglePopover()
    func refreshNow()
    /// Every command that arrives through a `hisingen://` URL. The conformer treats it as a deep
    /// link and asks the person to confirm it, because the URL came from outside the app.
    func performRemoteCommand(_ command: RemoteCommand, targetVIN: String?)
    /// A "not available on this brand" notice for a deep-link command the active brand can't run.
    func notifyCommandNotice(title: String, body: String)
}

/// Translates inbound `hisingen://…` URLs (and the Polestar `polestar-explore://` OAuth
/// redirect) into calls on the rest of the app: vehicle selection, popover / settings
/// toggles, manual refresh, and the deep-link remote commands
/// (`hisingen://lock`, `hisingen://climate/start?temp=21`, `hisingen://charge-target?percent=80`, …).
///
/// Any other `hisingen://` URL is refused with a notice rather than handed to a sign-in flow.
///
/// Extracted from `AppDelegate`, which was the URL parser, the Apple Event target, and the
/// dispatch table all at once. Owns the `kAEGetURL` Apple Event registration too, so the
/// system-browser redirect and the `application(_:open:)` path share one entry point.
@MainActor
final class URLCommandRouter: NSObject {
    private weak var context: (any URLCommandRouterContext)?
    private let logger = AppLog.logger("url-router")

    /// Climate range used when a deep link asks for a temperature: the same fallback the in-app
    /// climate slider uses when a vehicle advertises no limits.
    private static let climateTemperatureRange = VehicleControlSettings().temperatureRange
    /// The runtimes and delays the Controls tab pickers offer, so a link can only ask for what
    /// the in-app surface can ask for. The command line reads the same two lists for the same
    /// reason: an argument it accepts is one the pickers could have offered.
    static let engineRuntimeMinutes = [5, 10, 15]
    static let otaScheduleDelayMinutes = [120, 480, 720]

    init(context: any URLCommandRouterContext) {
        self.context = context
        super.init()
    }

    /// Registers for the `GetURL` Apple Event – `hisingen://…` opened while the app is already
    /// running, plus the OAuth redirect handed back by the system browser.
    func startHandlingAppleEvents() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                         withReplyEvent _: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        route(url)
    }

    func route(_ url: URL) {
        guard let context else { return }

        // The command client's redirect is `polestar-explore://explore.polestar.com` (PolestarAPI).
        if url.scheme?.lowercased() == "polestar-explore" {
            guard url.host?.lowercased() == "explore.polestar.com" else {
                logger.notice("Refused polestar-explore URL with an unexpected host")
                return
            }
            context.handleOAuthCallback(url)
            return
        }
        guard url.scheme?.lowercased() == "hisingen" else { return }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let command = host.isEmpty ? path : (path.isEmpty ? host : "\(host)/\(path)")
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems

        let rawTargetVIN = queryItems?.first(where: { $0.name == "vin" })?.value
        let targetVIN = rawTargetVIN?.isEmpty == false ? rawTargetVIN : nil

        switch command {
        // Volvo's HTTPS callback page (site/oauth-callback.html) hands the result back on this
        // exact path; VolvoAPI matches the same URI when it consumes the callback.
        case "oauth/volvo/callback":
            context.handleOAuthCallback(url)

        case "select-car", "switch-car", "switch-vehicle":
            if let vin = queryItems?.first(where: { $0.name == "vin" })?.value, !vin.isEmpty {
                context.selectVehicle(vin: vin)
            } else if let indexStr = queryItems?.first(where: { $0.name == "index" })?.value,
                      let index = Int(indexStr) {
                context.selectVehicleByIndex(index)
            }

        case "refresh":
            context.refreshNow()

        case "settings", "preferences":
            context.showSettings()

        case "toggle-settings":
            context.toggleSettings()

        case "status", "toggle":
            context.togglePopover()

        case "climate/start", "climatization/start":
            // Non-finite input (`temp=nan`) counts as absent and takes the saved default.
            let requestedTemperature = queryItems?.first(where: { $0.name == "temp" || $0.name == "temperature" })?
                .value.flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil }
            let temperature = Self.clamped(requestedTemperature ?? context.defaultRemoteClimateTemperatureCelsius,
                                           to: Self.climateTemperatureRange)
            dispatch(.startClimate(temperatureCelsius: Float(temperature), frontLeftSeat: .off,
                                   frontRightSeat: .off, rearLeftSeat: .off,
                                   rearRightSeat: .off, steeringWheel: .off), targetVIN: targetVIN)

        case "climate/stop", "climatization/stop":
            dispatch(.stopClimate, targetVIN: targetVIN)

        case "lock":
            dispatch(.lock, targetVIN: targetVIN)

        case "lock-reduced-guard", "lock-reduced":
            dispatch(.lockReducedGuard, targetVIN: targetVIN)

        case "unlock":
            dispatch(.unlock, targetVIN: targetVIN)

        case "flash", "flash-lights":
            dispatch(.flashLights, targetVIN: targetVIN)

        case "honk-flash", "honk":
            dispatch(.honkAndFlash, targetVIN: targetVIN)

        case "horn":
            // Horn only. `honk` stays an alias for honk-and-flash so existing links keep working.
            dispatch(.honkHorn, targetVIN: targetVIN)

        case "precleaning/start":
            dispatch(.startPreCleaning, targetVIN: targetVIN)

        case "precleaning/stop":
            dispatch(.stopPreCleaning, targetVIN: targetVIN)

        case "windows/open":
            dispatch(.openWindows, targetVIN: targetVIN)

        case "windows/close":
            dispatch(.closeWindows, targetVIN: targetVIN)

        case "tailgate/open":
            dispatch(.openTailgate, targetVIN: targetVIN)

        case "tailgate/close":
            dispatch(.closeTailgate, targetVIN: targetVIN)

        case "trunk/unlock":
            dispatch(.unlockTrunk, targetVIN: targetVIN)

        case "charge-limit":
            // Pinned to the fallback range like the other charging links. The provider checks
            // the vehicle's own limits before anything is sent.
            guard let amps = queryItems?.first(where: { $0.name == "amps" })?.value.flatMap({ Int($0) }) else {
                refuseInvalidValue(L10n.text("The charging current must be a whole number of amperes, such as amps=16."))
                return
            }
            dispatch(.setAmpLimit(Self.clamped(amps, to: VehicleChargeBounds.fallbackAmperageRange)),
                     targetVIN: targetVIN)

        case "charging/override-start":
            dispatch(.startChargingOverride, targetVIN: targetVIN)

        case "charging/override-stop":
            dispatch(.stopChargingOverride, targetVIN: targetVIN)

        case "ota/install":
            dispatch(.installOTANow, targetVIN: targetVIN)

        case "ota/cancel":
            dispatch(.cancelOTA, targetVIN: targetVIN)

        case "ota/schedule":
            // Only the delays the Controls tab's schedule picker offers (2, 8 and 12 hours).
            guard let delay = queryItems?.first(where: { $0.name == "delay" })?.value.flatMap({ Int($0) }),
                  Self.otaScheduleDelayMinutes.contains(delay) else {
                refuseInvalidValue(L10n.text("Choose a delay of 120, 480 or 720 minutes."))
                return
            }
            dispatch(.scheduleOTA(delayMinutes: delay), targetVIN: targetVIN)

        case "engine/start":
            // An absent runtime takes the longest option, as the Controls tab does when nothing is
            // saved. A present value that is not one of the options is refused, never defaulted.
            let minutesText = queryItems?.first(where: { $0.name == "minutes" })?.value
            guard let minutes = minutesText == nil ? 15 : Int(minutesText ?? ""),
                  Self.engineRuntimeMinutes.contains(minutes) else {
                refuseInvalidValue(L10n.text("Engine runtime must be 5, 10 or 15 minutes."))
                return
            }
            dispatch(.startEngine(runtimeMinutes: minutes), targetVIN: targetVIN)

        case "engine/stop":
            dispatch(.stopEngine, targetVIN: targetVIN)

        case "charge-target":
            // Polestar-only: Volvo's official API exposes no charging writes.
            guard targetVIN != nil || context.activeBrand == .polestar else {
                context.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Volvo's official API does not support changing charge settings.")
                )
                return
            }
            let requestedPercent = queryItems?.first(where: { $0.name == "percent" || $0.name == "target" })?
                .value.flatMap { Int($0) } ?? 80
            let percent = Self.clamped(requestedPercent, to: VehicleChargeBounds.fallbackTargetRange)
            context.performRemoteCommand(.setChargeTarget(percent), targetVIN: targetVIN)

        case "charge-timer/set", "charging/timer-set":
            // Polestar-only, like the other charging writes.
            guard targetVIN != nil || context.activeBrand == .polestar else {
                context.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Volvo's official API does not support changing charge settings.")
                )
                return
            }
            guard let timer = Self.schedule(kind: .globalCharging, from: queryItems) else {
                refuseInvalidValue(L10n.text("A timer link needs start and stop times, for example start=07:30&stop=17:00."))
                return
            }
            context.performRemoteCommand(.setGlobalChargeTimer(timer), targetVIN: targetVIN)

        case "climate-timer/set", "climatization/timer-set":
            guard let timer = Self.schedule(kind: .climate, from: queryItems) else {
                refuseInvalidValue(L10n.text("A timer link needs start and stop times, for example start=07:30&stop=17:00."))
                return
            }
            context.performRemoteCommand(.setClimateTimer(timer), targetVIN: targetVIN)

        case "climate-timer/delete", "climatization/timer-delete":
            guard let id = Self.query("id", in: queryItems), !id.isEmpty else {
                refuseInvalidValue(L10n.text("A timer delete link needs the timer id, for example id=123."))
                return
            }
            context.performRemoteCommand(.deleteClimateTimer(id: id), targetVIN: targetVIN)

        case "charge-location/add":
            guard targetVIN != nil || context.activeBrand == .polestar else {
                context.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Volvo's official API does not support changing charge settings.")
                )
                return
            }
            let alias = Self.query("alias", in: queryItems) ?? ""
            guard !alias.isEmpty else {
                refuseInvalidValue(L10n.text("A charge-location link needs a name, for example alias=Home."))
                return
            }
            let amps = Self.clamped(Self.query("amps", in: queryItems).flatMap { Int($0) }
                                    ?? VehicleChargeBounds.fallbackAmperageRange.lowerBound,
                                    to: VehicleChargeBounds.fallbackAmperageRange)
            let soc = Self.clamped(Self.query("soc", in: queryItems).flatMap { Int($0) }
                                   ?? VehicleChargeBounds.fallbackTargetRange.lowerBound,
                                   to: VehicleChargeBounds.fallbackTargetRange)
            let optimised = Self.flag("optimised", in: queryItems, default: true)
            context.performRemoteCommand(
                .createChargeLocationAtCar(alias: alias, ampLimit: amps, minimumSoc: soc, optimisedCharging: optimised),
                targetVIN: targetVIN
            )

        case "charge-location/alias", "charge-location/rename":
            guard let (id, alias) = Self.locationIDAndText("alias", in: queryItems) else {
                refuseInvalidValue(L10n.text("A charge-location rename needs the location id and a name."))
                return
            }
            context.performRemoteCommand(.updateChargeLocationAlias(id: id, alias: alias), targetVIN: targetVIN)

        case "charge-location/amps":
            guard let id = Self.query("id", in: queryItems), !id.isEmpty,
                  let amps = Self.query("amps", in: queryItems).flatMap({ Int($0) }) else {
                refuseInvalidValue(L10n.text("A charge-location amps link needs the location id and amps."))
                return
            }
            let clamped = Self.clamped(amps, to: VehicleChargeBounds.fallbackAmperageRange)
            context.performRemoteCommand(.updateChargeLocationAmpLimit(id: id, amps: clamped), targetVIN: targetVIN)

        case "charge-location/soc":
            guard let id = Self.query("id", in: queryItems), !id.isEmpty,
                  let soc = Self.query("soc", in: queryItems).flatMap({ Int($0) }) else {
                refuseInvalidValue(L10n.text("A charge-location target link needs the location id and soc."))
                return
            }
            let clamped = Self.clamped(soc, to: VehicleChargeBounds.fallbackTargetRange)
            context.performRemoteCommand(.updateChargeLocationMinimumSoc(id: id, soc: clamped), targetVIN: targetVIN)

        case "charge-location/optimised":
            guard let id = Self.query("id", in: queryItems), !id.isEmpty else {
                refuseInvalidValue(L10n.text("A charge-location link needs the location id."))
                return
            }
            let enabled = Self.flag("enabled", in: queryItems, default: true)
            context.performRemoteCommand(.setChargeLocationOptimisedCharging(id: id, enabled: enabled), targetVIN: targetVIN)

        case "charge-location/delete":
            guard let id = Self.query("id", in: queryItems), !id.isEmpty else {
                refuseInvalidValue(L10n.text("A charge-location delete link needs the location id."))
                return
            }
            context.performRemoteCommand(.deleteChargeLocation(id: id), targetVIN: targetVIN)

        default:
            // Unknown commands are refused, never handed to a sign-in flow.
            logger.notice("Refused unrecognized hisingen:// command")
            context.notifyCommandNotice(
                title: L10n.text("Unknown Command"),
                body: L10n.text("Hisingen does not recognize that link.")
            )
        }
    }

    // MARK: - Deep-link payload parsing

    /// One query value, unescaped by `URLComponents` already. Empty strings are treated as absent
    /// so `?alias=` cannot create a nameless location.
    static func query(_ name: String, in items: [URLQueryItem]?) -> String? {
        guard let value = items?.first(where: { $0.name == name })?.value, !value.isEmpty else { return nil }
        return value
    }

    /// A boolean query, accepting the spellings a hand-written link or a Shortcut might use.
    static func flag(_ name: String, in items: [URLQueryItem]?, default fallback: Bool) -> Bool {
        guard let value = query(name, in: items)?.lowercased() else { return fallback }
        switch value {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return fallback
        }
    }

    /// `HH:MM` for one query name. Hours 0–23 and minutes 0–59; anything else is refused rather
    /// than nudged, because a timer at the wrong time is worse than a link that does nothing.
    static func time(_ name: String, in items: [URLQueryItem]?) -> (hour: Int, minute: Int)? {
        guard let text = query(name, in: items) else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// Weekdays as numbers (1 = Monday) or names (`mon`, `monday`), comma separated. An absent
    /// value means every day, matching how the app writes a timer with no weekday restriction.
    static func weekdays(in items: [URLQueryItem]?) -> [VehicleWeekday]? {
        guard let text = query("weekdays", in: items) else { return [] }
        let names: [String: VehicleWeekday] = [
            "mon": .monday, "monday": .monday, "tue": .tuesday, "tuesday": .tuesday,
            "wed": .wednesday, "wednesday": .wednesday, "thu": .thursday, "thursday": .thursday,
            "fri": .friday, "friday": .friday, "sat": .saturday, "saturday": .saturday,
            "sun": .sunday, "sunday": .sunday,
        ]
        var result: [VehicleWeekday] = []
        for token in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            if let number = Int(token), let day = VehicleWeekday(rawValue: number) {
                result.append(day)
            } else if let day = names[token] {
                result.append(day)
            } else {
                return nil
            }
        }
        return Array(Set(result)).sorted { $0.rawValue < $1.rawValue }
    }

    /// A complete timer from a link, or nil when either time is missing or malformed.
    static func schedule(kind: ScheduleKind, from items: [URLQueryItem]?) -> VehicleSchedule? {
        guard let start = time("start", in: items), let end = time("stop", in: items),
              let days = weekdays(in: items) else { return nil }
        return VehicleSchedule(
            kind: kind,
            startHour: start.hour, startMinute: start.minute,
            endHour: end.hour, endMinute: end.minute,
            weekdays: days,
            isActive: flag("active", in: items, default: true)
        )
    }

    /// A location id plus one text field, for the rename route.
    static func locationIDAndText(_ field: String, in items: [URLQueryItem]?) -> (id: String, text: String)? {
        guard let id = query("id", in: items), let text = query(field, in: items) else { return nil }
        return (id, text)
    }

    /// A link whose value the app cannot send. Refused locally, so nothing reaches a backend.
    private func refuseInvalidValue(_ body: String) {
        context?.notifyCommandNotice(title: L10n.text("Invalid Value"), body: body)
    }

    /// Pins a deep-link value to the range the app itself accepts, so an out-of-range URL
    /// gets the nearest valid value instead of reaching the provider.
    private static func clamped<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Deep-link command dispatch. Brand policy lives in `CapabilityGate` + the provider
    /// command catalog – the same single answer the Controls tab and Shortcuts intents get –
    /// so a deep link cannot contradict the in-app surface for the same command.
    private func dispatch(_ command: RemoteCommand, targetVIN: String?) {
        context?.performRemoteCommand(command, targetVIN: targetVIN)
    }
}
