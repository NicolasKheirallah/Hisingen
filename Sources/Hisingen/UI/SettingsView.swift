import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsChange {
    case credentials
    case features
    case notifications
    case presentation
    case launchAtLogin
    case volvoSignIn(clientID: String, clientSecret: String, vccApiKey: String, nickname: String)
    case polestarCommandAuthorization
    case switchToBrand(VehicleBrand)
    case closeSettings
}

private struct DatabaseStats: Sendable {
    let counts: (snapshots: Int, chargingSessions: Int, chargingSamples: Int, batteryHealth: Int, telemetry: Int, commands: Int)
    let sizeBytes: Int64
}

@MainActor
struct SettingsView: View {
    let notificationPermission: NotificationPermission
    var state: VehicleState? = nil
    var database: VehicleDatabase = VehicleDatabase()
    var imageCache: CarImageCache = CarImageCache()
    let onSettingsChanged: (SettingsChange) -> Void
    let onSignOut: () -> Void
    var onTestConnection: (VehicleBrand) async -> (success: Bool, message: String) = { _ in
        (false, L10n.text("Connection testing is not available."))
    }

    @State private var appTheme: AppTheme = .hisingen
    @State private var appearanceMode: AppearanceMode = .system
    @State private var carRenderAngle: CarRenderAngle = .frontThreeQuarter
    @State private var vehicleModelBadgePosition: VehicleModelBadgePosition = .inlineHeader
    @State private var registrationBadgePosition: RegistrationNumberBadgePosition = .belowGreeting
    @State private var vehicleLabelFormat: VehicleLabelFormat = .modelAndYear
    @State private var menuBarStyle = MenuBarStyle.battery
    @State private var distanceUnit = DistanceUnit.kilometers
    @State private var temperatureUnit = TemperatureUnit.celsius
    @State private var pressureUnit = PressureUnit.kilopascals
    @State private var fuelVolumeUnit = FuelVolumeUnit.liters
    @State private var fuelEconomyUnit = FuelEconomyUnit.litersPer100Km
    @State private var energyConsumptionUnit = EnergyConsumptionUnit.kwhPer100Km
    @State private var selectedThemeCategory: ThemeCategory = .all
    @State private var interfaceLanguage = InterfaceLanguage.system
    @State private var tintMenuBarIcon = true
    @State private var launchAtLogin = false
    @State private var features = FeatureSelection.default
    @State private var notifyChargingStarted = true
    @State private var notifyChargingComplete = true
    @State private var notifyChargingProblem = true
    @State private var notifyLowBattery = true
    @State private var notifySoftwareUpdates = true
    @State private var notifyVehicleWarnings = true
    @State private var notifyOpeningsLeftOpen = true
    @State private var notifyServiceDue = true
    @State private var notifyStaleTelemetry = true
    @State private var notifySlowCharging = true
    @State private var notifyPlugInReminder = true
    @State private var lowBatteryThreshold = 20
    @State private var notifyRainWithWindows = true
    @State private var notifyEveningUnlocked = true
    @State private var privateNotificationDetails = true
    @State private var electricityPrice = "2.00"
    @State private var currencySymbol = "kr"
    @State private var storeChargingHistory = false
    @State private var nightTariffEnabled = false
    @State private var nightElectricityPrice = "2.00"
    @State private var nightTariffStartHour = 22
    @State private var nightTariffEndHour = 6
    @State private var requireBiometrics = false
    @State private var persistLocationHistory = false
    @State private var hasWarrantyInServiceDate = false
    @State private var warrantyInServiceDate = Date()
    @State private var usableBatteryCapacityOverride = ""
    @State private var wltpRangeOverride = ""
    @Environment(\.preferencesStore) private var preferences
    @State private var databaseVacuumed = false
    @State private var databasePruned = false
    @State private var databaseStats = DatabaseStats(
        counts: (0, 0, 0, 0, 0, 0), sizeBytes: 0
    )
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settingsVehicleVIN: String { state?.vin ?? preferences.vin }

    private var availableRenderAngles: [CarRenderAngle] {
        CarRenderAngle.allCases.filter {
            imageCache.image(for: settingsVehicleVIN, angle: $0.rawValue) != nil
        }
    }

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
                capabilitiesCard
                notificationsCard
                databaseStorageCard
                actionsCard
                versionFooter
            }
            .padding(HisingenTheme.sectionSpacing)
        }
        .frame(width: HisingenTheme.popoverWidth)
        .onAppear {
            appTheme = preferences.appTheme
            appearanceMode = preferences.appearanceMode
            carRenderAngle = preferences.carRenderAngle
            if let firstAvailable = availableRenderAngles.first,
               !availableRenderAngles.contains(preferences.carRenderAngle) {
                carRenderAngle = firstAvailable
                preferences.carRenderAngle = firstAvailable
            }
            vehicleModelBadgePosition = preferences.vehicleModelBadgePosition
            registrationBadgePosition = preferences.registrationBadgePosition
            vehicleLabelFormat = preferences.vehicleLabelFormat
            menuBarStyle = preferences.menuBarStyle
            distanceUnit = preferences.distanceUnit
            temperatureUnit = preferences.temperatureUnit
            pressureUnit = preferences.pressureUnit
            fuelVolumeUnit = preferences.fuelVolumeUnit
            fuelEconomyUnit = preferences.fuelEconomyUnit
            energyConsumptionUnit = preferences.energyConsumptionUnit
            interfaceLanguage = preferences.interfaceLanguage
            tintMenuBarIcon = preferences.tintMenuBarIcon
            launchAtLogin = preferences.launchAtLogin
            features = preferences.features
            notifyChargingStarted = preferences.notifyChargingStarted
            notifyChargingComplete = preferences.notifyChargingComplete
            notifyChargingProblem = preferences.notifyChargingProblem
            notifyLowBattery = preferences.notifyLowBattery
            notifySoftwareUpdates = preferences.notifySoftwareUpdates
            notifyVehicleWarnings = preferences.notifyVehicleWarnings
            notifyOpeningsLeftOpen = preferences.notifyOpeningsLeftOpen
            notifyServiceDue = preferences.notifyServiceDue
            notifyStaleTelemetry = preferences.notifyStaleTelemetry
            notifySlowCharging = preferences.notifySlowCharging
            notifyPlugInReminder = preferences.notifyPlugInReminder
            lowBatteryThreshold = preferences.lowBatteryThreshold
            notifyRainWithWindows = preferences.notifyRainWithWindowsOpen
            notifyEveningUnlocked = preferences.notifyEveningUnlocked
            privateNotificationDetails = preferences.privateNotificationDetails
            electricityPrice = String(format: "%.2f", preferences.electricityPricePerKwh)
            currencySymbol = preferences.currencySymbol
            storeChargingHistory = preferences.storeChargingHistory
            nightTariffEnabled = preferences.nightTariffEnabled
            nightElectricityPrice = String(format: "%.2f", preferences.nightElectricityPricePerKwh)
            nightTariffStartHour = preferences.nightTariffStartHour
            nightTariffEndHour = preferences.nightTariffEndHour
            requireBiometrics = preferences.requireBiometricsForRemoteControls
            persistLocationHistory = preferences.persistLocationHistory
            let warrantyVIN = state?.vin ?? preferences.vin
            if let savedDate = preferences.warrantyInServiceDate(for: warrantyVIN) {
                hasWarrantyInServiceDate = true
                warrantyInServiceDate = savedDate
            }
            if let specification = preferences.vehicleSpecificationOverride(for: warrantyVIN) {
                usableBatteryCapacityOverride = specification.usableBatteryCapacityKwh
                    .map { String(format: "%.1f", $0) } ?? ""
                wltpRangeOverride = specification.wltpRangeKm
                    .map { String(format: "%.0f", $0) } ?? ""
            }
        }
        .task {
            await loadDatabaseStats()
        }
    }

    private func loadDatabaseStats() async {
        let database = database
        let stats = await Task.detached(priority: .utility) {
            DatabaseStats(counts: database.recordCounts(), sizeBytes: database.databaseSizeBytes)
        }.value
        guard !Task.isCancelled else { return }
        databaseStats = stats
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
                AccountCredentialsForm(style: .compact, onSettingsChanged: onSettingsChanged,
                                        onTestConnection: onTestConnection)
            }
        }
    }


    private var filteredThemes: [AppTheme] {
        if selectedThemeCategory == .all {
            return AppTheme.allCases
        }
        return AppTheme.allCases.filter { $0.category == selectedThemeCategory }
    }

    private func themeCategoryCount(_ cat: ThemeCategory) -> Int {
        if cat == .all { return AppTheme.allCases.count }
        return AppTheme.allCases.filter { $0.category == cat }.count
    }

    private var appearanceCard: some View {
        let vehicleLabel = preferences.lastVehicleLabel(for: preferences.activeBrand)
        let availableAngles = availableRenderAngles
        let supportsMultipleAngles = availableAngles.count > 1
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardHeader(symbol: "paintpalette.fill", title: L10n.text("Appearance & Themes"), color: HisingenTheme.accent)
                    Spacer()
                    Text(L10n.format("%d Themes", AppTheme.allCases.count))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(HisingenTheme.accent.opacity(0.12), in: Capsule())
                        .foregroundStyle(HisingenTheme.accent)
                }

                // Appearance Mode Selector (System / Light / Dark)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Mode"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HisingenTheme.ink)

                    HStack(spacing: 8) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            let isModeSelected = appearanceMode == mode
                            Button {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                    appearanceMode = mode
                                    preferences.appearanceMode = mode
                                }
                                onSettingsChanged(.presentation)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: mode.symbol)
                                        .font(.system(size: 11, weight: isModeSelected ? .semibold : .regular))
                                    Text(mode.title)
                                        .font(.system(size: 11, weight: isModeSelected ? .semibold : .regular))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    isModeSelected ? HisingenTheme.accent.opacity(0.16) : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(isModeSelected ? HisingenTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                                )
                                .foregroundStyle(isModeSelected ? HisingenTheme.accent : HisingenTheme.ink)
                            }
                            .buttonStyle(.plain)
                            .withoutFocusRing()
                        }
                    }
                }

                // Vehicle Image Perspective & Studio Render Preview
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.text(supportsMultipleAngles ? "Vehicle Perspective" : "Vehicle Image"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(HisingenTheme.ink)
                        Spacer()
                        if supportsMultipleAngles {
                            Text(carRenderAngle.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Live Studio Render Preview
                    let previewData = supportsMultipleAngles
                        ? imageCache.image(for: settingsVehicleVIN, angle: carRenderAngle.rawValue)
                        : (availableAngles.first.flatMap { imageCache.image(for: settingsVehicleVIN, angle: $0.rawValue) }
                            ?? imageCache.image(for: settingsVehicleVIN))
                    if let previewData, let nsImg = NSImage(data: previewData) {
                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 110)
                            .padding(6)
                            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .transition(.opacity)
                    }

                    if supportsMultipleAngles {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(availableAngles, id: \.self) { angle in
                                let isAngleSelected = carRenderAngle == angle
                                Button {
                                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                        carRenderAngle = angle
                                        preferences.carRenderAngle = angle
                                    }
                                    onSettingsChanged(.presentation)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: angle.symbol)
                                            .font(.system(size: 11, weight: isAngleSelected ? .semibold : .regular))
                                        Text(angle.title)
                                            .font(.system(size: 11, weight: isAngleSelected ? .semibold : .regular))
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 4)
                                    .background(
                                        isAngleSelected ? HisingenTheme.accent.opacity(0.16) : Color.primary.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(isAngleSelected ? HisingenTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                                    )
                                    .foregroundStyle(isAngleSelected ? HisingenTheme.accent : HisingenTheme.ink)
                                }
                                .buttonStyle(.plain)
                                .withoutFocusRing()
                            }
                        }
                    }
                }

                Divider().opacity(0.4)

                Text(L10n.format("Active for %@ — each vehicle saves its own theme preference.", vehicleLabel))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                // Category Filter Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ThemeCategory.allCases, id: \.self) { cat in
                            categoryFilterButton(cat)
                        }
                    }
                    .padding(.vertical, 2)
                }

                // 2-Column Responsive Grid of Themes
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(filteredThemes, id: \.self) { theme in
                        themeTile(theme)
                    }
                }
            }
        }
    }

    private func categoryFilterButton(_ cat: ThemeCategory) -> some View {
        let isSelected = selectedThemeCategory == cat
        let count = themeCategoryCount(cat)
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                selectedThemeCategory = cat
            }
        } label: {
            HStack(spacing: 4) {
                Text(cat.title)
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.85)
            }
            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                isSelected ? HisingenTheme.accent.opacity(0.18) : Color.primary.opacity(0.05),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(isSelected ? HisingenTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? HisingenTheme.accent : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func themeTile(_ theme: AppTheme) -> some View {
        let isSelected = appTheme == theme
        let accentColor = Color(hex: theme.accentColorHex) ?? HisingenTheme.accent
        return Button {
            guard appTheme != theme else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                appTheme = theme
                preferences.appTheme = theme
            }
            onSettingsChanged(.presentation)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    HStack(spacing: 3) {
                        ForEach(theme.previewHexColors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? Color.gray)
                                .frame(width: 8, height: 8)
                        }
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accentColor)
                    } else {
                        Circle()
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            .frame(width: 12, height: 12)
                    }
                }

                Text(theme.title)
                    .font(.system(size: 11.5, weight: isSelected ? .bold : .semibold))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)

                Text(theme.subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected ? accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
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
                        .onChange(of: interfaceLanguage) { _, _ in
                            preferences.interfaceLanguage = interfaceLanguage
                            onSettingsChanged(.presentation)
                        }
                    }

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Model badge position"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Placement of model & year label"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $vehicleModelBadgePosition) {
                            ForEach(VehicleModelBadgePosition.allCases, id: \.self) { pos in
                                Text(pos.title).tag(pos)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                        .onChange(of: vehicleModelBadgePosition) { _, _ in
                            preferences.vehicleModelBadgePosition = vehicleModelBadgePosition
                            onSettingsChanged(.presentation)
                        }
                    }

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("License plate position"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Placement of registration plate"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $registrationBadgePosition) {
                            ForEach(RegistrationNumberBadgePosition.allCases, id: \.self) { pos in
                                Text(pos.title).tag(pos)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                        .onChange(of: registrationBadgePosition) { _, _ in
                            preferences.registrationBadgePosition = registrationBadgePosition
                            onSettingsChanged(.presentation)
                        }
                    }

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Vehicle display name"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Shown in footer switcher, menus, and vehicle headers"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $vehicleLabelFormat) {
                            ForEach(VehicleLabelFormat.allCases, id: \.self) { format in
                                Text(format.title).tag(format)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                        .onChange(of: vehicleLabelFormat) { _, _ in
                            preferences.vehicleLabelFormat = vehicleLabelFormat
                            onSettingsChanged(.presentation)
                        }
                    }

                    let previewTitle = preferences.formattedVehicleTitle(
                        vin: preferences.vin.isEmpty ? "YS2TESTVIN123456" : preferences.vin,
                        modelName: state?.modelName ?? (preferences.activeBrand == .polestar ? "Polestar 2" : "Volvo EX40"),
                        modelYear: state?.modelYear ?? "2024",
                        registrationNo: state?.registrationNo ?? "ZCJ 06G",
                        format: vehicleLabelFormat
                    )
                    HStack(spacing: 6) {
                        Text(L10n.text("Preview:"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: preferences.activeBrand == .polestar ? "bolt.car.fill" : "car.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(HisingenTheme.accent)
                            Text(previewTitle)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        Spacer()
                    }
                    .padding(.vertical, 2)

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Charging Session History"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Keep up to 20 local per-vehicle charging summaries"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $storeChargingHistory)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: storeChargingHistory) { _, _ in
                                preferences.storeChargingHistory = storeChargingHistory
                                onSettingsChanged(.presentation)
                            }
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
                        .onChange(of: menuBarStyle) { _, _ in
                            preferences.menuBarStyle = menuBarStyle
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
                        serviceWarning: false, fluidWarnings: [],
                        exteriorStatus: ExteriorSnapshot(openings: [], isLocked: false, alarmTriggered: false),
                        imageData: nil, fetchedAt: Date(), vehicleReportedAt: Date(), dataWarnings: []
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
                            if menuBarStyle == .lockAndBattery,
                               let lockSymbol = Format.lockStatusSymbol(for: previewSample) {
                                Image(systemName: lockSymbol)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(HisingenTheme.semanticWarning)
                            }
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

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Dynamic status bar tinting"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Color icon green while charging and orange below 20%"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $tintMenuBarIcon)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        .onChange(of: tintMenuBarIcon) { _, _ in
                                preferences.tintMenuBarIcon = tintMenuBarIcon
                                onSettingsChanged(.presentation)
                            }
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
                        .onChange(of: distanceUnit) { _, _ in
                            preferences.distanceUnit = distanceUnit
                            if !preferences.hasExplicitTemperatureUnit {
                                temperatureUnit = distanceUnit == .miles ? .fahrenheit : .celsius
                            }
                            if !preferences.hasExplicitPressureUnit {
                                pressureUnit = distanceUnit == .miles ? .psi : .kilopascals
                            }
                            if !preferences.hasExplicitEnergyConsumptionUnit {
                                energyConsumptionUnit = distanceUnit == .miles ? .milesPerKwh : .kwhPer100Km
                            }
                            onSettingsChanged(.presentation)
                        }
                    }

                    Divider().opacity(0.4)

                    HStack {
                        Text(L10n.text("Temperature unit"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $temperatureUnit) {
                            ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                                Text(unit.title).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                        .onChange(of: temperatureUnit) { _, _ in
                            preferences.temperatureUnit = temperatureUnit
                            onSettingsChanged(.presentation)
                        }
                    }

                    Divider().opacity(0.4)

                    HStack {
                        Text(L10n.text("Tyre pressure unit"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $pressureUnit) {
                            ForEach(PressureUnit.allCases, id: \.self) { unit in
                                Text(unit.title).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                        .onChange(of: pressureUnit) { _, _ in
                            preferences.pressureUnit = pressureUnit
                            onSettingsChanged(.presentation)
                        }
                    }

                    Divider().opacity(0.4)

                    HStack {
                        Text(L10n.text("Fuel volume unit"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $fuelVolumeUnit) {
                            ForEach(FuelVolumeUnit.allCases, id: \.self) { unit in
                                Text(unit.title).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                        .onChange(of: fuelVolumeUnit) { _, _ in
                            preferences.fuelVolumeUnit = fuelVolumeUnit
                            onSettingsChanged(.presentation)
                        }
                    }

                    Divider().opacity(0.4)

                    HStack {
                        Text(L10n.text("Fuel economy unit"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $fuelEconomyUnit) {
                            ForEach(FuelEconomyUnit.allCases, id: \.self) { unit in
                                Text(unit.title).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                        .onChange(of: fuelEconomyUnit) { _, _ in
                            preferences.fuelEconomyUnit = fuelEconomyUnit
                            onSettingsChanged(.presentation)
                        }
                    }

                    Divider().opacity(0.4)

                    HStack {
                        Text(L10n.text("Electric consumption unit"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $energyConsumptionUnit) {
                            ForEach(EnergyConsumptionUnit.allCases, id: \.self) { unit in
                                Text(unit.title).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                        .onChange(of: energyConsumptionUnit) { _, value in
                            preferences.energyConsumptionUnit = value
                            onSettingsChanged(.presentation)
                        }
                    }

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Launch at login"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Automatically start Hisingen on macOS startup"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: launchAtLogin) { _, _ in
                                preferences.launchAtLogin = launchAtLogin
                                onSettingsChanged(.launchAtLogin)
                            }
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
                                .onChange(of: electricityPrice) { _, _ in
                                    if let price = Double(electricityPrice.replacingOccurrences(of: ",", with: ".")), price > 0 {
                                        preferences.electricityPricePerKwh = price
                                    }
                                }
                            TextField("kr", text: $currencySymbol)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 45)
                                .controlSize(.small)
                                .onChange(of: currencySymbol) { _, _ in
                                    preferences.currencySymbol = currencySymbol.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            Text("/kWh")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("Night Tariff"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Splits session cost by when energy actually flowed"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $nightTariffEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: nightTariffEnabled) { _, _ in
                                preferences.nightTariffEnabled = nightTariffEnabled
                            }
                    }
                    if nightTariffEnabled {
                        HStack(spacing: 4) {
                            TextField("2.00", text: $nightElectricityPrice)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 55)
                                .multilineTextAlignment(.trailing)
                                .controlSize(.small)
                                .onChange(of: nightElectricityPrice) { _, _ in
                                    if let price = Double(nightElectricityPrice.replacingOccurrences(of: ",", with: ".")), price > 0 {
                                        preferences.nightElectricityPricePerKwh = price
                                    }
                                }
                            Text(L10n.text("/kWh from"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Stepper(value: $nightTariffStartHour, in: 0...23) {
                                Text(String(format: "%02d:00", nightTariffStartHour))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .controlSize(.small)
                            .onChange(of: nightTariffStartHour) { _, _ in
                                preferences.nightTariffStartHour = nightTariffStartHour
                            }
                            Text(L10n.text("to"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Stepper(value: $nightTariffEndHour, in: 0...23) {
                                Text(String(format: "%02d:00", nightTariffEndHour))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .controlSize(.small)
                            .onChange(of: nightTariffEndHour) { _, _ in
                                preferences.nightTariffEndHour = nightTariffEndHour
                            }
                        }
                    }

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Require Touch ID"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Authenticate before running remote commands"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $requireBiometrics)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: requireBiometrics) { _, _ in
                                preferences.requireBiometricsForRemoteControls = requireBiometrics
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
                preferences.features = recommended
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
                preferences.features = all
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
        let isVolvo = preferences.activeBrand == .volvo
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "slider.horizontal.3", title: L10n.text("Remote Controls"), color: .blue)

                Text(isVolvo
                     ? L10n.text("Climate is available with the standard API subscription. Lock, locate, engine-start, and location permissions require approval for your Volvo developer application and a new sign-in.")
                     : L10n.text("Climate, locks, windows, cabin cleaning, charging and timers are dispatched through Polestar's command service, and software installation through its OTA scheduler."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    if isVolvo {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.text("Approved Volvo permissions"))
                                    .font(.system(size: 11, weight: .semibold))
                                Text(L10n.text("Request restricted lock, unlock, engine, locate, and location scopes on the next sign-in."))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { preferences.volvoRestrictedScopesEnabled },
                                set: { enabled in
                                    preferences.volvoRestrictedScopesEnabled = enabled
                                    onSettingsChanged(.features)
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.text("Authorize Remote Commands"))
                                    .font(.system(size: 11, weight: .semibold))
                                Text(L10n.text("Opens your browser to sign in for remote commands. Hisingen never sees your Polestar password for this step, and this is separate from the account sign-in above."))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                onSettingsChanged(.polestarCommandAuthorization)
                            } label: {
                                Text(L10n.text("Authorize…"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    featureToggleRow(.remoteClimate, symbol: "fan.fill", title: "Remote Climate", detail: "Start & stop cabin preconditioning")
                    featureToggleRow(.remoteLocks, symbol: "lock.fill", title: "Remote Locks", detail: "Central lock and unlock", isSupported: !isVolvo || preferences.volvoRestrictedScopesEnabled, badgeText: isVolvo ? "Requires Approval" : nil)
                    featureToggleRow(.remoteCharging, symbol: "bolt.fill", title: "Remote Charging", detail: "Set target SoC, current limit & charge now", isSupported: !isVolvo, badgeText: isVolvo ? "Read-Only in API" : nil)
                    featureToggleRow(.remoteSchedules, symbol: "calendar.badge.clock", title: "Charging & Climate Timers", detail: "Create and edit charge windows and departure timers", isSupported: !isVolvo, badgeText: isVolvo ? "Not in API" : nil)
                    featureToggleRow(.remoteWindows, symbol: "rectangle.arrowtriangle.2.outward", title: "Window Controls", detail: "Vent or close vehicle windows", isSupported: !isVolvo, badgeText: isVolvo ? "Not in API" : nil)
                    featureToggleRow(.remoteHonkFlash, symbol: "flashlight.on.fill", title: "Locate Vehicle", detail: "Flash headlights and honk horn", isSupported: !isVolvo || preferences.volvoRestrictedScopesEnabled, badgeText: isVolvo ? "Requires Approval" : nil)
                    featureToggleRow(.remotePreCleaning, symbol: "sparkles", title: "Cabin Air Cleaning", detail: "PM2.5 pre-cleaning filtration", isSupported: !isVolvo, badgeText: isVolvo ? "In-Car Only" : nil)
                    featureToggleRow(.remoteOTA, symbol: "arrow.triangle.2.circlepath", title: "Vehicle Software Controls", detail: "Install or cancel a pending software update", isSupported: !isVolvo, badgeText: isVolvo ? "Not in API" : nil)
                }
            }
        }
    }


    private var vehicleDataCard: some View {
        let brand = preferences.activeBrand
        let isVolvo = brand == .volvo
        let brandName = brand.displayName
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "list.bullet.rectangle", title: L10n.text("Vehicle Data"), color: .green)

                let warrantyVIN = state?.vin ?? preferences.vin
                if !warrantyVIN.isEmpty, state?.warrantyInfo == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L10n.text("Warranty in-service date"))
                                    .font(.system(size: 11, weight: .medium))
                                Text(L10n.text("Not supplied by the vehicle API; enter the delivery/in-service date shown in your warranty documents."))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: $hasWarrantyInServiceDate)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .onChange(of: hasWarrantyInServiceDate) { _, enabled in
                                    preferences.setWarrantyInServiceDate(enabled ? warrantyInServiceDate : nil, for: warrantyVIN)
                                    onSettingsChanged(.presentation)
                                }
                        }
                        if hasWarrantyInServiceDate {
                            DatePicker(
                                L10n.text("In-Service Date"),
                                selection: $warrantyInServiceDate,
                                in: ...Date(),
                                displayedComponents: .date
                            )
                            .datePickerStyle(.compact)
                            .controlSize(.small)
                            .onChange(of: warrantyInServiceDate) { _, date in
                                preferences.setWarrantyInServiceDate(date, for: warrantyVIN)
                                onSettingsChanged(.presentation)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                if !warrantyVIN.isEmpty, state?.powertrain.hasElectricRange == true {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L10n.text("Exact vehicle references"))
                                    .font(.system(size: 11, weight: .medium))
                                Text(L10n.text("Optional VIN-specific values from the vehicle specification sheet. These replace broad model-family references in calculated range and SoH estimates."))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            InformationButton(message: L10n.text("User-entered reference data is always labelled as such. It does not become provider telemetry or a measured battery value."))
                        }
                        HStack {
                            Text(L10n.text("Usable battery capacity"))
                                .font(.system(size: 10.5))
                            Spacer()
                            TextField(L10n.text("Automatic"), text: $usableBatteryCapacityOverride)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                                .onSubmit { saveSpecificationOverride(vin: warrantyVIN) }
                            Text("kWh").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(L10n.text("WLTP reference range"))
                                .font(.system(size: 10.5))
                            Spacer()
                            TextField(L10n.text("Automatic"), text: $wltpRangeOverride)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                                .onSubmit { saveSpecificationOverride(vin: warrantyVIN) }
                            Text("km").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        HStack {
                            Spacer()
                            Button(L10n.text("Apply References")) {
                                saveSpecificationOverride(vin: warrantyVIN)
                            }
                            .controlSize(.small)
                            if !usableBatteryCapacityOverride.isEmpty || !wltpRangeOverride.isEmpty {
                                Button(L10n.text("Reset")) {
                                    usableBatteryCapacityOverride = ""
                                    wltpRangeOverride = ""
                                    saveSpecificationOverride(vin: warrantyVIN)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                subsectionHeader("Vehicle & Identity")
                VStack(spacing: 4) {
                    featureToggleRow(.vehicleIdentity, symbol: "car.side", title: "Vehicle Identity", detail: "Model, year, license plate & VIN")
                    featureToggleRow(.ownerGreeting, symbol: "person.text.rectangle", title: "Owner Greeting", detail: L10n.format("Show the %@ ID first name", brandName), isSupported: !isVolvo, badgeText: isVolvo ? "N/A on Volvo" : nil)
                    featureToggleRow(.vehicleImage, symbol: "photo.artframe", title: "Studio Vehicle Image", detail: L10n.format("Render high-resolution %@ visual", brandName))
                    featureToggleRow(.vehicleAvailability, symbol: "antenna.radiowaves.left.and.right", title: "Vehicle Availability", detail: "Show online state and command availability")
                }

                subsectionHeader("Charging & Energy")
                VStack(spacing: 4) {
                    featureToggleRow(.chargingDetails, symbol: "powerplug.fill", title: "Charging Telemetry", detail: "Power, voltage, current & completion time")
                    featureToggleRow(.chargingSchedule, symbol: "calendar.badge.clock", title: "Charging Schedules", detail: "Show charging windows and departure times", isSupported: !isVolvo, badgeText: isVolvo ? "Deprecated in API v2" : nil)
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
                    featureToggleRow(.airQuality, symbol: "wind", title: "Cabin Air Quality", detail: "AQI & particulate matter sensors", isSupported: !isVolvo, badgeText: isVolvo ? "In-Car Only" : nil)
                }

                subsectionHeader("Location & Weather")
                VStack(spacing: 4) {
                    featureToggleRow(.vehicleLocation, symbol: "location.fill", title: "Vehicle Location & Maps", detail: "Parking GPS coordinates and Apple Maps")
                    featureToggleRow(.vehicleWeather, symbol: "cloud.sun.fill", title: "Vehicle Weather", detail: "Ambient weather at vehicle GPS location — sends vehicle coordinates to Open-Meteo")
                }

                subsectionHeader("Advanced Diagnostics")
                VStack(spacing: 4) {
                    featureToggleRow(.tripMeters, symbol: "chart.xyaxis.line", title: "Trip Meters", detail: "Manual and automatic trip computers")
                    featureToggleRow(.connectivityDiagnostics, symbol: "antenna.radiowaves.left.and.right", title: "Connectivity", detail: "Vehicle network & signal diagnostics", isSupported: !isVolvo, badgeText: isVolvo ? "Enterprise Only" : nil)
                    featureToggleRow(.softwareUpdates, symbol: "arrow.triangle.2.circlepath", title: "Vehicle Software & OTA", detail: L10n.format("%@ software version and update status", brandName))
                }
            }
        }
    }

    private func saveSpecificationOverride(vin: String) {
        func parsed(_ text: String, range: ClosedRange<Double>) -> Double? {
            guard let value = Double(text.replacingOccurrences(of: ",", with: ".")),
                  range.contains(value) else { return nil }
            return value
        }
        let value = VehicleSpecificationOverride(
            usableBatteryCapacityKwh: parsed(usableBatteryCapacityOverride, range: 5...200),
            wltpRangeKm: parsed(wltpRangeOverride, range: 50...1_200)
        )
        preferences.setVehicleSpecificationOverride(value.isEmpty ? nil : value, for: vin)
        onSettingsChanged(.presentation)
    }

    private func subsectionHeader(_ title: String) -> some View {
        Text(L10n.text(title))
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.3)
            .padding(.top, 6)
    }

    private func featureToggleRow(
        _ feature: AppFeature,
        symbol: String,
        title: String,
        detail: String,
        isSupported: Bool = true,
        badgeText: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isSupported ? .secondary : .tertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(L10n.text(title))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSupported ? .primary : .secondary)
                    if let badgeText {
                        Text(L10n.text(badgeText))
                            .font(.system(size: 8, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(L10n.text(detail))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(isSupported ? 1.0 : 0.7))
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isSupported && features.contains(feature) },
                set: { enabled in
                    guard isSupported else { return }
                    features.set(feature, enabled: enabled)
                    preferences.features = features
                    onSettingsChanged(.features)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(!isSupported)
        }
        .padding(.vertical, 3)
        .opacity(isSupported ? 1.0 : 0.55)
    }

    private func degradedNotice(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(HisingenTheme.semanticWarning)
            Text(text)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(HisingenTheme.semanticWarning.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var capabilitiesCard: AnyView {
        guard let state else { return AnyView(EmptyView()) }
        let profile = state.capabilityProfile
        let items = VehicleCapability.displayed

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "checklist", title: L10n.text("Vehicle Capability Matrix"), color: .blue)
                Text(L10n.format("Capability assessment for %@ (%@)", state.modelName ?? L10n.text("Vehicle"), state.vin))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                // A degraded dashboard should explain itself here rather than only in the
                // unified log — the cached snapshot keeps very little telemetry, so cards
                // going quiet is otherwise indistinguishable from an unsupported vehicle.
                if state.isCachedSnapshot {
                    degradedNotice(
                        symbol: "internaldrive",
                        text: L10n.text("Showing the last saved snapshot — most live telemetry is unavailable until the next successful refresh.")
                    )
                } else if !state.unavailableFeatures.isEmpty {
                    degradedNotice(
                        symbol: "exclamationmark.arrow.triangle.2.circlepath",
                        text: L10n.format(
                            "The last refresh could not read: %@",
                            state.unavailableFeatures.map(\.title).sorted().joined(separator: ", ")
                        )
                    )
                }

                VStack(spacing: 6) {
                    ForEach(items, id: \.self) { cap in
                        let support = profile.support(for: cap)
                        HStack {
                            Text(cap.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(HisingenTheme.ink)
                            Spacer()
                            let color: Color = {
                                switch support {
                                case .supported: return HisingenTheme.semanticGood
                                case .vehicleManaged: return .blue
                                case .unavailable: return HisingenTheme.semanticWarning
                                case .backendDependent: return .secondary
                                }
                            }()
                            Pill(text: support.displayName, color: color, symbol: support.symbolName)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Text(L10n.text("\"Direct tyre-pressure values\" means numeric kPa readings. Many vehicles report a warning level per tyre instead (indirect TPMS); those warnings still appear on the vehicle overview and in notifications."))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        })
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
                        persist: { preferences.notifyChargingStarted = $0 }
                    )
                    notificationRow(
                        symbol: "battery.100.bolt",
                        title: "Charging Complete",
                        detail: "Alert when target state of charge is reached",
                        isOn: $notifyChargingComplete,
                        persist: { preferences.notifyChargingComplete = $0 }
                    )
                    notificationRow(
                        symbol: "exclamationmark.triangle.fill",
                        title: "Charging Interrupted",
                        detail: "Alert if charging stops unexpectedly",
                        isOn: $notifyChargingProblem,
                        persist: { preferences.notifyChargingProblem = $0 }
                    )
                    notificationRow(
                        symbol: "battery.25",
                        title: "Low Battery Warning",
                        detail: "Alert when battery falls below threshold",
                        isOn: $notifyLowBattery,
                        persist: { preferences.notifyLowBattery = $0 }
                    )

                    notificationRow(
                        symbol: "arrow.triangle.2.circlepath",
                        title: "Software Updates",
                        detail: "Alert when vehicle software becomes available or finishes installing",
                        isOn: $notifySoftwareUpdates,
                        persist: { preferences.notifySoftwareUpdates = $0 }
                    )

                    notificationRow(
                        symbol: "exclamationmark.triangle.fill",
                        title: "Vehicle Warnings & Alarm",
                        detail: "Alert for new service, tyre, light, 12 V, fluid, or alarm warnings",
                        isOn: $notifyVehicleWarnings,
                        persist: { preferences.notifyVehicleWarnings = $0 }
                    )

                    notificationRow(
                        symbol: "door.left.hand.open",
                        title: "Open Door or Window",
                        detail: "Alert after an opening has been left open for 15 minutes",
                        isOn: $notifyOpeningsLeftOpen,
                        persist: { preferences.notifyOpeningsLeftOpen = $0 }
                    )

                    notificationRow(
                        symbol: "wrench.and.screwdriver.fill",
                        title: "Service Due Soon",
                        detail: "Alert at 30 days, 1,000 km, or a provider service warning",
                        isOn: $notifyServiceDue,
                        persist: { preferences.notifyServiceDue = $0 }
                    )

                    notificationRow(
                        symbol: "clock.badge.exclamationmark",
                        title: "Stale Vehicle Data",
                        detail: "Alert when provider telemetry remains older than its freshness limit",
                        isOn: $notifyStaleTelemetry,
                        persist: { preferences.notifyStaleTelemetry = $0 }
                    )

                    notificationRow(
                        symbol: "bolt.trianglebadge.exclamationmark.fill",
                        title: "Unusually Slow Charging",
                        detail: "Alert below 2 kW for 15 minutes while actively charging",
                        isOn: $notifySlowCharging,
                        persist: { preferences.notifySlowCharging = $0 }
                    )

                    notificationRow(
                        symbol: "powerplug.fill",
                        title: "Plug-In Reminder",
                        detail: "Alert once at 40% or below while unplugged and not charging",
                        isOn: $notifyPlugInReminder,
                        persist: { preferences.notifyPlugInReminder = $0 }
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
                            .onChange(of: lowBatteryThreshold) { _, _ in
                                preferences.lowBatteryThreshold = lowBatteryThreshold
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
                        persist: { preferences.notifyRainWithWindowsOpen = $0 }
                    )

                    notificationRow(
                        symbol: "lock.shield.fill",
                        title: "Evening Unlocked Reminder",
                        detail: "Alert if parked and unlocked after 21:00",
                        isOn: $notifyEveningUnlocked,
                        persist: { preferences.notifyEveningUnlocked = $0 }
                    )

                    Divider().opacity(0.4)
                        .padding(.vertical, 2)

                    notificationRow(
                        symbol: "eye.slash.fill",
                        title: "Private Notification Banners",
                        detail: "Hide license plate and battery % from lock screen",
                        isOn: $privateNotificationDetails,
                        persist: { preferences.privateNotificationDetails = $0 }
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
                .onChange(of: isOn.wrappedValue) { _, value in
                    persist(value)
                    onSettingsChanged(.notifications)
                }
        }
        .padding(.vertical, 3)
    }

    private var databaseStorageCard: some View {
        let counts = databaseStats.counts
        let sizeStr = ByteCountFormatter.string(fromByteCount: databaseStats.sizeBytes, countStyle: .file)

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "cylinder.split.1x2.fill", title: L10n.text("SQLite Storage & Data"), color: .blue)

                VStack(spacing: 6) {
                    KVRow(L10n.text("Database Engine"), "SQLite 3 · WAL Mode", symbol: "server.rack")
                    KVRow(L10n.text("Storage Size"), sizeStr, symbol: "internaldrive")
                    KVRow(L10n.text("Vehicle Snapshots"), "\(counts.snapshots)", symbol: "car.side.fill")
                    KVRow(L10n.text("Charging Sessions"), "\(counts.chargingSessions) (\(counts.chargingSamples) samples)", symbol: "bolt.fill")
                    KVRow(L10n.text("Battery Health Logs"), "\(counts.batteryHealth)", symbol: "heart.fill")
                    KVRow(L10n.text("Telemetry Entries"), "\(counts.telemetry)", symbol: "chart.xyaxis.line")
                    KVRow(L10n.text("Remote Command Audit"), "\(counts.commands)", symbol: "checklist")
                }

                Divider().opacity(0.4)

                HStack(spacing: 8) {
                    Image(systemName: "location.slash.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.text("Store precise location history"))
                            .font(.system(size: 11, weight: .medium))
                        Text(L10n.text("Off by default. Live parking location still works, but coordinates are not written to history."))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $persistLocationHistory)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .onChange(of: persistLocationHistory) { _, value in
                            preferences.persistLocationHistory = value
                            if !value { database.clearStoredLocations(for: state?.vin) }
                        }
                }

                Divider().opacity(0.4)
                    .padding(.vertical, 2)

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            database.vacuum()
                            Task { await loadDatabaseStats() }
                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                databaseVacuumed = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    databaseVacuumed = false
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: databaseVacuumed ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                                Text(databaseVacuumed ? L10n.text("Optimized!") : L10n.text("Vacuum & Checkpoint"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(databaseVacuumed ? HisingenTheme.semanticGood : nil)

                        Button {
                            database.pruneHistoricalSamples(olderThanDays: 90)
                            Task { await loadDatabaseStats() }
                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                databasePruned = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    databasePruned = false
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: databasePruned ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                                Text(databasePruned ? L10n.text("Pruned!") : L10n.text("Prune Old Samples"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(databasePruned ? HisingenTheme.semanticGood : nil)
                    }

                    HStack(spacing: 8) {
                        Button {
                            let csv = database.exportChargingSessionsCSV(for: state?.vin)
                            saveCSVWithPanel(suggestedFilename: "charging_sessions_\(state?.vin.prefix(8) ?? "all").csv", csvContent: csv)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                Text(L10n.text("Export Charging (CSV)"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            let csv = database.exportBatteryHealthCSV(for: state?.vin)
                            saveCSVWithPanel(suggestedFilename: "battery_health_\(state?.vin.prefix(8) ?? "all").csv", csvContent: csv)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                Text(L10n.text("Export Health (CSV)"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    HStack(spacing: 8) {
                        Button {
                            guard let vin = state?.vin else { return }
                            saveCSVWithPanel(suggestedFilename: "telemetry_\(vin.prefix(8)).csv",
                                             csvContent: database.exportTelemetryCSV(for: vin))
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                Text(L10n.text("Export Trips (CSV)"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(state == nil)

                        Button {
                            guard let vin = state?.vin else { return }
                            saveCSVWithPanel(suggestedFilename: "command_audit_\(vin.prefix(8)).csv",
                                             csvContent: database.exportCommandAuditsCSV(for: vin))
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                Text(L10n.text("Export Commands (CSV)"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(state == nil)
                    }

                    Button {
                        guard let vin = state?.vin else { return }
                        saveCSVWithPanel(suggestedFilename: "air_quality_\(vin.prefix(8)).csv",
                                         csvContent: database.exportAirQualityCSV(for: vin))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                            Text(L10n.text("Export Air Quality (CSV)"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state == nil)

                    Button {
                        Task { @MainActor in
                            guard let data = try? await APIDiagnosticLogStore.shared.exportData() else { return }
                            saveDataWithPanel(
                                suggestedFilename: "hisingen_api_diagnostics.json",
                                contentType: .json,
                                data: data
                            )
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stethoscope")
                            Text(L10n.text("Export Redacted API Data"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L10n.text("Exports only sanitized JSON response bodies. Paths, metadata, vehicle identifiers, credentials, locations, and image URLs are removed."))
                }
            }
        }
    }

    private func saveCSVWithPanel(suggestedFilename: String, csvContent: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedFilename
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? csvContent.write(to: url, atomically: true, encoding: .utf8)
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        }
    }

    private func saveDataWithPanel(suggestedFilename: String, contentType: UTType, data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = suggestedFilename
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? data.write(to: url, options: .atomic)
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        }
    }

    private var actionsCard: some View {
        Card {
            VStack(spacing: 8) {
                Button(role: .destructive) {
                    onSignOut()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text(L10n.format("Sign Out of %@ Account", preferences.activeBrand.displayName))
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
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "car.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HisingenTheme.accent)
                Text("Hisingen")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("v\(appVersion)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("(\(buildNumber))")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 3) {
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
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Button("GitHub") {
                    if let url = URL(string: "https://github.com/NicolasKheirallah/Hisingen") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 10, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(HisingenTheme.canvas.opacity(0.5))
        }
    }

}
