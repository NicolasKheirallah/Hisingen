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
    private var monitor: AnyObject?
    private var settingsMode = false

    var updateVersion: String?
    var checkingForUpdates = false
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
    var onTestConnection: () -> Void = {}

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    init(onRefresh: @escaping () -> Void, onSettings: @escaping () -> Void,
         onCheckForUpdates: @escaping () -> Void,
         onRemoteCommand: @escaping (RemoteCommand) -> Void) {
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.onCheckForUpdates = onCheckForUpdates
        self.onRemoteCommand = onRemoteCommand
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.car", accessibilityDescription: L10n.text("Hisingen"))
            button.imagePosition = .imageLeft
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .semitransient
        popover.delegate = self
        popover.contentSize = NSSize(width: HisingenTheme.popoverWidth, height: 560)
        installGlobalHotKey()
    }

    private func installGlobalHotKey() {


        installLocalHotKey()
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        installGlobalHotKeyIfAuthorized()
    }

    func refreshGlobalHotKeyAccess() {
        guard globalKeyMonitor == nil, AXIsProcessTrusted() else { return }
        installGlobalHotKeyIfAuthorized()
    }

    private func installGlobalHotKeyIfAuthorized() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.option) else { return }
            let chars = event.charactersIgnoringModifiers?.lowercased()
            if chars == "p" {
                Task { @MainActor in self.toggleFromHotKey() }
            } else if chars == "[" {
                Task { @MainActor in self.cycleVehicle(forward: false) }
            } else if chars == "]" {
                Task { @MainActor in self.cycleVehicle(forward: true) }
            } else if let digit = chars?.first?.wholeNumberValue, digit >= 1 && digit <= 9 {
                Task { @MainActor in self.selectVehicleByIndex(digit - 1) }
            }
        }
    }

    private func installLocalHotKey() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.option) else { return event }
            let chars = event.charactersIgnoringModifiers?.lowercased()
            if chars == "p" {
                self.toggleFromHotKey()
                return nil
            } else if chars == "[" {
                self.cycleVehicle(forward: false)
                return nil
            } else if chars == "]" {
                self.cycleVehicle(forward: true)
                return nil
            } else if let digit = chars?.first?.wholeNumberValue, digit >= 1 && digit <= 9 {
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

    private func toggleFromHotKey() {
        togglePopover()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            showPopover()
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil) }
        let menu = NSMenu()

        if let state = latestState {
            let nickname = Preferences.vehicleNickname(for: state.vin)
            let vehicleName = [nickname.isEmpty ? nil : nickname, state.modelName]
                .compactMap { $0 }.first ?? Preferences.activeBrand.displayName
            let battery = state.batteryPercentage.map { String(format: "%.0f%%", $0) } ?? "--"
            let range = state.rangeKm.map {
                "\(Preferences.distanceUnit.convert(km: $0)) \(Preferences.distanceUnit.suffix)"
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

        let otherBrand: VehicleBrand = Preferences.activeBrand == .polestar ? .volvo : .polestar
        let otherBrandResumable = Preferences.hasResumableSession(for: otherBrand)

        if cars.count > 1 || otherBrandResumable {
            let switchMenu = NSMenu()
            for (index, car) in cars.enumerated() {
                let name = car.title.isEmpty ? Preferences.activeBrand.displayName : car.title
                let battery = cachedSnapshots[car.vin]?.batteryPercentage.map { " · \(Int($0))%" } ?? ""
                let shortcut = index < 9 ? "⌥\(index + 1)" : ""
                let title = shortcut.isEmpty
                    ? "\(name)\(battery) (\(car.vin.prefix(8))...)"
                    : "\(name)\(battery) (\(car.vin.prefix(8))...)   [\(shortcut)]"
                let item = NSMenuItem(title: title, action: #selector(contextSwitchCar(_:)), keyEquivalent: "")
                item.representedObject = car.vin
                item.state = car.vin == activeVin ? .on : .off
                item.target = self
                switchMenu.addItem(item)
            }
            if otherBrandResumable {
                if !cars.isEmpty { switchMenu.addItem(.separator()) }
                let label = Preferences.lastVehicleLabel(for: otherBrand)
                let item = NSMenuItem(
                    title: L10n.format("Switch to %@ (%@)…", otherBrand.displayName, label),
                    action: #selector(contextSwitchBrand(_:)), keyEquivalent: ""
                )
                item.representedObject = otherBrand.rawValue
                item.target = self
                switchMenu.addItem(item)
            }
            let switchItem = menu.addItem(
                withTitle: L10n.text("Switch Vehicle (⌥[ / ⌥])"),
                action: nil,
                keyEquivalent: ""
            )
            switchItem.submenu = switchMenu
        }

        if let state = latestState {
            let isVolvo = Preferences.activeBrand == .volvo
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
                    title: climateActive ? L10n.text("Stop Climate") : L10n.format("Start Climate (%@)", "\(Int(Preferences.remoteClimateTemperature)) °C"),
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
                let infoItem = NSMenuItem(
                    title: L10n.text("Remote controls restricted to paired mobile devices"),
                    action: nil,
                    keyEquivalent: ""
                )
                infoItem.isEnabled = false
                controlsMenu.addItem(infoItem)
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

        menu.addItem(.separator())
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
              let longitude = location.longitude,
              let label = Preferences.activeBrand.displayName
                  .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "maps://?q=\(label)&ll=\(latitude),\(longitude)") else { return }
        NSWorkspace.shared.open(url)
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

    @objc private func contextSettings() {
        onSettings()
    }

    @objc private func contextRefresh() {
        onRefresh()
    }

    @objc private func contextQuit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func contextToggleLock() {
        guard Preferences.activeBrand == .volvo else { return }
        let isLocked = latestState?.exteriorStatus?.isLocked == true
        onRemoteCommand(isLocked ? .unlock : .lock)
    }

    @objc private func contextToggleClimate() {
        guard Preferences.activeBrand == .volvo else { return }
        let climateActive = latestState?.climateStatus?.activity == .active
            || latestState?.climateStatus?.activity == .heating
            || latestState?.climateStatus?.activity == .cooling
            || latestState?.climateStatus?.activity == .ventilating
        if climateActive {
            onRemoteCommand(.stopClimate)
        } else {
            let temp = Float(Preferences.remoteClimateTemperature)
            onRemoteCommand(.startClimate(temperatureCelsius: temp, frontLeftSeat: .off, frontRightSeat: .off, rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .off))
        }
    }

    @objc private func contextFlashLights() {
        guard Preferences.activeBrand == .volvo else { return }
        onRemoteCommand(.flashLights)
    }

    @objc private func contextHonkHorn() {
        guard Preferences.activeBrand == .volvo else { return }
        onRemoteCommand(.honkHorn)
    }

    @objc private func contextHonkAndFlash() {
        guard Preferences.activeBrand == .volvo else { return }
        onRemoteCommand(.honkAndFlash)
    }

    @objc private func contextExportChargingCSV() {
        guard let state = latestState, !state.chargingSessions.isEmpty else { return }
        let headers = "Date,Start Battery %,End Battery %,Battery Added %,kWh Delivered,Peak Power (kW),Duration (min),Estimated Cost,Currency\n"
        let rows = state.chargingSessions.map { s in
            let dateStr = ISO8601DateFormatter().string(from: s.startDate)
            let costStr = s.estimatedCost(tariff: Preferences.electricityPricePerKwh).map { String(format: "%.2f", $0) } ?? ""
            let peakKw = s.peakPowerWatts.map { String(format: "%.1f", Double($0) / 1000.0) } ?? ""
            return "\(dateStr),\(s.startBatteryPercentage),\(s.endBatteryPercentage),\(s.percentageAdded),\(s.kwhDelivered),\(peakKw),\(s.durationMinutes),\(costStr),\(Preferences.currencySymbol)"
        }.joined(separator: "\n")
        let csvData = headers + rows

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

    func updateCars(_ newCars: [CarSummary], activeVin: String?) {
        cars = newCars
        self.activeVin = activeVin
        refreshPopoverIfNeeded()
    }

    func updateRemoteCommandState(_ inProgress: RemoteCommand?) {
        remoteCommandInProgress = inProgress != nil
        refreshPopoverIfNeeded()
    }

    func updateAppVersion(newVersion: String?) {
        updateVersion = newVersion
        refreshPopoverIfNeeded()
    }

    func updateCheckingForUpdates(_ checking: Bool) {
        checkingForUpdates = checking
        refreshPopoverIfNeeded()
    }

    func updateNotificationPermission(_ permission: NotificationPermission) {
        notificationPermission = permission
        refreshPopoverIfNeeded()
    }

    private func showPopover() {
        guard !popover.isShown else { return }
        let view = HisingenContentView(
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
            onRefresh: { [weak self] in self?.onRefresh() },
            onSettings: { [weak self] in self?.toggleSettings() },
            onCheckForUpdates: { [weak self] in self?.onCheckForUpdates() },
            onOpenUpdate: { [weak self] in self?.onOpenUpdate() },
            onRemoteCommand: { [weak self] cmd in self?.onRemoteCommand(cmd) },
            onSelectCar: { [weak self] vin in self?.selectCar(vin) },
            onSettingsChanged: { [weak self] change in self?.onSettingsChanged(change) },
            onSignOut: { [weak self] in self?.onSignOut() },
            settingsMode: settingsMode
        )
        let hosting = NSHostingController(rootView: view)
        popover.contentViewController = hosting
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func selectCar(_ vin: String) {
        guard vin != activeVin else { return }
        onSelectCar?(vin)
    }

    func cycleVehicle(forward: Bool) {
        guard cars.count > 1 else { return }
        let currentIndex = cars.firstIndex { $0.vin == (activeVin ?? cars.first?.vin) } ?? 0
        let nextIndex = forward
            ? (currentIndex + 1) % cars.count
            : (currentIndex - 1 + cars.count) % cars.count
        selectCar(cars[nextIndex].vin)
    }

    func selectVehicleByIndex(_ index: Int) {
        guard index >= 0 && index < cars.count else { return }
        selectCar(cars[index].vin)
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
        let iconName = Format.icon(for: data, includeConnection: Preferences.features.contains(.chargingDetails))
        var icon = NSImage(systemSymbolName: iconName, accessibilityDescription: L10n.text("Hisingen"))
        if Preferences.tintMenuBarIcon, let data {
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
        statusItem.button?.title = title.isEmpty ? "" : " " + title
        statusItem.button?.setAccessibilityLabel(accessibilitySummary(data: data, title: title))
        refreshPopoverIfNeeded()
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

    private func refreshPopoverIfNeeded() {
        guard popover.isShown, let hosting = popover.contentViewController as? NSHostingController<HisingenContentView> else { return }
        let view = HisingenContentView(
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
            onRefresh: { [weak self] in self?.onRefresh() },
            onSettings: { [weak self] in self?.toggleSettings() },
            onCheckForUpdates: { [weak self] in self?.onCheckForUpdates() },
            onOpenUpdate: { [weak self] in self?.onOpenUpdate() },
            onRemoteCommand: { [weak self] cmd in self?.onRemoteCommand(cmd) },
            onSelectCar: { [weak self] vin in self?.selectCar(vin) },
            onSettingsChanged: { [weak self] change in self?.onSettingsChanged(change) },
            onSignOut: { [weak self] in self?.onSignOut() },
            settingsMode: settingsMode
        )
        hosting.rootView = view
    }

    private func barTitle(for data: VehicleState?) -> String {
        Format.barTitle(
            for: data,
            style: Preferences.menuBarStyle,
            unit: Preferences.distanceUnit,
            includeChargingContext: Preferences.features.contains(.chargingDetails)
        )
    }

    private func accessibilitySummary(data: VehicleState?, title: String) -> String {
        guard let data else { return L10n.text("Hisingen, no vehicle data") }
        if data.isStale() {
            return L10n.format("Hisingen, %@, %@, data may be stale", title, data.chargingState.displayName)
        }
        return L10n.format("Hisingen, %@, %@", title, data.chargingState.displayName)
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        settingsMode = false
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}


