import SwiftUI

@MainActor
struct SettingsVehicleReferencesCard: View {
    let state: VehicleState?
    let binder: PreferenceBinder

    @State private var hasWarrantyInServiceDate = false
    @State private var warrantyInServiceDate = Date()
    @State private var usableBatteryCapacityOverride = ""
    @State private var wltpRangeOverride = ""
    @State private var specificationValidationMessage: String?

    private var prefs: PreferencesStore { binder.preferences }
    private var warrantyVIN: String { state?.identity.vin ?? prefs.vin }

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
        if !warrantyVIN.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "list.bullet.rectangle", title: L10n.text("Vehicle References"), color: HisingenTheme.semanticActive)
                    if !warrantyVIN.isEmpty, state?.maintenance.warranty == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(L10n.text("Warranty in-service date"))
                                        .hisType(.label, weight: .medium)
                                    Text(L10n.text("Not supplied by the vehicle API; enter the delivery/in-service date shown in your warranty documents."))
                                        .hisType(.micro)
                                        .foregroundStyle(.secondary)
                                        .hisCaptionLeading()
                                        .hisCaptionLeading()
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { hasWarrantyInServiceDate },
                                    set: { enabled in
                                        hasWarrantyInServiceDate = enabled
                                        prefs.setWarrantyInServiceDate(enabled ? warrantyInServiceDate : nil, for: warrantyVIN)
                                        binder.notify(.presentation)
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .accessibilityLabel(L10n.text("Warranty in-service date"))
                            }
                            if hasWarrantyInServiceDate {
                                DatePicker(
                                    L10n.text("In-Service Date"),
                                    selection: Binding(
                                        get: { warrantyInServiceDate },
                                        set: { date in
                                            warrantyInServiceDate = date
                                            prefs.setWarrantyInServiceDate(date, for: warrantyVIN)
                                            binder.notify(.presentation)
                                        }
                                    ),
                                    in: ...Date(),
                                    displayedComponents: .date
                                )
                                .datePickerStyle(.compact)
                                .controlSize(.small)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 0, style: .continuous))
                        .hisAnimation(Motion.layout, value: hasWarrantyInServiceDate)
                    }

                    if !warrantyVIN.isEmpty, state?.powertrain.hasElectricRange == true {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(L10n.text("Exact vehicle references"))
                                        .hisType(.label, weight: .medium)
                                    Text(L10n.text("Optional VIN-specific values from the vehicle specification sheet. These replace broad model-family references in calculated range and SoH estimates."))
                                        .hisType(.micro)
                                        .foregroundStyle(.secondary)
                                        .hisCaptionLeading()
                                        .hisCaptionLeading()
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                InformationButton(message: L10n.text("User-entered reference data is always labelled as such. It does not become provider telemetry or a measured battery value."))
                            }
                            HStack {
                                Text(L10n.text("Usable battery capacity"))
                                    .hisType(.caption)
                                Spacer()
                                HisTextField(L10n.text("Automatic"), text: $usableBatteryCapacityOverride)
                                    .frame(width: 70)
                                    .multilineTextAlignment(.trailing)
                                    .onSubmit { saveSpecificationOverride(vin: warrantyVIN) }
                                Text(L10n.text("kWh")).hisType(.micro).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(L10n.text("WLTP reference range"))
                                    .hisType(.caption)
                                Spacer()
                                HisTextField(L10n.text("Automatic"), text: $wltpRangeOverride)
                                    .frame(width: 70)
                                    .multilineTextAlignment(.trailing)
                                    .onSubmit { saveSpecificationOverride(vin: warrantyVIN) }
                                Text("km").hisType(.micro).foregroundStyle(.secondary)
                            }
                            if let specificationValidationMessage {
                                InlineValidationLabel(message: specificationValidationMessage)
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
                                    .transition(.opacity)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 0, style: .continuous))
                        // Both override texts feed the Reset button's visibility; keying
                        // on their emptiness animates its appear/disappear as one.
                        .animation(Motion.resolve(Motion.layout),
                                   value: usableBatteryCapacityOverride.isEmpty && wltpRangeOverride.isEmpty)
                    }
                    if state?.powertrain.hasElectricRange != true && state?.maintenance.warranty != nil {
                        Text(L10n.text("This vehicle has no editable warranty or battery references."))
                            .hisType(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task(id: warrantyVIN) {
                let savedDate = prefs.warrantyInServiceDate(for: warrantyVIN)
                hasWarrantyInServiceDate = savedDate != nil
                warrantyInServiceDate = savedDate ?? Date()
                let reference = prefs.vehicleSpecificationOverride(for: warrantyVIN)
                usableBatteryCapacityOverride = reference?.usableBatteryCapacityKwh
                    .map { String(format: "%.1f", locale: L10n.displayLocale, $0) } ?? ""
                wltpRangeOverride = reference?.wltpRangeKm
                    .map { String(format: "%.0f", locale: L10n.displayLocale, $0) } ?? ""
                specificationValidationMessage = nil
            }
        } else {
            UnavailableFeatureCard(
                symbol: "car",
                title: L10n.text("Vehicle References"),
                color: HisingenTheme.semanticActive,
                badge: L10n.text("No vehicle selected"),
                message: L10n.text("Connect an account and choose a vehicle to edit its references."),
                state: .unavailable
            )
        }
    }
}
