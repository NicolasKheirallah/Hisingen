import Foundation
import SwiftUI

@MainActor
struct SettingsDisplayCard: View {
    var state: VehicleState?
    let binder: PreferenceBinder

    @State private var distanceUnit = DistanceUnit.kilometers
    @State private var temperatureUnit = TemperatureUnit.celsius
    @State private var pressureUnit = PressureUnit.kilopascals
    @State private var fuelVolumeUnit = FuelVolumeUnit.liters
    @State private var fuelEconomyUnit = FuelEconomyUnit.litersPer100Km
    @State private var energyConsumptionUnit = EnergyConsumptionUnit.kwhPer100Km
    @State private var gridCarbonIntensity = "120"

    private var preferences: PreferencesStore { binder.preferences }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "display", title: L10n.text("Display, Units & Energy"), color: HisingenTheme.semanticActive)

                VStack(spacing: 10) {
                    labelsSection
                    historySection
                    menuBarSection
                    panelSection
                    unitsSection
                    energySection
                    securitySection
                }
            }
        }
        .onAppear {
            distanceUnit = preferences.distanceUnit
            temperatureUnit = preferences.temperatureUnit
            pressureUnit = preferences.pressureUnit
            fuelVolumeUnit = preferences.fuelVolumeUnit
            fuelEconomyUnit = preferences.fuelEconomyUnit
            energyConsumptionUnit = preferences.energyConsumptionUnit
            gridCarbonIntensity = String(format: "%.0f", locale: L10n.displayLocale, preferences.gridCarbonIntensityGramsPerKwh)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var labelsSection: some View {
        settingsGroupHeader("Language & Vehicle Labels")
        HStack {
            Text(L10n.text("Language"))
                .hisType(.body)
            Spacer()
            Picker("", selection: binder(\.interfaceLanguage, .presentation)) {
                ForEach(InterfaceLanguage.allCases, id: \.self) { language in
                    Text(language.title).tag(language)
                }
            }
            .labelsHidden()
            .accessibilityLabel(L10n.text("Language"))
            .controlSize(.small)
            .frame(maxWidth: 160)
        }

        Divider().opacity(HisingenTheme.dividerOpacity)

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("Model badge position"))
                    .hisType(.body, weight: .medium)
                Text(L10n.text("Placement of model & year label"))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: binder(\.vehicleModelBadgePosition, .presentation)) {
                ForEach(VehicleModelBadgePosition.allCases, id: \.self) { pos in
                    Text(pos.title).tag(pos)
                }
            }
            .labelsHidden()
            .accessibilityLabel(L10n.text("Model badge position"))
            .controlSize(.small)
            .frame(maxWidth: 160)
        }

        Divider().opacity(HisingenTheme.dividerOpacity)

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("License plate position"))
                    .hisType(.body, weight: .medium)
                Text(L10n.text("Placement of registration plate"))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: binder(\.registrationBadgePosition, .presentation)) {
                ForEach(RegistrationNumberBadgePosition.allCases, id: \.self) { pos in
                    Text(pos.title).tag(pos)
                }
            }
            .labelsHidden()
            .accessibilityLabel(L10n.text("License plate position"))
            .controlSize(.small)
            .frame(maxWidth: 160)
        }

        Divider().opacity(HisingenTheme.dividerOpacity)

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("Vehicle display name"))
                    .hisType(.body, weight: .medium)
                Text(L10n.text("Shown in footer switcher, menus, and vehicle headers"))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: binder(\.vehicleLabelFormat, .presentation)) {
                ForEach(VehicleLabelFormat.allCases, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
            .labelsHidden()
            .accessibilityLabel(L10n.text("Vehicle display name"))
            .controlSize(.small)
            .frame(maxWidth: 160)
        }

        let previewTitle = preferences.formattedVehicleTitle(
            vin: preferences.vin.isEmpty ? "YS2TESTVIN123456" : preferences.vin,
            modelName: state?.identity.modelName ?? (preferences.activeBrand == .polestar ? "Polestar 2" : "Volvo EX40"),
            modelYear: state?.identity.modelYear ?? "2024",
            registrationNo: state?.identity.registrationNo ?? "ZCJ 06G",
            format: preferences.vehicleLabelFormat
        )
        HStack(spacing: 6) {
            Text(L10n.text("Preview:"))
                .hisType(.label, weight: .medium)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Image(systemName: preferences.activeBrand == .polestar ? "bolt.car.fill" : "car.fill")
                    .hisType(.caption)
                    .foregroundStyle(HisingenTheme.accent)
                Text(previewTitle)
                    .hisType(.label, weight: .semibold)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var historySection: some View {
        settingsGroupHeader("History")

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("Charging Session History"))
                    .hisType(.body, weight: .medium)
                Text(L10n.text("Keep up to 20 local per-vehicle charging summaries"))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: binder.toggle(\.storeChargingHistory, .presentation))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var menuBarSection: some View {
        settingsGroupHeader("Menu Bar & Panel")

        HStack {
            Text(L10n.text("Menu bar display"))
                .hisType(.body)
            Spacer()
            Picker("", selection: binder(\.menuBarStyle, .presentation)) {
                ForEach(MenuBarStyle.allCases, id: \.self) { style in
                    Text(style.title).tag(style)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 160)
        }


        let previewSample = VehicleState(
            energy: EnergyAndChargingSnapshot(
                batteryPercentage: 82,
                rangeKm: 348,
                chargingState: .charging,
                estimatedTimeToFullMinutes: 102,
                targetPercentage: 90,
                powerWatts: 7200,
                currentAmps: 16,
                voltageVolts: 230,
                type: .ac,
                connection: .connected
            ),
            identity: VehicleIdentitySnapshot(
                availability: .available,
                modelName: "Polestar 2",
                modelYear: "2024",
                vin: "YSMTEST"
            ),
            maintenance: MaintenanceAndHealthSnapshot(odometerKm: 12500),
            freshness: SnapshotFreshness(fetchedAt: Date(), vehicleReportedAt: Date()),
            exteriorStatus: ExteriorSnapshot(openings: [], isLocked: false, alarmTriggered: false),
        )
        let previewText = Format.barTitle(for: previewSample, style: preferences.menuBarStyle, unit: distanceUnit)
        HStack(spacing: 6) {
            Text(L10n.text("Preview:"))
                .hisType(.label, weight: .medium)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                if let glyphImage = MenuBarGlyphImageProvider.shared.image(for: .charging) {
                    Image(nsImage: glyphImage)
                        .renderingMode(.template)
                        .frame(width: 16, height: 16)
                        .foregroundStyle(preferences.tintMenuBarIcon ? HisingenTheme.semanticGood : Color.primary)
                } else {
                    Image(systemName: Format.icon(for: previewSample))
                        .hisType(.caption)
                        .foregroundStyle(preferences.tintMenuBarIcon ? HisingenTheme.semanticGood : Color.primary)
                }
                if preferences.menuBarStyle == .lockAndBattery,
                   let lockSymbol = Format.lockStatusSymbol(for: previewSample) {
                    Image(systemName: lockSymbol)
                        .hisType(.body, weight: .bold)
                        .foregroundStyle(HisingenTheme.semanticWarning)
                }
                Text(previewText)
                    .hisType(.label, weight: .medium)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var panelSection: some View {
        Divider().opacity(HisingenTheme.dividerOpacity)

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("Panel auto-close"))
                    .hisType(.body, weight: .medium)
                Text(preferences.panelCloseBehavior.subtitle)
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: binder(\.panelCloseBehavior, .presentation)) {
                ForEach(PanelCloseBehavior.allCases, id: \.self) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            .labelsHidden()
            .accessibilityLabel(L10n.text("Panel close behavior"))
            .controlSize(.small)
            .frame(maxWidth: 220)
        }

        Divider().opacity(HisingenTheme.dividerOpacity)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("Card Layout"))
                        .hisType(.body, weight: .medium)
                    Text(L10n.text("How mid-size cards flow on wide panels"))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: binder(\.wideCardLayout, .presentation)) {
                    ForEach(WideCardLayout.allCases, id: \.self) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(L10n.text("Card Layout"))
                .controlSize(.small)
                .frame(maxWidth: 160)
            }

        }

        Divider().opacity(HisingenTheme.dividerOpacity)

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("Dynamic status bar tinting"))
                    .hisType(.body, weight: .medium)
                Text(L10n.text("Color icon green while charging and orange below 20%"))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: binder.toggle(\.tintMenuBarIcon, .presentation))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }

        Divider().opacity(HisingenTheme.dividerOpacity)

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("Launch at login"))
                    .hisType(.body, weight: .medium)
                Text(L10n.text("Automatically start Hisingen on macOS startup"))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: binder.toggle(\.launchAtLogin, .launchAtLogin))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var unitsSection: some View {
        settingsGroupHeader("Units")

        unitRow("Distance unit", selection: $distanceUnit, options: DistanceUnit.allCases, label: \.title) { _ in
            if !preferences.hasExplicitTemperatureUnit {
                temperatureUnit = distanceUnit == .miles ? .fahrenheit : .celsius
            }
            if !preferences.hasExplicitPressureUnit {
                pressureUnit = distanceUnit == .miles ? .psi : .kilopascals
            }
            if !preferences.hasExplicitEnergyConsumptionUnit {
                energyConsumptionUnit = distanceUnit == .miles ? .milesPerKwh : .kwhPer100Km
            }
            preferences.distanceUnit = distanceUnit
            binder.notify(.presentation)
        }

        Divider().opacity(HisingenTheme.dividerOpacity)

        unitRow("Temperature unit", selection: $temperatureUnit, options: TemperatureUnit.allCases, label: \.title) { _ in
            preferences.temperatureUnit = temperatureUnit
            binder.notify(.presentation)
        }

        Divider().opacity(HisingenTheme.dividerOpacity)

        unitRow("Tyre pressure unit", selection: $pressureUnit, options: PressureUnit.allCases, label: \.title) { _ in
            preferences.pressureUnit = pressureUnit
            binder.notify(.presentation)
        }

        Divider().opacity(HisingenTheme.dividerOpacity)

        unitRow("Fuel volume unit", selection: $fuelVolumeUnit, options: FuelVolumeUnit.allCases, label: \.title) { _ in
            preferences.fuelVolumeUnit = fuelVolumeUnit
            binder.notify(.presentation)
        }

        Divider().opacity(HisingenTheme.dividerOpacity)

        unitRow("Fuel economy unit", selection: $fuelEconomyUnit, options: FuelEconomyUnit.allCases, label: \.title) { _ in
            preferences.fuelEconomyUnit = fuelEconomyUnit
            binder.notify(.presentation)
        }

        Divider().opacity(HisingenTheme.dividerOpacity)

        unitRow("Electric consumption unit", selection: $energyConsumptionUnit, options: EnergyConsumptionUnit.allCases, label: \.title) { _ in
            preferences.energyConsumptionUnit = energyConsumptionUnit
            binder.notify(.presentation)
        }
    }

    @ViewBuilder
    private var energySection: some View {
        settingsGroupHeader("Energy & Emissions")

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Grid Carbon Intensity"))
                    .hisType(.body, weight: .medium)
                Text(L10n.text("For the emissions comparison in History"))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                TextField("120", text: $gridCarbonIntensity)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 55)
                    .multilineTextAlignment(.trailing)
                    .controlSize(.small)
                    .onChange(of: gridCarbonIntensity) { _, _ in
                        if let intensity = NumberParsing.decimal(from: gridCarbonIntensity),
                           (1...1_200).contains(intensity) {
                            preferences.gridCarbonIntensityGramsPerKwh = intensity
                        }
                    }
                Text(L10n.text("g CO₂/kWh"))
                    .hisType(.label)
                    .foregroundStyle(.secondary)
            }
        }
        if !isValidGridCarbonIntensity(gridCarbonIntensity) {
            InlineValidationLabel(message: L10n.text("Enter an intensity between 1 and 1,200 g CO₂/kWh."))
        }
    }

    @ViewBuilder
    private var securitySection: some View {
        settingsGroupHeader("Security")

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("Require device-owner authentication"))
                    .hisType(.body, weight: .medium)
                Text(L10n.text("Authenticate before running remote commands"))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: binder.toggle(\.requireBiometricsForRemoteControls))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(L10n.text("Require device-owner authentication"))
        }
    }

    // MARK: - Helpers

    private func isValidGridCarbonIntensity(_ text: String) -> Bool {
        guard let value = NumberParsing.decimal(from: text) else { return false }
        return (1...1_200).contains(value)
    }

    /// Shared scaffolding for the unit pickers. Each caller keeps its own `onChange` because
    /// only the distance row cascades into derived defaults.
    private func unitRow<Unit: Hashable>(
        _ title: String,
        selection: Binding<Unit>,
        options: [Unit],
        label: @escaping (Unit) -> String,
        onChange: @escaping (Unit) -> Void
    ) -> some View {
        HStack {
            Text(L10n.text(title))
                .hisType(.body)
            Spacer()
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { unit in
                    Text(label(unit)).tag(unit)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 160)
            .accessibilityLabel(L10n.text(title))
            .onChange(of: selection.wrappedValue) { _, newValue in
                onChange(newValue)
            }
        }
    }

    private func settingsGroupHeader(_ title: String) -> some View {
        Text(L10n.text(title))
            .hisType(.micro, weight: .semibold)
            .textCase(.uppercase)
            .foregroundStyle(HisingenTheme.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
