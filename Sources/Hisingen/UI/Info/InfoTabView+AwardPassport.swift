import SwiftUI

extension InfoTabView {
    var awardVehiclePassport: some View {
        let identity = state.identity
        let model = state.model
        let capacity = state.measuredCapacityReference(
            specification: preferences.vehicleSpecificationOverride(for: identity.vin)
        )?.kwh
        let title = identity.modelName.flatMap { $0.isEmpty ? nil : $0 } ?? model.displayName
        let redacted = preferences.privacyRedactionEnabled
        let stacked = passportTypeSize.isAccessibilitySize || HisingenTheme.layoutWidth < 540

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .hisType(.display)
                    .foregroundStyle(HisingenTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let year = identity.modelYear {
                    Text(year)
                        .hisType(.subhead)
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
            }
            // Straight on the canvas, as on Now.
            InstrumentVehicleProfile(state: state, imageCache: imageCache, height: stacked ? 128 : 168, fillsWidth: true)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 14) {
                plateEntry(label: L10n.text("VIN"), value: identity.vin, redacted: redacted)

                let column: CGFloat = passportTypeSize.isAccessibilitySize ? 280 : 130
                LazyVGrid(columns: [GridItem(.adaptive(minimum: column), spacing: 14, alignment: .topLeading)],
                          alignment: .leading, spacing: 13) {
                    if let registration = identity.registrationNo, !registration.isEmpty {
                        plateEntry(label: L10n.text("Registration"), value: registration.uppercased(), redacted: redacted)
                    }
                    if let odometer = state.odometerKm {
                        plateEntry(label: L10n.text("Odometer"),
                                   value: Format.distance(km: Double(odometer), decimals: 0, unit: preferences.distanceUnit))
                    }
                    if let capacity {
                        plateEntry(label: L10n.text("Battery Capacity"), value: Format.energyKwh(capacity))
                    }
                    if let connector = model.connectorSpec?.connector {
                        plateEntry(label: L10n.text("DC Charge Port"), value: connector)
                    }
                }
            }
        }
        .padding(.horizontal, HisingenTheme.cardPadding)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private func plateEntry(label: String, value: String, redacted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            PanelRule()
            if redacted {
                Text(L10n.text("Hidden"))
                    .hisType(.title)
                    .foregroundStyle(HisingenTheme.inkMuted)
            } else {
                Text(value)
                    .hisType(.title)
                    .monospacedDigit()
                    .foregroundStyle(HisingenTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(label)
                .hisType(.label)
                .foregroundStyle(HisingenTheme.inkMuted)
        }
        // Drawn value-first, spoken label-first.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(redacted ? L10n.text("Hidden") : value)
    }
}
