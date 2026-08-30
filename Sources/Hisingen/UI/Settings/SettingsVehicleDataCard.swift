import SwiftUI

/// Settings → Features → "Vehicle Data": optional VIN-specific reference inputs (warranty
/// in-service date, usable-capacity / WLTP overrides) followed by the full feature-toggle
/// list grouped into subsections. Extracted from `SettingsView`; the reference-input text
/// fields keep local `@State` (parse/validate on commit), feature toggles bind live.
@MainActor
struct SettingsVehicleDataCard: View {
    let state: VehicleState?
    let binder: PreferenceBinder

    @State private var hasWarrantyInServiceDate = false
    @State private var warrantyInServiceDate = Date()
    @State private var usableBatteryCapacityOverride = ""
    @State private var wltpRangeOverride = ""
    @State private var specificationValidationMessage: String?

    private var prefs: PreferencesStore { binder.preferences }
    private var warrantyVIN: String { state?.vin ?? prefs.vin }

    private func row(_ feature: AppFeature, symbol: String, title: String, detail: String,
                     isSupported: Bool = true, badgeText: String? = nil) -> SettingsFeatureToggleRow {
        SettingsFeatureToggleRow(binder: binder, feature: feature, symbol: symbol, title: title,
                                 detail: detail, isSupported: isSupported, badgeText: badgeText)
    }

    private func subsectionHeader(_ title: String) -> some View {
        Text(L10n.text(title))
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.3)
            .padding(.top, 6)
    }

    private func inlineValidation(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.red)
            .accessibilityLabel(message)
    }

    private func saveSpecificationOverride(vin: String) {
        func parsed(_ text: String, range: ClosedRange<Double>) -> Double? {
            guard let value = NumberParsing.decimal(from: text),
                  range.contains(value) else { return nil }
            return value
        }
        let capacityText = usableBatteryCapacityOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let rangeText = wltpRangeOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let capacity = capacityText.isEmpty ? nil : parsed(capacityText, range: 5...200)
        let referenceRange = rangeText.isEmpty ? nil : parsed(rangeText, range: 50...1_200)
        guard capacityText.isEmpty || capacity != nil else {
            specificationValidationMessage = L10n.text("Usable battery capacity must be between 5 and 200 kWh.")
            return
        }
        guard rangeText.isEmpty || referenceRange != nil else {
            specificationValidationMessage = L10n.text("WLTP reference range must be between 50 and 1,200 km.")
            return
        }
        specificationValidationMessage = nil
        let value = VehicleSpecificationOverride(
            usableBatteryCapacityKwh: capacity,
            wltpRangeKm: referenceRange
        )
        prefs.setVehicleSpecificationOverride(value.isEmpty ? nil : value, for: vin)
        binder.notify(.presentation)
    }

    var body: some View {
        let brand = prefs.activeBrand
        let isVolvo = brand == .volvo
        let brandName = brand.displayName
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "list.bullet.rectangle", title: L10n.text("Vehicle Data"), color: .green)

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
                                .accessibilityLabel(L10n.text("Warranty in-service date"))
                                .onChange(of: hasWarrantyInServiceDate) { _, enabled in
                                    prefs.setWarrantyInServiceDate(enabled ? warrantyInServiceDate : nil, for: warrantyVIN)
                                    binder.notify(.presentation)
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
                                prefs.setWarrantyInServiceDate(date, for: warrantyVIN)
                                binder.notify(.presentation)
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
                        if let specificationValidationMessage {
                            inlineValidation(specificationValidationMessage)
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
                    row(.vehicleIdentity, symbol: "car.side", title: "Vehicle Identity", detail: "Model, year, license plate & VIN")
                    row(.ownerGreeting, symbol: "person.text.rectangle", title: "Owner Greeting", detail: L10n.format("Show the %@ ID first name", brandName), isSupported: !isVolvo, badgeText: isVolvo ? "N/A on Volvo" : nil)
                    row(.vehicleImage, symbol: "photo.artframe", title: "Studio Vehicle Image", detail: L10n.format("Render high-resolution %@ visual", brandName))
                    row(.vehicleAvailability, symbol: "antenna.radiowaves.left.and.right", title: "Vehicle Availability", detail: "Show online state and command availability")
                }

                subsectionHeader("Charging & Energy")
                VStack(spacing: 4) {
                    row(.chargingDetails, symbol: "powerplug.fill", title: "Charging Telemetry", detail: "Power, voltage, current & completion time")
                    row(.chargingSchedule, symbol: "calendar.badge.clock", title: "Charging Schedules", detail: "Show charging windows and departure times", isSupported: !isVolvo, badgeText: isVolvo ? "Deprecated in API v2" : nil)
                    row(.batteryDiagnostics, symbol: "batteryblock", title: "Battery Diagnostics", detail: "Battery state, module health & energy usage")
                }

                subsectionHeader("Status & Security")
                VStack(spacing: 4) {
                    row(.exteriorStatus, symbol: "door.left.hand.open", title: "Exterior Doors & Windows", detail: "Open doors, windows, trunk & lock alerts")
                    row(.tyreAndWarnings, symbol: "circle.grid.2x2", title: "Tyre Pressures & Warnings", detail: "Pressure monitoring and system alerts")
                    row(.vehicleHealth, symbol: "speedometer", title: "Odometer & Service", detail: "Mileage, service intervals & fluid levels")
                }

                subsectionHeader("Climate & Air")
                VStack(spacing: 4) {
                    row(.climateStatus, symbol: "thermometer.medium", title: "Climate Status & Timers", detail: "Live interior status and scheduled timers")
                    row(.airQuality, symbol: "wind", title: "Cabin Air Quality", detail: "AQI & particulate matter sensors", isSupported: !isVolvo, badgeText: isVolvo ? "In-Car Only" : nil)
                }

                subsectionHeader("Location & Weather")
                VStack(spacing: 4) {
                    row(.vehicleLocation, symbol: "location.fill", title: "Vehicle Location & Maps", detail: "Parking GPS coordinates and Apple Maps")
                    row(.vehicleWeather, symbol: "cloud.sun.fill", title: "Vehicle Weather", detail: "Ambient weather at vehicle GPS location — sends vehicle coordinates to Open-Meteo")
                }

                subsectionHeader("Advanced Diagnostics")
                VStack(spacing: 4) {
                    row(.tripMeters, symbol: "chart.xyaxis.line", title: "Trip Meters", detail: "Manual and automatic trip computers")
                    row(.connectivityDiagnostics, symbol: "antenna.radiowaves.left.and.right", title: "Connectivity", detail: "Vehicle network & signal diagnostics", isSupported: !isVolvo, badgeText: isVolvo ? "Enterprise Only" : nil)
                    row(.softwareUpdates, symbol: "arrow.triangle.2.circlepath", title: "Vehicle Software & OTA", detail: L10n.format("%@ software version and update status", brandName))
                }

                subsectionHeader("App Integration")
                VStack(spacing: 4) {
                    row(.multipleVehicles, symbol: "car.2.fill", title: "Vehicle Switcher", detail: "Show controls for moving between vehicles on the same account")
                    row(.updateChecks, symbol: "arrow.down.circle", title: "App Update Checks", detail: "Allow checks against Hisingen’s signed stable update feed")
                    row(.vehicleErrors, symbol: "exclamationmark.bubble", title: "Vehicle Service Errors", detail: "Fetch charging and climate errors reported by the vehicle service")
                    row(.realTimeUpdates, symbol: "dot.radiowaves.left.and.right", title: "Real-Time Updates", detail: "Use live server streaming when supported, with polling as fallback", isSupported: !isVolvo, badgeText: isVolvo ? "Polling Only" : nil)
                }
            }
        }
        .onAppear {
            if let savedDate = prefs.warrantyInServiceDate(for: warrantyVIN) {
                hasWarrantyInServiceDate = true
                warrantyInServiceDate = savedDate
            }
            if let specification = prefs.vehicleSpecificationOverride(for: warrantyVIN) {
                usableBatteryCapacityOverride = specification.usableBatteryCapacityKwh
                    .map { String(format: "%.1f", $0) } ?? ""
                wltpRangeOverride = specification.wltpRangeKm
                    .map { String(format: "%.0f", $0) } ?? ""
            }
        }
    }
}
