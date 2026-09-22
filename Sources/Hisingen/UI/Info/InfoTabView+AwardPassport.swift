import SwiftUI

extension InfoTabView {
    /// The Info destination is a technical passport, not a second dashboard. The side profile
    /// anchors identity while the four callouts answer the specifications people check first.
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

        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Vehicle & Identity"))
                .hisType(.micro, weight: .bold)
                .foregroundStyle(HisingenTheme.accent)

            Text(title.isEmpty ? state.model.displayName : title)
                .hisType(size: 30, weight: .bold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            HStack(spacing: 24) {
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
                .frame(maxWidth: .infinity, minHeight: 165, maxHeight: 190)
                .accessibilityLabel(L10n.format("%@ vehicle profile", title))

                VStack(alignment: .leading, spacing: 0) {
                    passportCallout(
                        symbol: "bolt.fill",
                        value: capacity.map { Format.energyKwh($0) } ?? "–",
                        label: L10n.text("Battery Capacity")
                    )
                    passportCallout(
                        symbol: "road.lanes",
                        value: state.primaryRangeKm.map {
                            Format.distance(km: $0, unit: preferences.distanceUnit)
                        } ?? "–",
                        label: L10n.text("Estimated Range")
                    )
                    passportCallout(
                        symbol: "cable.connector",
                        value: model.connectorSpec?.connector ?? "–",
                        label: L10n.text("DC Charge Port")
                    )
                    passportCallout(
                        symbol: "thermometer.medium",
                        value: state.climateStatus?.interiorTemperatureCelsius.map {
                            Format.temperature(celsius: $0, unit: preferences.temperatureUnit)
                        } ?? "–",
                        label: L10n.text("Cabin Temperature"),
                        drawsDivider: false
                    )
                }
                .frame(width: 205)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    private func passportCallout(
        symbol: String,
        value: String,
        label: String,
        drawsDivider: Bool = true
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(HisingenTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .hisType(.body, weight: .bold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(label)
                    .hisType(.micro, weight: .medium)
                    .foregroundStyle(HisingenTheme.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 42)
        .overlay(alignment: .bottom) {
            if drawsDivider { Divider() }
        }
    }
}
