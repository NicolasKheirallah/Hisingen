import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var latestState: VehicleState?
    private var latestError: String?
    private var authenticated = false
    private var settingsMode = false
    private var selectedTab: HisingenContentView.Tab = .vehicle
    private var pendingPopoverRefresh: Task<Void, Never>?
    private let database: VehicleDatabase
    private let reverseGeocoder: ReverseGeocoder
    private let imageCache: CarImageCache
    private let preferences: PreferencesStore

    var updateVersion: String?
    var checkingForUpdates = false
    /// Whether the popover is currently on screen. Callers outside AppKit view code use
    /// this to decide between in-panel feedback (banners) and system notifications.
    var isPopoverVisible: Bool { popover.isShown }
    var cars: [CarSummary] = []
    var activeVin: String?
    var diagnostics: DiagnosticsSnapshot?


    var cachedSnapshots: [String: VehicleState] = [:]
    var onSelectCar: ((String) -> Void)?
    var remoteCommandInProgress = false
    var onOpenPanel: (() -> Void)?
    private(set) var notificationPermission: NotificationPermission = .notDetermined

    var onRefresh: () -> Void = {}
    var onSettings: () -> Void = {}
    var onCheckForUpdates: () -> Void = {}
    var onOpenUpdate: () -> Void = {}
    var onRemoteCommand: (RemoteCommand) -> Void = { _ in }
    var onSettingsChanged: (SettingsChange) -> Void = { _ in }
    var onSignOut: () -> Void = {}
    var onTestConnection: (VehicleBrand) async -> (success: Bool, message: String) = { _ in
        (false, L10n.text("Connection testing is not available."))
    }

    private var selectedTabBinding: Binding<HisingenContentView.Tab> {
        Binding(
            get: { [weak self] in self?.selectedTab ?? .vehicle },
            set: { [weak self] value in self?.selectedTab = value }
        )
    }

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    /// When the popover last closed. In transient ("Close When Switching Apps") mode the
    /// system closes the panel *before* the click on the status item reaches this class,
    /// so a naive toggle would immediately reopen it — the guard swallows that same click.
    private var lastPopoverCloseDate: Date?

    @MainActor
    init(onRefresh: @escaping () -> Void = {},
         onSettings: @escaping () -> Void = {},
         onCheckForUpdates: @escaping () -> Void = {},
         onRemoteCommand: @escaping (RemoteCommand) -> Void = { _ in },
         database: VehicleDatabase = VehicleDatabase(),
         reverseGeocoder: ReverseGeocoder = ReverseGeocoder(),
         imageCache: CarImageCache = CarImageCache(),
         preferences: PreferencesStore) {
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.onCheckForUpdates = onCheckForUpdates
        self.onRemoteCommand = onRemoteCommand
        self.database = database
        self.reverseGeocoder = reverseGeocoder
        self.imageCache = imageCache
        self.preferences = preferences
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()
        let layout = PanelLayout.resolve(from: preferences)
        popover.contentSize = NSSize(width: layout.width, height: layout.height)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.car", accessibilityDescription: L10n.text("Hisingen"))
            button.imagePosition = .imageLeft
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = preferences.panelCloseBehavior.popoverBehavior
        popover.delegate = self
        if Bundle.main.bundleURL.pathExtension == "app" {
            popover.appearance = preferences.appearanceMode.nsAppearance
            installGlobalHotKey()
        }
        popover.contentSize = NSSize(width: layout.width, height: layout.height)
    }

    private func installGlobalHotKey() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        installLocalHotKey()
        guard AXIsProcessTrusted() else { return }
        installGlobalHotKeyIfAuthorized()
    }

    /// Only ever *installs* the monitor when accessibility is newly granted; never revokes.
    func refreshGlobalHotKeyAccess() {
        guard globalKeyMonitor == nil, AXIsProcessTrusted() else { return }
        installGlobalHotKeyIfAuthorized()
    }

    /// The hot-key combination: ⌃⌥ (Control+Option). Plain ⌥+[ / ⌥+1…9 were previously
    /// matched in the *global* monitor, which cannot consume events — so typing characters
    /// like "¡", "±", or "™" in any other app switched vehicles behind the user's back.
    /// Requiring Control as well makes the combination exclusive enough to be safe globally.
    private static let hotKeyModifiers: NSEvent.ModifierFlags = [.option, .control]

    private static func matchesHotKey(_ event: NSEvent, _ character: Character) -> Bool {
        // `charactersIgnoringModifiers` strips Option but keeps Control; compare against the
        // unmodified character so both plain and Option-shifted layouts resolve identically.
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              chars.first == character else { return false }
        let required = hotKeyModifiers
        return event.modifierFlags.isSuperset(of: required)
    }

    private func installGlobalHotKeyIfAuthorized() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if Self.matchesHotKey(event, "p") {
                Task { @MainActor in self.toggleFromHotKey() }
            } else if Self.matchesHotKey(event, "[") {
                Task { @MainActor in self.cycleVehicle(forward: false) }
            } else if Self.matchesHotKey(event, "]") {
                Task { @MainActor in self.cycleVehicle(forward: true) }
            } else if let digit = event.charactersIgnoringModifiers?.first?.wholeNumberValue,
                      digit >= 1 && digit <= 9,
                      Self.matchesHotKey(event, Character("\(digit)")) {
                Task { @MainActor in self.selectVehicleByIndex(digit - 1) }
            }
        }
    }

    private func installLocalHotKey() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if Self.matchesHotKey(event, "p") {
                self.toggleFromHotKey()
                return nil
            } else if Self.matchesHotKey(event, "[") {
                self.cycleVehicle(forward: false)
                return nil
            } else if Self.matchesHotKey(event, "]") {
                self.cycleVehicle(forward: true)
                return nil
            } else if let digit = event.charactersIgnoringModifiers?.first?.wholeNumberValue,
                      digit >= 1 && digit <= 9,
                      Self.matchesHotKey(event, Character("\(digit)")) {
                self.selectVehicleByIndex(digit - 1)
                return nil
            }
            return event
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    /// True when the popover was already closed by the *current* status-item click
    /// (transient auto-close fires before this action runs); treating that click as a
    /// toggle would instantly reopen the panel the user just dismissed. Only the button
    /// path consults this — the hot-key never triggers an outside-click auto-close.
    private var popoverJustClosedByThisClick: Bool {
        guard let closed = lastPopoverCloseDate else { return false }
        return Date().timeIntervalSince(closed) < 0.3
    }

    private func toggleFromHotKey() {
        togglePopover()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            if !popoverJustClosedByThisClick { showPopover() }
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else if popover.isShown {
            popover.performClose(nil)
        } else if !popoverJustClosedByThisClick {
            showPopover()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil) }
        lastPopoverCloseDate = nil
        let menu = NSMenu()

        if let state = latestState {
            let vehicleName = preferences.formattedVehicleTitle(
                vin: state.vin,
                modelName: state.modelName,
                modelYear: state.modelYear,
                registrationNo: state.registrationNo
            )
            let battery = state.batteryPercentage.map { String(format: "%.0f%%", $0) } ?? "--"
            let range = state.rangeKm.map {
                "\(preferences.distanceUnit.convert(km: $0)) \(preferences.distanceUnit.suffix)"
            } ?? "--"
            let summary = "\(vehicleName) · \(battery) (\(range))"
            let headerItem = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
            headerItem.attributedTitle = NSAttributedString(
                string: summary,
                attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
            )
            menu.addItem(headerItem)

            if state.isCharging {
                let power = state.chargingPowerWatts.map { Format.kilowatts(watts: $0) } ?? ""
                let title = power.isEmpty
                    ? "⚡ \(L10n.text("Charging Active"))"
                    : "⚡ \(L10n.format("Charging at %@", power))"
                menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            }

            if let locked = state.exteriorStatus?.isLocked {
                let title = locked ? L10n.text("Vehicle Locked") : L10n.text("Vehicle Unlocked")
                menu.addItem(withTitle: "\(locked ? "🔒" : "🔓") \(title)", action: nil, keyEquivalent: "")
            }
            menu.addItem(.separator())
        }

        let refreshItem = menu.addItem(
            withTitle: L10n.text("Refresh Telemetry"),
            action: #selector(contextRefresh),
            keyEquivalent: "r"
        )
        refreshItem.target = self

        if let location = latestState?.location,
           location.latitude != nil, location.longitude != nil {
            let mapsItem = menu.addItem(
                withTitle: L10n.text("Open in Apple Maps"),
                action: #selector(contextOpenMaps),
                keyEquivalent: "l"
            )
            mapsItem.target = self
        }

        if let vin = latestState?.vin, !vin.isEmpty {
            let copyItem = menu.addItem(
                withTitle: L10n.format("Copy VIN (%@)…", String(vin.prefix(8))),
                action: #selector(contextCopyVIN),
                keyEquivalent: ""
            )
            copyItem.target = self
        }

        let otherBrand: VehicleBrand = preferences.activeBrand == .polestar ? .volvo : .polestar
        let otherBrandResumable = preferences.hasResumableSession(for: otherBrand)
        let vins = availableVehicleVINs

        if vins.count > 1 || otherBrandResumable {
            let switchMenu = NSMenu()
            for (index, vin) in vins.enumerated() {
                let snapshot = cachedSnapshots[vin] ?? (vin == latestState?.vin ? latestState : nil)
                let name: String = {
                    if let snapshot {
                        return preferences.formattedVehicleTitle(
                            vin: snapshot.vin, modelName: snapshot.modelName, modelYear: snapshot.modelYear, registrationNo: snapshot.registrationNo, fallbackBrand: snapshot.model.brand
                        )
                    }
                    if let car = cars.first(where: { $0.vin == vin }) {
                        return car.displayTitle()
                    }
                    return vin
                }()
                let battery = snapshot?.batteryPercentage.map { " · \(Int($0))%" } ?? ""
                let shortcut = index < 9 ? "⌃⌥\(index + 1)" : ""
                let title = shortcut.isEmpty
                    ? "\(name)\(battery) (\(vin.prefix(8))...)"
                    : "\(name)\(battery) (\(vin.prefix(8))...)   [\(shortcut)]"
                let item = NSMenuItem(title: title, action: #selector(contextSwitchCar(_:)), keyEquivalent: "")
                item.representedObject = vin
                item.state = vin == activeVin ? .on : .off
                item.target = self
                switchMenu.addItem(item)
            }
            if otherBrandResumable, !vins.contains(where: { cachedSnapshots[$0]?.model.brand == otherBrand }) {
                if !vins.isEmpty { switchMenu.addItem(.separator()) }
                let label = preferences.lastVehicleLabel(for: otherBrand)
                let item = NSMenuItem(
                    title: L10n.format("Switch to %@ (%@)…", otherBrand.displayName, label),
                    action: #selector(contextSwitchBrand(_:)), keyEquivalent: ""
                )
                item.representedObject = otherBrand.rawValue
                item.target = self
                switchMenu.addItem(item)
            }
            let switchItem = menu.addItem(
                withTitle: L10n.text("Switch Vehicle (⌃⌥[ / ⌃⌥])"),
                action: nil,
                keyEquivalent: ""
            )
            switchItem.submenu = switchMenu
        }

        if let state = latestState {
            let isVolvo = preferences.activeBrand == .volvo
            let controlsMenu = NSMenu()

            if isVolvo {
                let isLocked = state.exteriorStatus?.isLocked == true
                let lockItem = NSMenuItem(
                    title: isLocked ? L10n.text("Unlock Doors") : L10n.text("Lock Doors"),
                    action: #selector(contextToggleLock),
                    keyEquivalent: ""
                )
                lockItem.target = self
                controlsMenu.addItem(lockItem)

                let climateActive = state.climateStatus?.activity == .active
                    || state.climateStatus?.activity == .heating
                    || state.climateStatus?.activity == .cooling
                    || state.climateStatus?.activity == .ventilating
                let climateItem = NSMenuItem(
                    title: climateActive ? L10n.text("Stop Climate") : L10n.format("Start Climate (%@)", Format.temperature(celsius: preferences.remoteClimateTemperature, unit: preferences.temperatureUnit, decimals: 0)),
                    action: #selector(contextToggleClimate),
                    keyEquivalent: ""
                )
                climateItem.target = self
                controlsMenu.addItem(climateItem)

                let flashItem = NSMenuItem(
                    title: L10n.text("Flash Lights"),
                    action: #selector(contextFlashLights),
                    keyEquivalent: ""
                )
                flashItem.target = self
                controlsMenu.addItem(flashItem)

                let honkItem = NSMenuItem(
                    title: L10n.text("Honk Horn"),
                    action: #selector(contextHonkHorn),
                    keyEquivalent: ""
                )
                honkItem.target = self
                controlsMenu.addItem(honkItem)

                let honkFlashItem = NSMenuItem(
                    title: L10n.text("Honk & Flash"),
                    action: #selector(contextHonkAndFlash),
                    keyEquivalent: ""
                )
                honkFlashItem.target = self
                controlsMenu.addItem(honkFlashItem)
            } else {
                // Polestar quick controls
                let isLocked = state.exteriorStatus?.isLocked == true
                let lockItem = NSMenuItem(
                    title: isLocked ? L10n.text("Unlock Doors") : L10n.text("Lock Doors"),
                    action: #selector(contextToggleLock),
                    keyEquivalent: ""
                )
                lockItem.target = self
                controlsMenu.addItem(lockItem)

                // Tailgate toggle if supported
                if state.otaCapabilities?.supportsTrunkControl == true {
                    let tailgateIsOpen = state.exteriorStatus?.isTailgateOpen ?? false
                    let tailgateItem = NSMenuItem(
                        title: tailgateIsOpen ? L10n.text("Close Tailgate") : L10n.text("Open Tailgate"),
                        action: #selector(contextToggleTailgate),
                        keyEquivalent: ""
                    )
                    tailgateItem.target = self
                    controlsMenu.addItem(tailgateItem)
                }

                // Trunk unlock if supported
                if state.otaCapabilities?.supportsTrunkUnlock == true {
                    let trunkItem = NSMenuItem(
                        title: L10n.text("Unlock Trunk"),
                        action: #selector(contextUnlockTrunk),
                        keyEquivalent: ""
                    )
                    trunkItem.target = self
                    controlsMenu.addItem(trunkItem)
                }

                controlsMenu.addItem(.separator())

                let climateActive = state.climateStatus?.activity == .active
                    || state.climateStatus?.activity == .heating
                    || state.climateStatus?.activity == .cooling
                    || state.climateStatus?.activity == .ventilating
                let climateItem = NSMenuItem(
                    title: climateActive ? L10n.text("Stop Climate") : L10n.format("Start Climate (%@)", Format.temperature(celsius: preferences.remoteClimateTemperature, unit: preferences.temperatureUnit, decimals: 0)),
                    action: #selector(contextToggleClimate),
                    keyEquivalent: ""
                )
                climateItem.target = self
                controlsMenu.addItem(climateItem)

                let flashItem = NSMenuItem(
                    title: L10n.text("Flash Lights"),
                    action: #selector(contextFlashLights),
                    keyEquivalent: ""
                )
                flashItem.target = self
                controlsMenu.addItem(flashItem)

                let honkFlashItem = NSMenuItem(
                    title: L10n.text("Honk & Flash"),
                    action: #selector(contextHonkAndFlash),
                    keyEquivalent: ""
                )
                honkFlashItem.target = self
                controlsMenu.addItem(honkFlashItem)
            }

            let remoteSection = menu.addItem(withTitle: L10n.text("Quick Controls"), action: nil, keyEquivalent: "")
            remoteSection.submenu = controlsMenu

            if !state.chargingSessions.isEmpty {
                let exportItem = menu.addItem(
                    withTitle: L10n.text("Export Charging History (CSV)…"),
                    action: #selector(contextExportChargingCSV),
                    keyEquivalent: ""
                )
                exportItem.target = self
            }
        }

        // Quick panel geometry switching without a trip into Settings → General.
        // Mirrors the Settings writes exactly (preset clears any custom override);
        // applyPopoverRefresh resizes an open dropdown on the next runloop tick.
        let sizeMenu = NSMenu()
        for size in PanelSize.allCases {
            let item = NSMenuItem(
                title: "\(size.title)  (\(size.dimensionsLabel))",
                action: #selector(contextSetPanelSize(_:)),
                keyEquivalent: ""
            )
            item.representedObject = size.rawValue
            item.state = (!preferences.customPanelSizeEnabled && preferences.panelSize == size) ? .on : .off
            item.target = self
            sizeMenu.addItem(item)
        }
        let sizeItem = menu.addItem(withTitle: L10n.text("Panel Size"), action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu

        let densityMenu = NSMenu()
        for density in ContentDensity.allCases {
            let item = NSMenuItem(
                title: density.title,
                action: #selector(contextSetContentDensity(_:)),
                keyEquivalent: ""
            )
            item.representedObject = density.rawValue
            item.state = preferences.contentDensity == density ? .on : .off
            item.target = self
            densityMenu.addItem(item)
        }
        let densityItem = menu.addItem(withTitle: L10n.text("Content Density"), action: nil, keyEquivalent: "")
        densityItem.submenu = densityMenu

        menu.addItem(.separator())
        let updateItem = menu.addItem(
            withTitle: updateVersion.map { L10n.format("Update Available: Hisingen %@", $0) }
                ?? L10n.text("Check for Updates…"),
            action: #selector(contextCheckForUpdates), keyEquivalent: ""
        )
        updateItem.target = self
        let settingsItem = menu.addItem(
            withTitle: L10n.text("Preferences…"),
            action: #selector(contextSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        let quitItem = menu.addItem(
            withTitle: L10n.text("Quit Hisingen"),
            action: #selector(contextQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func contextOpenMaps() {
        guard let location = latestState?.location,
              let latitude = location.latitude,
              let longitude = location.longitude else { return }
        guard let url = Self.appleMapsURL(
            latitude: latitude,
            longitude: longitude,
            label: preferences.activeBrand.displayName
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    static func appleMapsURL(latitude: Double, longitude: Double, label: String) -> URL? {
        MapLinks.appleMapsPin(latitude: latitude, longitude: longitude, label: label)
    }

    @objc private func contextCopyVIN() {
        guard let vin = latestState?.vin, !vin.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(vin, forType: .string)
    }

    @objc private func contextSwitchCar(_ sender: NSMenuItem) {
        guard let vin = sender.representedObject as? String else { return }
        selectCar(vin)
    }

    @objc private func contextSwitchBrand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let brand = VehicleBrand(rawValue: raw) else { return }
        onSettingsChanged(.switchToBrand(brand))
    }

    @objc private func contextSetPanelSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = PanelSize(rawValue: raw) else { return }
        preferences.panelSize = size
        // A picked preset replaces any custom override, matching Settings behavior.
        preferences.customPanelSizeEnabled = false
        refreshPopoverIfNeeded()
    }

    @objc private func contextSetContentDensity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let density = ContentDensity(rawValue: raw) else { return }
        preferences.contentDensity = density
        refreshPopoverIfNeeded()
    }

    @objc private func contextSettings() {
        onSettings()
    }

    @objc private func contextRefresh() {
        onRefresh()
    }

    @objc private func contextCheckForUpdates() {
        if updateVersion != nil { onOpenUpdate() } else { onCheckForUpdates() }
    }

    @objc private func contextQuit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func contextToggleLock() {
        let isLocked = latestState?.exteriorStatus?.isLocked == true
        onRemoteCommand(isLocked ? .unlock : .lock)
    }

    @objc private func contextToggleTailgate() {
        let tailgateIsOpen = latestState?.exteriorStatus?.isTailgateOpen ?? false
        onRemoteCommand(tailgateIsOpen ? .closeTailgate : .openTailgate)
    }

    @objc private func contextUnlockTrunk() {
        onRemoteCommand(.unlockTrunk)
    }

    @objc private func contextToggleClimate() {
        let climateActive = latestState?.climateStatus?.activity == .active
            || latestState?.climateStatus?.activity == .heating
            || latestState?.climateStatus?.activity == .cooling
            || latestState?.climateStatus?.activity == .ventilating
        if climateActive {
            onRemoteCommand(.stopClimate)
        } else {
            let temp = Float(preferences.remoteClimateTemperature)
            onRemoteCommand(.startClimate(temperatureCelsius: temp, frontLeftSeat: .off, frontRightSeat: .off, rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .off))
        }
    }

    @objc private func contextFlashLights() {
        onRemoteCommand(.flashLights)
    }

    @objc private func contextHonkHorn() {
        onRemoteCommand(.honkHorn)
    }

    @objc private func contextHonkAndFlash() {
        guard preferences.activeBrand == .volvo else { return }
        onRemoteCommand(.honkAndFlash)
    }

    @objc private func contextExportChargingCSV() {
        guard let state = latestState, !state.chargingSessions.isEmpty else { return }
        let csvData = ChargingHistoryExport.csv(
            sessions: state.chargingSessions,
            tariffPricePerKwh: preferences.electricityPricePerKwh,
            currencySymbol: preferences.currencySymbol
        )

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "charging_history_\(state.vin.prefix(8)).csv"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? csvData.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    func showSettings() {
        settingsMode = true
        if popover.isShown {
            refreshPopoverIfNeeded()
        } else {
            showPopover()
        }
    }

    func toggleSettings() {
        settingsMode.toggle()
        if popover.isShown {
            refreshPopoverIfNeeded()
        } else {
            showPopover()
        }
    }

    func dismissSettings() {
        settingsMode = false
        if popover.isShown {
            refreshPopoverIfNeeded()
        }
    }

    func updateNotificationPermission(_ permission: NotificationPermission) {
        notificationPermission = permission
        refreshPopoverIfNeeded()
    }

    private func showPopover() {
        guard !popover.isShown else { return }
         popover.appearance = preferences.appearanceMode.nsAppearance
        // Resolve fresh every open: close behavior, preset/density/custom overrides may
        // have changed since init or since the last refresh while shown.
        popover.behavior = preferences.panelCloseBehavior.popoverBehavior
        let layout = PanelLayout.resolve(from: preferences)
        popover.contentSize = NSSize(width: layout.width, height: layout.height)
        let hosting = NSHostingController(rootView: makeRootView())
        popover.contentViewController = hosting
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        // Apple Liquid Glass: clear the popover's opaque backing so SwiftUI materials
        // sample the real content behind the window (same pattern as ChargingMiniPanel).
        if let window = hosting.view.window {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }

    func openPopover() {
        showPopover()
    }

    static func availableVehicleVINs(cars: [CarSummary], cachedSnapshots: [String: VehicleState]) -> [String] {
        var set = Set<String>()
        var list: [String] = []
        for car in cars {
            if set.insert(car.vin).inserted {
                list.append(car.vin)
            }
        }
        for (vin, _) in cachedSnapshots {
            if set.insert(vin).inserted {
                list.append(vin)
            }
        }
        return list
    }

    var availableVehicleVINs: [String] {
        Self.availableVehicleVINs(cars: cars, cachedSnapshots: cachedSnapshots)
    }

    private func selectCar(_ vin: String) {
        activeVin = vin
        onSelectCar?(vin)
    }

    func cycleVehicle(forward: Bool) {
        let vins = availableVehicleVINs
        guard vins.count > 1 else { return }
        let currentIndex = vins.firstIndex(of: activeVin ?? vins.first ?? "") ?? 0
        let nextIndex = forward
            ? (currentIndex + 1) % vins.count
            : (currentIndex - 1 + vins.count) % vins.count
        selectCar(vins[nextIndex])
    }

    func selectVehicleByIndex(_ index: Int) {
        let vins = availableVehicleVINs
        guard index >= 0 && index < vins.count else { return }
        selectCar(vins[index])
    }

    func showLoading() {
        if latestState == nil { statusItem.button?.title = " …" }
        statusItem.button?.setAccessibilityLabel(L10n.text("Hisingen, refreshing"))
    }

    func render(data: VehicleState?, error: String?, authenticated: Bool, diagnostics: DiagnosticsSnapshot? = nil) {
        latestState = data
        latestError = error
        self.authenticated = authenticated
        if let diagnostics { self.diagnostics = diagnostics }
        let title = barTitle(for: data)
         let iconName = Format.icon(for: data, includeConnection: preferences.features.contains(.chargingDetails))
        var icon = NSImage(systemSymbolName: iconName, accessibilityDescription: L10n.text("Hisingen"))
        if preferences.tintMenuBarIcon, let data {
            let tintColor: NSColor = data.isCharging ? .systemGreen : ((data.batteryPercentage ?? 100) <= 20 ? .systemOrange : .controlAccentColor)
            if let configured = icon?.withSymbolConfiguration(.init(paletteColors: [tintColor])) {
                icon = configured
                icon?.isTemplate = false
            }
        } else {
            icon?.isTemplate = true
        }


        let isStale = data?.isStale() ?? false
        icon = dimmed(icon, when: isStale)
        statusItem.button?.image = icon
        setStatusBarTitle(title, for: data)
        statusItem.button?.setAccessibilityLabel(accessibilitySummary(data: data, title: title))
        updateFleetToolTip(activeState: data)
        refreshPopoverIfNeeded()
    }

    private func updateFleetToolTip(activeState: VehicleState?) {
        var lines: [String] = []
        let currentVin = activeState?.vin ?? activeVin ?? preferences.vin
        let vins = availableVehicleVINs
        for vin in vins {
            let state = (vin == activeState?.vin ? activeState : nil) ?? cachedSnapshots[vin]
            let name = preferences.formattedVehicleTitle(
                vin: vin,
                modelName: state?.modelName,
                modelYear: state?.modelYear,
                registrationNo: state?.registrationNo,
                fallbackBrand: state?.model.brand
            )
            var parts: [String] = [name]
            if let battery = state?.batteryPercentage {
                var batStr = String(format: "%.0f%%", battery)
                if state?.isCharging == true {
                    batStr += " ⚡"
                }
                parts.append(batStr)
            } else if let fuel = state?.fuelLevelPercent {
                parts.append(String(format: "%.0f%% fuel", fuel))
            }
            if let range = state?.primaryRangeKm {
                parts.append(Format.distance(km: range, unit: preferences.distanceUnit))
            }
            if let locked = state?.exteriorStatus?.isLocked {
                parts.append(locked ? "Locked" : "Unlocked ⚠️")
            }
            let isCurrent = (vin == currentVin)
            let prefix = isCurrent ? "● " : "○ "
            lines.append(prefix + parts.joined(separator: " · "))
        }
        statusItem.button?.toolTip = lines.isEmpty ? "Hisingen" : lines.joined(separator: "\n")
    }

    private func setStatusBarTitle(_ title: String, for data: VehicleState?) {
        guard let button = statusItem.button else { return }
        guard preferences.menuBarStyle == .lockAndBattery,
              let symbolName = Format.lockStatusSymbol(for: data),
              let isLocked = data?.exteriorStatus?.isLocked,
              let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        else {
            button.title = title.isEmpty ? "" : " " + title
            return
        }

        let color: NSColor = isLocked ? .secondaryLabelColor : .systemOrange
        let pointSize: CGFloat = isLocked ? 12 : 14
        let symbol = image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
                .applying(.init(paletteColors: [color]))
        ) ?? image
        symbol.isTemplate = false

        let attachment = NSTextAttachment()
        attachment.image = symbol
        attachment.bounds = NSRect(x: 0, y: -2, width: pointSize, height: pointSize)

        let renderedTitle = NSMutableAttributedString(string: " ")
        renderedTitle.append(NSAttributedString(attachment: attachment))
        renderedTitle.append(NSAttributedString(
            string: title.isEmpty ? "" : "  \(title)",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]
        ))
        button.attributedTitle = renderedTitle
    }

    private func dimmed(_ image: NSImage?, when isStale: Bool) -> NSImage? {
        guard let image, isStale else { return image }
        let wasTemplate = image.isTemplate
        let faded = NSImage(size: image.size)
        faded.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size),
                    from: .zero, operation: .sourceOver, fraction: 0.4)
        faded.unlockFocus()
        faded.isTemplate = wasTemplate
        return faded
    }

    func refreshPopoverIfNeeded() {
        guard popover.isShown else { return }
        guard pendingPopoverRefresh == nil else { return }
        pendingPopoverRefresh = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.pendingPopoverRefresh = nil
            self?.applyPopoverRefresh()
        }
    }

    /// Single home for the popover's SwiftUI tree construction. `showPopover` and
    /// `applyPopoverRefresh` were previously two verbatim copies of these ~30 lines, already
    /// drifting in their trailing statements.
    private func makeRootView() -> AnyView {
        AnyView(HisingenContentView(
            state: latestState,
            error: latestError,
            authenticated: authenticated,
            cars: cars,
            activeVin: activeVin,
            cachedSnapshots: cachedSnapshots,
            remoteCommandInProgress: remoteCommandInProgress,
            updateVersion: updateVersion,
            checkingForUpdates: checkingForUpdates,
            notificationPermission: notificationPermission,
            diagnostics: diagnostics,
            onRefresh: { [weak self] in self?.onRefresh() },
            onSettings: { [weak self] in self?.toggleSettings() },
            onCheckForUpdates: { [weak self] in self?.onCheckForUpdates() },
            onOpenUpdate: { [weak self] in self?.onOpenUpdate() },
            onRemoteCommand: { [weak self] cmd in self?.onRemoteCommand(cmd) },
            onSelectCar: { [weak self] vin in self?.selectCar(vin) },
            onSettingsChanged: { [weak self] change in self?.onSettingsChanged(change) },
            onSignOut: { [weak self] in self?.onSignOut() },
            onTestConnection: { [weak self] brand in
                await self?.onTestConnection(brand) ?? (false, L10n.text("Connection testing is not available."))
            },
            settingsMode: settingsMode,
            selectedTab: selectedTabBinding,
            database: database,
             reverseGeocoder: reverseGeocoder, imageCache: imageCache
        ).environment(\.preferencesStore, preferences))
    }

    private func applyPopoverRefresh() {
        guard popover.isShown, let hosting = popover.contentViewController as? NSHostingController<AnyView> else { return }
         popover.appearance = preferences.appearanceMode.nsAppearance
        // Live-apply the close behavior so switching modes in Settings takes effect on
        // the open panel without closing it first.
        popover.behavior = preferences.panelCloseBehavior.popoverBehavior
        // Re-apply the resolved panel geometry so an open dropdown resizes live when
        // the user switches presets, drags a custom slider, or changes density.
        // (The SwiftUI frames react via @AppStorage on their own; this keeps the
        // NSPopover window itself in sync.)
        let layout = PanelLayout.resolve(from: preferences)
        popover.contentSize = NSSize(width: layout.width, height: layout.height)
        hosting.preferredContentSize = NSSize(width: layout.width, height: layout.height)
        hosting.rootView = makeRootView()
    }

    private func barTitle(for data: VehicleState?) -> String {
        Format.barTitle(
            for: data,
            style: preferences.menuBarStyle,
            unit: preferences.distanceUnit,
            includeChargingContext: preferences.features.contains(.chargingDetails)
        )
    }

    private func accessibilitySummary(data: VehicleState?, title: String) -> String {
        guard let data else { return L10n.text("Hisingen, no vehicle data") }
        let security = data.exteriorStatus?.isLocked.map {
            $0 ? L10n.text("Vehicle Locked") : L10n.text("Vehicle Unlocked")
        }
        let summary = [title.nilIfEmpty, security].compactMap { $0 }.joined(separator: ", ")
        if data.isStale() {
            return L10n.format("Hisingen, %@, %@, data may be stale", summary, data.chargingState.displayName)
        }
        return L10n.format("Hisingen, %@, %@", summary, data.chargingState.displayName)
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        lastPopoverCloseDate = Date()
        settingsMode = false
        // Tear the SwiftUI tree down with the popover: hidden views kept running geocode
        // tasks and pulse animations, and the copied snapshot dictionaries stayed alive
        // until the next rootView replacement. The tree is rebuilt by `showPopover`.
        popover.contentViewController = nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
