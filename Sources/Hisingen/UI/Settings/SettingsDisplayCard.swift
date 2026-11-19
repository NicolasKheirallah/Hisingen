import SwiftUI

@MainActor
struct SettingsDisplayCard: View {
    let binder: PreferenceBinder

    @State private var distanceUnit = DistanceUnit.kilometers
    @State private var temperatureUnit = TemperatureUnit.celsius
    @State private var pressureUnit = PressureUnit.kilopascals
    @State private var fuelVolumeUnit = FuelVolumeUnit.liters
    @State private var fuelEconomyUnit = FuelEconomyUnit.litersPer100Km
    @State private var energyConsumptionUnit = EnergyConsumptionUnit.kwhPer100Km

    private var preferences: PreferencesStore { binder.preferences }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "gearshape", title: L10n.text("Language & Units"), color: HisingenTheme.semanticActive)
                languageRow
                HStack {
                    Text(L10n.text("Time Format")).hisType(.body)
                    Spacer()
                    Picker(L10n.text("Time Format"), selection: binder(\.timeFormat, .timeFormat)) {
                        ForEach(AppTimeFormat.allCases, id: \.self) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                unitsSection
                Divider().opacity(HisingenTheme.dividerOpacity)
                launchAtLoginRow
            }
        }
        .onAppear {
            distanceUnit = preferences.distanceUnit
            temperatureUnit = preferences.temperatureUnit
            pressureUnit = preferences.pressureUnit
            fuelVolumeUnit = preferences.fuelVolumeUnit
            fuelEconomyUnit = preferences.fuelEconomyUnit
            energyConsumptionUnit = preferences.energyConsumptionUnit
        }
    }

    private var languageRow: some View {
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
    }

    private var launchAtLoginRow: some View {
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
