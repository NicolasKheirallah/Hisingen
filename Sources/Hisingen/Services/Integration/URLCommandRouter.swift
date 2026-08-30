import AppKit

/// What the URL router needs from the app shell. The router owns URL parsing and the dispatch
/// table; every actual effect (selecting a vehicle, toggling the popover, sending a command)
/// is a call back through here.
@MainActor
protocol URLCommandRouterContext: AnyObject {
    /// VIN of the currently displayed vehicle, for `hisingen://copy-vin`.
    var selectedVehicleVIN: String? { get }
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
    func performRemoteCommand(_ command: RemoteCommand)
    /// A "not available on this brand" notice for a deep-link command the active brand can't run.
    func notifyCommandNotice(title: String, body: String)
}

/// Translates inbound `hisingen://…` URLs (and the Polestar `polestar-explore://` OAuth
/// redirect) into calls on the rest of the app: vehicle selection, popover / settings
/// toggles, manual refresh, VIN-to-clipboard, and the deep-link remote commands
/// (`hisingen://lock`, `hisingen://climate/start?temp=21`, `hisingen://charge-target?percent=80`, …).
///
/// Extracted from `AppDelegate`, which was the URL parser, the Apple Event target, and the
/// dispatch table all at once. Owns the `kAEGetURL` Apple Event registration too, so the
/// system-browser redirect and the `application(_:open:)` path share one entry point.
@MainActor
final class URLCommandRouter: NSObject {
    private weak var context: (any URLCommandRouterContext)?

    init(context: any URLCommandRouterContext) {
        self.context = context
        super.init()
    }

    /// Registers for the `GetURL` Apple Event — `hisingen://…` opened while the app is already
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
                                         withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        route(url)
    }

    func route(_ url: URL) {
        guard let context else { return }

        if url.scheme?.lowercased() == "polestar-explore" {
            context.handleOAuthCallback(url)
            return
        }
        guard url.scheme?.lowercased() == "hisingen" else { return }

        if url.host == "oauth" || url.path.contains("callback") || url.query?.contains("code=") == true {
            context.handleOAuthCallback(url)
            return
        }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let command = host.isEmpty ? path : (path.isEmpty ? host : "\(host)/\(path)")
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems

        // A `?vin=` query applies to every command, not just the switch verbs.
        if let targetVin = queryItems?.first(where: { $0.name == "vin" })?.value, !targetVin.isEmpty {
            context.selectVehicle(vin: targetVin)
        }

        switch command {
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

        case "copy-vin":
            if let vin = context.selectedVehicleVIN, !vin.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(vin, forType: .string)
            }

        case "climate/start", "climatization/start":
            let temp = queryItems?.first(where: { $0.name == "temp" || $0.name == "temperature" })?
                .value.flatMap { Float($0) } ?? Float(context.defaultRemoteClimateTemperatureCelsius)
            dispatchVolvoWrite(.startClimate(temperatureCelsius: temp, frontLeftSeat: .off,
                                             frontRightSeat: .off, rearLeftSeat: .off,
                                             rearRightSeat: .off, steeringWheel: .off))

        case "climate/stop", "climatization/stop":
            dispatchVolvoWrite(.stopClimate)

        case "lock":
            dispatchVolvoWrite(.lock)

        case "unlock":
            dispatchVolvoWrite(.unlock)

        case "flash", "flash-lights":
            dispatchVolvoWrite(.flashLights)

        case "honk-flash", "honk":
            dispatchVolvoWrite(.honkAndFlash)

        case "charge-target":
            // Polestar-only: Volvo's official API exposes no charging writes.
            guard context.activeBrand == .polestar else {
                context.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Volvo's official API does not support changing charge settings.")
                )
                return
            }
            let percent = queryItems?.first(where: { $0.name == "percent" || $0.name == "target" })?
                .value.flatMap { Int($0) } ?? 80
            context.performRemoteCommand(.setChargeTarget(percent))

        default:
            context.handleOAuthCallback(url)
        }
    }

    /// Volvo is the only brand whose official API accepts remote write commands; on Polestar
    /// the deep link is acknowledged with an explanatory notice instead.
    private func dispatchVolvoWrite(_ command: RemoteCommand) {
        guard let context else { return }
        if context.activeBrand == .volvo {
            context.performRemoteCommand(command)
        } else {
            // Polestar blocks remote *write* commands from anything but a paired mobile device.
            context.notifyCommandNotice(
                title: L10n.text("Command Restricted"),
                body: L10n.text("Polestar restricts remote write commands to paired mobile devices.")
            )
        }
    }
}
