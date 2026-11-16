import SwiftUI

extension InfoTabView {
    /// Car: the type plate (2026-11-16 redesign). Laid out like the stamped plate in the door
    /// jamb: the model and year as the title, then identity and specification as label-over-value
    /// pairs on a tight grid. Only reported or derived facts appear; an unknown field is left out
    /// rather than shown as a dash, because a plate does not print blanks.
    var awardVehiclePassport: some View {
        let model = state.model
        let capacity = state.measuredCapacityReference(
            specification: preferences.vehicleSpecificationOverride(for: state.identity.vin)
        )?.kwh
        let title = [state.identity.modelName, state.identity.modelYear]
            .compactMap { $0 }
            .joined(separator: " · ")
        let factoryImageData = state.identity.imageData
            ?? imageCache.image(for: state.identity.vin, angle: preferences.carRenderAngle.rawValue)
            ?? imageCache.image(for: state.identity.vin)
        let redacted = preferences.privacyRedactionEnabled
        let condensed = HisingenTheme.layoutWidth < 600

        var entries: [(label: String, value: String, sensitive: Bool)] = []
        if let registration = state.identity.registrationNo, !registration.isEmpty {
            entries.append((L10n.text("Registration"), registration.uppercased(), true))
        }
        entries.append((L10n.text("VIN"), state.identity.vin, true))
        if let capacity { entries.append((L10n.text("Battery Capacity"), Format.energyKwh(capacity), false)) }
        if let connector = model.connectorSpec?.connector {
            entries.append((L10n.text("DC Charge Port"), connector, false))
        }
        if let odometer = state.odometerKm {
            entries.append((L10n.text("Odometer"),
                            Format.distance(km: Double(odometer), decimals: 0, unit: preferences.distanceUnit), false))
        }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Text(title.isEmpty ? state.model.displayName : title)
                    .hisType(size: condensed ? 26 : 32, relativeTo: .largeTitle, weight: .light)
                    .foregroundStyle(HisingenTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }

            HStack(alignment: .center, spacing: condensed ? 12 : 22) {
                Group {
                    if let factoryImageData {
                        VehiclePresentationView(
                            identity: VehiclePresentationIdentity(
                                vin: state.identity.vin,
                                angle: preferences.carRenderAngle.rawValue
                            ),
                            imageData: factoryImageData
                        )
                    } else {
                        VehicleSideProfileDoorsView(
                            openings: state.exteriorStatus?.openings ?? [],
                            model: model,
                            brand: state.model.brand
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: condensed ? 120 : 150, maxHeight: condensed ? 140 : 170)
                .accessibilityLabel(L10n.format("%@ vehicle profile", title))

                LazyVGrid(
                    columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        plateEntry(label: entry.label, value: entry.value,
                                   redacted: entry.sensitive && redacted)
                    }
                }
                .frame(width: condensed ? 220 : 260)
            }
        }
        .padding(.horizontal, condensed ? 16 : 24)
        .padding(.vertical, condensed ? 12 : 18)
        .accessibilityElement(children: .contain)
    }

    /// One stamped field: a small muted label over the value in tabular figures. The VIN and the
    /// registration follow Screenshot Privacy Mode.
    private func plateEntry(label: String, value: String, redacted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .hisType(.caption, weight: .semibold)
                .foregroundStyle(HisingenTheme.inkMuted)
            Text(value)
                .hisType(.body, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(HisingenTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .textSelection(.enabled)
                .privacySensitive(redacted)
                .redacted(reason: redacted ? .privacy : [])
        }
        .accessibilityElement(children: .combine)
    }
}
