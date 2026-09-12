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
    @State private var electricityPrice = "2.00"
    @State private var currencySymbol = "kr"
    @State private var nightElectricityPrice = "2.00"

    private var preferences: PreferencesStore { binder.preferences }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "display", title: L10n.text("General"), color: .blue)

                VStack(spacing: 10) {
                    HStack {
                        Text(L10n.text("Language"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: binder(\.interfaceLanguage, .presentation)) {
                            ForEach(InterfaceLanguage.allCases, id: \.self) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
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
                        Picker("", selection: binder(\.vehicleModelBadgePosition, .presentation)) {
                            ForEach(VehicleModelBadgePosition.allCases, id: \.self) { pos in
                                Text(pos.title).tag(pos)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
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
                        Picker("", selection: binder(\.registrationBadgePosition, .presentation)) {
                            ForEach(RegistrationNumberBadgePosition.allCases, id: \.self) { pos in
                                Text(pos.title).tag(pos)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
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
                        Picker("", selection: binder(\.vehicleLabelFormat, .presentation)) {
                            ForEach(VehicleLabelFormat.allCases, id: \.self) { format in
                                Text(format.title).tag(format)
                            }
                        }
                        .labelsHidden()
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
                        Toggle("", isOn: binder(\.storeChargingHistory, .presentation))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    Divider().opacity(0.4)

                    HStack {
                        Text(L10n.text("Menu bar display"))
                            .font(.system(size: 12))
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
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            if let glyphImage = MenuBarGlyphImageProvider.shared.image(for: .charging) {
                                Image(nsImage: glyphImage)
                                    .renderingMode(.template)
                                    .frame(width: 16, height: 16)
                                    .foregroundStyle(preferences.tintMenuBarIcon ? Color.green : Color.primary)
                            } else {
                                Image(systemName: Format.icon(for: previewSample))
                                    .font(.system(size: 10))
                                    .foregroundStyle(preferences.tintMenuBarIcon ? Color.green : Color.primary)
                            }
                            if preferences.menuBarStyle == .lockAndBattery,
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
                            Text(L10n.text("Panel auto-close"))
                                .font(.system(size: 12, weight: .medium))
                            Text(preferences.panelCloseBehavior.subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: binder(\.panelCloseBehavior, .presentation)) {
                            ForEach(PanelCloseBehavior.allCases, id: \.self) { behavior in
                                Text(behavior.title).tag(behavior)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 220)
                    }

                    Divider().opacity(0.4)

                    Divider().opacity(0.4)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L10n.text("Card Layout"))
                                    .font(.system(size: 12, weight: .medium))
                                Text(L10n.text("How mid-size cards flow on wide panels"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: binder(\.wideCardLayout, .presentation)) {
                                ForEach(WideCardLayout.allCases, id: \.self) { layout in
                                    Text(layout.title).tag(layout)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: 160)
                        }

                        SegmentedPresetRow(options: WideCardLayout.allCases, selection: binder(\.wideCardLayout, .presentation))
                    }

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
                        Toggle("", isOn: binder(\.tintMenuBarIcon, .presentation))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    Divider().opacity(0.4)

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

                    Divider().opacity(0.4)

                    unitRow("Temperature unit", selection: $temperatureUnit, options: TemperatureUnit.allCases, label: \.title) { _ in
                            preferences.temperatureUnit = temperatureUnit
                            binder.notify(.presentation)
                        }

                    Divider().opacity(0.4)

                    unitRow("Tyre pressure unit", selection: $pressureUnit, options: PressureUnit.allCases, label: \.title) { _ in
                            preferences.pressureUnit = pressureUnit
                            binder.notify(.presentation)
                        }

                    Divider().opacity(0.4)

                    unitRow("Fuel volume unit", selection: $fuelVolumeUnit, options: FuelVolumeUnit.allCases, label: \.title) { _ in
                            preferences.fuelVolumeUnit = fuelVolumeUnit
                            binder.notify(.presentation)
                        }

                    Divider().opacity(0.4)

                    unitRow("Fuel economy unit", selection: $fuelEconomyUnit, options: FuelEconomyUnit.allCases, label: \.title) { _ in
                            preferences.fuelEconomyUnit = fuelEconomyUnit
                            binder.notify(.presentation)
                        }

                    Divider().opacity(0.4)

                    unitRow("Electric consumption unit", selection: $energyConsumptionUnit, options: EnergyConsumptionUnit.allCases, label: \.title) { _ in
                            preferences.energyConsumptionUnit = energyConsumptionUnit
                            binder.notify(.presentation)
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
                        Toggle("", isOn: binder(\.launchAtLogin, .launchAtLogin))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
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
                                    if let price = NumberParsing.decimal(from: electricityPrice),
                                       (0.01...1_000).contains(price) {
                                        preferences.electricityPricePerKwh = price
                                    }
                                }
                            TextField("kr", text: $currencySymbol)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 45)
                                .controlSize(.small)
                                .onChange(of: currencySymbol) { _, _ in
                                    if isValidCurrencySymbol(currencySymbol) {
                                        preferences.currencySymbol = currencySymbol.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                }
                            Text("/kWh")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !isValidElectricityPrice(electricityPrice) {
                        inlineValidation(L10n.text("Enter a rate between 0.01 and 1,000."))
                    }
                    if !isValidCurrencySymbol(currencySymbol) {
                        inlineValidation(L10n.text("Enter a currency symbol or code using 1–8 characters."))
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
                        Toggle("", isOn: binder(\.nightTariffEnabled))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    if preferences.nightTariffEnabled {
                        HStack(spacing: 4) {
                            TextField("2.00", text: $nightElectricityPrice)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 55)
                                .multilineTextAlignment(.trailing)
                                .controlSize(.small)
                                .onChange(of: nightElectricityPrice) { _, _ in
                                    if let price = NumberParsing.decimal(from: nightElectricityPrice),
                                       (0.01...1_000).contains(price) {
                                        preferences.nightElectricityPricePerKwh = price
                                    }
                                }
                            Text(L10n.text("/kWh from"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Stepper(value: binder(\.nightTariffStartHour), in: 0...23) {
                                Text(String(format: "%02d:00", preferences.nightTariffStartHour))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .controlSize(.small)
                            Text(L10n.text("to"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Stepper(value: binder(\.nightTariffEndHour), in: 0...23) {
                                Text(String(format: "%02d:00", preferences.nightTariffEndHour))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .controlSize(.small)
                        }
                        if !isValidElectricityPrice(nightElectricityPrice) {
                            inlineValidation(L10n.text("Enter a night rate between 0.01 and 1,000."))
                        }
                    }

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Require device-owner authentication"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Authenticate before running remote commands"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: binder(\.requireBiometricsForRemoteControls))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel(L10n.text("Require device-owner authentication"))
                    }
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
            electricityPrice = String(format: "%.2f", preferences.electricityPricePerKwh)
            currencySymbol = preferences.currencySymbol
            nightElectricityPrice = String(format: "%.2f", preferences.nightElectricityPricePerKwh)
        }
    }

    private func isValidElectricityPrice(_ text: String) -> Bool {
        SettingsValidation.isValidElectricityPrice(text)
    }

    private func isValidCurrencySymbol(_ text: String) -> Bool {
        SettingsValidation.isValidCurrencySymbol(text)
    }

    private func inlineValidation(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.red)
            .accessibilityLabel(message)
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
                .font(.system(size: 12))
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
}
