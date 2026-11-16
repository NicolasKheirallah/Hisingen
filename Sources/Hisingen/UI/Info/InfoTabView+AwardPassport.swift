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

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .hisType(.display, weight: .light)
                    .foregroundStyle(HisingenTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let year = identity.modelYear {
                    Text(year)
                        .hisType(.body, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
            }

            InstrumentVehicleProfile(state: state, imageCache: imageCache, height: 172)

            Rectangle().fill(HisingenTheme.hairline).frame(height: 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                plateEntry(label: L10n.text("VIN"), value: identity.vin, redacted: redacted)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 14, alignment: .topLeading)],
                          alignment: .leading, spacing: 10) {
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
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .hisType(.label)
                .foregroundStyle(HisingenTheme.inkMuted)
            if redacted {
                Text(L10n.text("Hidden"))
                    .hisType(.body)
                    .foregroundStyle(HisingenTheme.inkMuted)
            } else {
                Text(value)
                    .hisType(.body, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(HisingenTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
