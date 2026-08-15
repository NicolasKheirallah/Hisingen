import SwiftUI

enum SettingsChange {
    case credentials
    case features
    case notifications
    case presentation
    case launchAtLogin
    case volvoSignIn(clientID: String, clientSecret: String, vccApiKey: String, nickname: String)
    case switchToBrand(VehicleBrand)
    case closeSettings
}

@MainActor
struct SettingsView: View {
    let notificationPermission: NotificationPermission
    let onSettingsChanged: (SettingsChange) -> Void
    let onSignOut: () -> Void

    @AppStorage("app_theme") private var appTheme: AppTheme = .hisingen
    @State private var menuBarStyle = Preferences.menuBarStyle
    @State private var distanceUnit = Preferences.distanceUnit
    @State private var interfaceLanguage = Preferences.interfaceLanguage
    @State private var tintMenuBarIcon = Preferences.tintMenuBarIcon
    @State private var launchAtLogin = Preferences.launchAtLogin
    @State private var features = Preferences.features
    @State private var notifyChargingStarted = Preferences.notifyChargingStarted
    @State private var notifyChargingComplete = Preferences.notifyChargingComplete
    @State private var notifyChargingProblem = Preferences.notifyChargingProblem
    @State private var notifyLowBattery = Preferences.notifyLowBattery
    @State private var notifySoftwareUpdates = Preferences.notifySoftwareUpdates
    @State private var notifyVehicleWarnings = Preferences.notifyVehicleWarnings
    @State private var lowBatteryThreshold = Preferences.lowBatteryThreshold
    @State private var notifyRainWithWindows = Preferences.notifyRainWithWindowsOpen
    @State private var notifyEveningUnlocked = Preferences.notifyEveningUnlocked
    @State private var privateNotificationDetails = Preferences.privateNotificationDetails
    @State private var electricityPrice = String(format: "%.2f", Preferences.electricityPricePerKwh)
    @State private var currencySymbol = Preferences.currencySymbol
    @State private var storeChargingHistory = Preferences.storeChargingHistory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: HisingenTheme.sectionSpacing) {
                headerBar
                accountCard
                appearanceCard
                displayCard
                featureQuickActions
                vehicleDataCard
                remoteControlsCard
                notificationsCard
                actionsCard
                versionFooter
            }
            .padding(HisingenTheme.sectionSpacing)
        }
        .frame(width: HisingenTheme.popoverWidth)
    }

    private var headerBar: some View {
        HStack {
            Button {
                onSettingsChanged(.closeSettings)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                    Text(L10n.text("Dashboard"))
                }
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Text(L10n.text("Settings"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(HisingenTheme.ink)

            Spacer()

            Button {
                onSettingsChanged(.closeSettings)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.text("Back to Dashboard"))
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }


    private var accountCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "person.crop.circle", title: L10n.text("Account"), color: .accentColor)
                AccountCredentialsForm(style: .compact, onSettingsChanged: onSettingsChanged)
            }
        }
    }


    private var appearanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "paintpalette", title: L10n.text("Appearance"), color: .purple)
                VStack(spacing: 6) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        themeRow(theme)
                    }
                }
            }
        }
    }

    private func themeRow(_ theme: AppTheme) -> some View {
        let isSelected = appTheme == theme
        return Button {
            guard appTheme != theme else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                appTheme = theme
            }
            onSettingsChanged(.presentation)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? HisingenTheme.accent : Color(.tertiaryLabelColor))
                VStack(alignment: .leading, spacing: 1) {
                    Text(theme.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(theme.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(
                isSelected ? HisingenTheme.accent.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.title): \(theme.subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }


    private var displayCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "display", title: L10n.text("General"), color: .blue)

                VStack(spacing: 10) {
                    HStack {
                        Text(L10n.text("Language"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $interfaceLanguage) {
                            ForEach(InterfaceLanguage.allCases, id: \.self) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                        .onChange(of: interfaceLanguage) { _ in
                            Preferences.interfaceLanguage = interfaceLanguage
                            onSettingsChanged(.presentation)
                        }
                    }

                    Divider().opacity(0.4)

                    Toggle(isOn: $storeChargingHistory) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Charging Session History"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Keep up to 20 local per-vehicle charging summaries"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: storeChargingHistory) { _ in
                        Preferences.storeChargingHistory = storeChargingHistory
                        onSettingsChanged(.presentation)
                    }

                    Divider().opacity(0.4)

                    HStack {
                        Text(L10n.text("Menu bar display"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $menuBarStyle) {
                            ForEach(MenuBarStyle.allCases, id: \.self) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                        .onChange(of: menuBarStyle) { _ in
                            Preferences.menuBarStyle = menuBarStyle
                            onSettingsChanged(.presentation)
                        }
                    }


                    let previewSample = VehicleState(
                        batteryPercentage: 82, rangeKm: 348, chargingState: .charging,
                        estimatedChargingTimeToFullMinutes: 102, chargeTargetPercentage: 90,
                        chargingPowerWatts: 7200, chargingCurrentAmps: 16, chargingVoltageVolts: 230,
                        chargingType: .ac, chargerConnection: .connected, availability: .available,
                        modelName: "Polestar 2", modelYear: "2024", registrationNo: nil, vin: "YSMTEST",
                        ownerFirstName: nil, odometerKm: 12500, daysToService: nil, distanceToServiceKm: nil,
                        serviceWarning: false, fluidWarnings: [], imageData: nil, fetchedAt: Date(),
                        vehicleReportedAt: Date(), dataWarnings: []
                    )
                    let previewText = Format.barTitle(for: previewSample, style: menuBarStyle, unit: distanceUnit)
                    let previewIcon = Format.icon(for: previewSample)
                    HStack(spacing: 6) {
                        Text(L10n.text("Preview:"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: previewIcon)
                                .font(.system(size: 10))
                                .foregroundStyle(tintMenuBarIcon ? Color.green : Color.primary)
                            Text(previewText)
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        Spacer()
                    }
                    .padding(.vertical, 2)

                    Divider().opacity(0.4)

                    Toggle(isOn: $tintMenuBarIcon) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Dynamic status bar tinting"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Color icon green while charging and orange below 20%"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: tintMenuBarIcon) { _ in
                        Preferences.tintMenuBarIcon = tintMenuBarIcon
                        onSettingsChanged(.presentation)
                    }

                    Divider().opacity(0.4)

                    HStack {
                        Text(L10n.text("Distance unit"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $distanceUnit) {
                            ForEach(DistanceUnit.allCases, id: \.self) { unit in
                                Text(unit.title).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                        .onChange(of: distanceUnit) { _ in
                            Preferences.distanceUnit = distanceUnit
                            onSettingsChanged(.presentation)
                        }
                    }

                    Divider().opacity(0.4)

                    Toggle(isOn: $launchAtLogin) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Launch at login"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Automatically start Hisingen on macOS startup"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: launchAtLogin) { _ in
                        Preferences.launchAtLogin = launchAtLogin
                        onSettingsChanged(.launchAtLogin)
                    }

                    Divider().opacity(0.4)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("Electricity Rate"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("For charge cost estimates"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            TextField("2.00", text: $electricityPrice)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 55)
                                .multilineTextAlignment(.trailing)
                                .controlSize(.small)
                                .onChange(of: electricityPrice) { newValue in
                                    if let price = Double(newValue.replacingOccurrences(of: ",", with: ".")), price > 0 {
                                        Preferences.electricityPricePerKwh = price
                                    }
                                }
                            TextField("kr", text: $currencySymbol)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 45)
                                .controlSize(.small)
                                .onChange(of: currencySymbol) { newValue in
                                    Preferences.currencySymbol = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            Text("/kWh")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }


    private var featureQuickActions: some View {
        HStack(spacing: 8) {
            Button {
                let recommended = FeatureSelection.default
                features = recommended
                Preferences.features = recommended
                onSettingsChanged(.features)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text(L10n.text("Recommended"))
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.borderedProminent)
            .tint(HisingenTheme.accent)
            .controlSize(.small)

            Button {
                let all = FeatureSelection(enabled: Set(AppFeature.userSelectableCases))
                features = all
                Preferences.features = all
                onSettingsChanged(.features)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                    Text(L10n.text("Enable All Features"))
                }
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }


    private var remoteControlsCard: some View {
        let isVolvo = Preferences.activeBrand == .volvo
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "slider.horizontal.3", title: L10n.text("Remote Controls"), color: .secondary)

                Text(isVolvo
                     ? L10n.text("Volvo Connected Vehicle telemetry is active. Write commands depend on your vehicle connected package and developer account tier.")
                     : L10n.text("Remote vehicle commands are unavailable because Polestar restricts them to paired mobile devices."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    featureToggleRow(.remoteClimate, symbol: "fan.fill", title: "Remote Climate", detail: "Start & stop cabin preconditioning")
                    featureToggleRow(.remoteLocks, symbol: "lock.fill", title: "Remote Locks", detail: "Central lock, unlock, and trunk release")
                    featureToggleRow(.remoteCharging, symbol: "bolt.fill", title: "Remote Charging", detail: "Set target SoC, current limit & charge now")
                    featureToggleRow(.remoteWindows, symbol: "rectangle.arrowtriangle.2.outward", title: "Window Controls", detail: "Vent or close vehicle windows")
                    featureToggleRow(.remoteHonkFlash, symbol: "flashlight.on.fill", title: "Locate Vehicle", detail: "Flash headlights and honk horn")
                    featureToggleRow(.remotePreCleaning, symbol: "sparkles", title: "Cabin Air Cleaning", detail: "PM2.5 pre-cleaning filtration")
                }
                .disabled(true)
                .opacity(0.5)
            }
        }
    }


    private var vehicleDataCard: some View {
        let brandName = Preferences.activeBrand.displayName
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "list.bullet.rectangle", title: L10n.text("Vehicle Data"), color: .green)

                subsectionHeader("Vehicle & Identity")
                VStack(spacing: 4) {
                    featureToggleRow(.vehicleIdentity, symbol: "car.side", title: "Vehicle Identity", detail: "Model, year, license plate & VIN")
                    featureToggleRow(.ownerGreeting, symbol: "person.text.rectangle", title: "Owner Greeting", detail: L10n.format("Show the %@ ID first name", brandName))
                    featureToggleRow(.vehicleImage, symbol: "photo.artframe", title: "Studio Vehicle Image", detail: L10n.format("Render high-resolution %@ visual", brandName))
                    featureToggleRow(.vehicleAvailability, symbol: "antenna.radiowaves.left.and.right", title: "Vehicle Availability", detail: "Show online state and unavailable reason")
                }

                subsectionHeader("Charging & Energy")
                VStack(spacing: 4) {
                    featureToggleRow(.chargingDetails, symbol: "powerplug.fill", title: "Charging Telemetry", detail: "Power, voltage, current & completion time")
                    featureToggleRow(.chargingSchedule, symbol: "calendar.badge.clock", title: "Charging Schedules", detail: "Show charging windows and departure times")
                    featureToggleRow(.batteryDiagnostics, symbol: "batteryblock", title: "Battery Diagnostics", detail: "Battery state, module health & energy usage")
                }

                subsectionHeader("Status & Security")
                VStack(spacing: 4) {
                    featureToggleRow(.exteriorStatus, symbol: "door.left.hand.open", title: "Exterior Doors & Windows", detail: "Open doors, windows, trunk & lock alerts")
                    featureToggleRow(.tyreAndWarnings, symbol: "circle.grid.2x2", title: "Tyre Pressures & Warnings", detail: "Pressure monitoring and system alerts")
                    featureToggleRow(.vehicleHealth, symbol: "speedometer", title: "Odometer & Service", detail: "Mileage, service intervals & fluid levels")
                }

                subsectionHeader("Climate & Air")
                VStack(spacing: 4) {
                    featureToggleRow(.climateStatus, symbol: "thermometer.medium", title: "Climate Status & Timers", detail: "Live interior status and scheduled timers")
                    featureToggleRow(.airQuality, symbol: "wind", title: "Cabin Air Quality", detail: "AQI & particulate matter sensors")
                }

                subsectionHeader("Location & Weather")
                VStack(spacing: 4) {
                    featureToggleRow(.vehicleLocation, symbol: "location.fill", title: "Vehicle Location & Maps", detail: "Parking GPS coordinates and Apple Maps")
                    featureToggleRow(.vehicleWeather, symbol: "cloud.sun.fill", title: "Vehicle Weather", detail: "Ambient weather at vehicle GPS location — sends vehicle coordinates to Open-Meteo")
                }

                subsectionHeader("Advanced Diagnostics")
                VStack(spacing: 4) {
                    featureToggleRow(.tripMeters, symbol: "chart.xyaxis.line", title: "Trip Meters", detail: "Manual and automatic trip computers")
                    featureToggleRow(.connectivityDiagnostics, symbol: "antenna.radiowaves.left.and.right", title: "Connectivity", detail: "Vehicle network & signal diagnostics")
                    featureToggleRow(.softwareUpdates, symbol: "arrow.triangle.2.circlepath", title: "Vehicle Software & OTA", detail: L10n.format("%@ software version and update status", brandName))
                }
            }
        }
    }

    private func subsectionHeader(_ title: String) -> some View {
        Text(L10n.text(title))
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.3)
            .padding(.top, 6)
    }

    private func featureToggleRow(_ feature: AppFeature, symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text(title))
                    .font(.system(size: 11, weight: .medium))
                Text(L10n.text(detail))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { features.contains(feature) },
                set: { enabled in
                    features.set(feature, enabled: enabled)
                    Preferences.features = features
                    onSettingsChanged(.features)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.vertical, 3)
    }


    private var notificationsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "bell.badge", title: L10n.text("Notifications"), color: .orange)

                if notificationPermission == .denied {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(HisingenTheme.semanticWarning)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Notifications Blocked in System Settings"))
                                .font(.system(size: 11, weight: .semibold))
                            Text(L10n.text("These toggles won't alert you until notifications are allowed for Hisingen."))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text(L10n.text("Open Settings"))
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(8)
                    .background(HisingenTheme.semanticWarning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                }

                VStack(spacing: 4) {
                    notificationRow(
                        symbol: "bolt.badge.clock.fill",
                        title: "Charging Started",
                        detail: "Alert when vehicle starts charging",
                        isOn: $notifyChargingStarted,
                        persist: { Preferences.notifyChargingStarted = $0 }
                    )
                    notificationRow(
                        symbol: "battery.100.bolt",
                        title: "Charging Complete",
                        detail: "Alert when target state of charge is reached",
                        isOn: $notifyChargingComplete,
                        persist: { Preferences.notifyChargingComplete = $0 }
                    )
                    notificationRow(
                        symbol: "exclamationmark.triangle.fill",
                        title: "Charging Interrupted",
                        detail: "Alert if charging stops unexpectedly",
                        isOn: $notifyChargingProblem,
                        persist: { Preferences.notifyChargingProblem = $0 }
                    )
                    notificationRow(
                        symbol: "battery.25",
                        title: "Low Battery Warning",
                        detail: "Alert when battery falls below threshold",
                        isOn: $notifyLowBattery,
                        persist: { Preferences.notifyLowBattery = $0 }
                    )

                    notificationRow(
                        symbol: "arrow.triangle.2.circlepath",
                        title: "Software Updates",
                        detail: "Alert when vehicle software becomes available or finishes installing",
                        isOn: $notifySoftwareUpdates,
                        persist: { Preferences.notifySoftwareUpdates = $0 }
                    )

                    notificationRow(
                        symbol: "exclamationmark.triangle.fill",
                        title: "Vehicle Warnings & Alarm",
                        detail: "Alert for new service, tyre, light, 12 V, fluid, or alarm warnings",
                        isOn: $notifyVehicleWarnings,
                        persist: { Preferences.notifyVehicleWarnings = $0 }
                    )

                    if notifyLowBattery {
                        HStack(spacing: 8) {
                            Image(systemName: "slider.horizontal.below.rectangle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(L10n.text("Alert Threshold"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $lowBatteryThreshold) {
                                ForEach(stride(from: 5, through: 50, by: 5).map { $0 }, id: \.self) { v in
                                    Text("\(v)%").tag(v)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: 80)
                            .onChange(of: lowBatteryThreshold) { _ in
                                Preferences.lowBatteryThreshold = lowBatteryThreshold
                                onSettingsChanged(.notifications)
                            }
                        }
                        .padding(.leading, 12)
                        .padding(.vertical, 2)
                    }

                    Divider().opacity(0.4)
                        .padding(.vertical, 2)

                    notificationRow(
                        symbol: "cloud.rain.fill",
                        title: "Rain Alert (Windows Open)",
                        detail: "Alert if rain starts while windows or sunroof are open",
                        isOn: $notifyRainWithWindows,
                        persist: { Preferences.notifyRainWithWindowsOpen = $0 }
                    )

                    notificationRow(
                        symbol: "lock.shield.fill",
                        title: "Evening Unlocked Reminder",
                        detail: "Alert if parked and unlocked after 21:00",
                        isOn: $notifyEveningUnlocked,
                        persist: { Preferences.notifyEveningUnlocked = $0 }
                    )

                    Divider().opacity(0.4)
                        .padding(.vertical, 2)

                    notificationRow(
                        symbol: "eye.slash.fill",
                        title: "Private Notification Banners",
                        detail: "Hide license plate and battery % from lock screen",
                        isOn: $privateNotificationDetails,
                        persist: { Preferences.privateNotificationDetails = $0 }
                    )
                }
            }
        }
    }

    private func notificationRow(
        symbol: String,
        title: String,
        detail: String,
        isOn: Binding<Bool>,
        persist: @escaping @MainActor (Bool) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text(title))
                    .font(.system(size: 11, weight: .medium))
                Text(L10n.text(detail))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .onChange(of: isOn.wrappedValue) { value in
                    persist(value)
                    onSettingsChanged(.notifications)
                }
        }
        .padding(.vertical, 3)
    }


    private var actionsCard: some View {
        Card {
            VStack(spacing: 8) {
                Button(role: .destructive) {
                    onSignOut()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text(L10n.format("Sign Out of %@ Account", Preferences.activeBrand.displayName))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.red)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    HStack {
                        Image(systemName: "power")
                        Text(L10n.text("Quit Hisingen"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
    }

    private var versionFooter: some View {
        VStack(spacing: 4) {
            Text("Hisingen v2.5.0")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(L10n.text("Created by"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Button("Nicolas Kheirallah") {
                    if let url = URL(string: "https://github.com/NicolasKheirallah") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 10, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

}


