import AppKit
import SwiftUI

@MainActor
struct InfoTabView: View {
    let state: VehicleState

    @State private var vinCopied = false

    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            heroVisualSection
            exteriorStylingCard
            interiorCabinCard
            powertrainSpecsCard
            factoryBuildCard
        }
    }

    private var heroVisualSection: some View {
        Card {
            VStack(spacing: 8) {
                if let imageData = state.imageData, let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 150)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.04))
                            .frame(height: 100)
                        Image(systemName: "car.side.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(HisingenTheme.accent.opacity(0.7))
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.modelName ?? "Vehicle")
                            .font(.system(size: 15, weight: .bold))
                        if let year = state.modelYear {
                            Text(L10n.format("Model Year %@", year))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let color = state.externalColour, !color.isEmpty {
                        Pill(
                            text: color,
                            color: HisingenTheme.accent,
                            symbol: "paintpalette.fill"
                        )
                    }
                }
            }
        }
    }

    private var exteriorStylingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "car.fill", title: L10n.text("Exterior & Styling"), color: .blue)

                VStack(spacing: 6) {
                    if let color = state.externalColour, !color.isEmpty {
                        KVRow(L10n.text("Paint Color"), color, symbol: "paintpalette.fill")
                    }
                    if let wheels = state.wheels, !wheels.isEmpty {
                        KVRow(L10n.text("Wheels & Rims"), wheels, symbol: "circle.circle.fill")
                    }
                    if !state.packages.isEmpty {
                        HStack(alignment: .top) {
                            HStack(spacing: 6) {
                                Image(systemName: "shippingbox.and.arrow.backward.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(HisingenTheme.accent)
                                    .frame(width: 14)
                                Text(L10n.text("Factory Packages"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 4) {
                                ForEach(state.packages, id: \.self) { pkg in
                                    Text(pkg)
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(HisingenTheme.accent.opacity(0.12), in: Capsule())
                                        .foregroundStyle(HisingenTheme.accent)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    if let doors = state.exteriorStatus?.openings {
                        KVRow(L10n.text("Body Style"), L10n.format("%d Doors", max(4, doors.count)), symbol: "car.side.fill")
                    }
                }
            }
        }
    }

    private var interiorCabinCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "carseat.left.fill", title: L10n.text("Interior & Cabin"), color: .purple)

                VStack(spacing: 6) {
                    if let upholstery = state.upholstery, !upholstery.isEmpty {
                        KVRow(L10n.text("Interior Trim"), upholstery, symbol: "carseat.left.fill")
                    }
                    if let steering = state.formattedSteeringOrientation, !steering.isEmpty {
                        KVRow(L10n.text("Steering Orientation"), steering, symbol: "steeringwheel")
                    }
                    if let climate = state.climateStatus {
                        if let temp = climate.requestedTemperatureCelsius ?? climate.interiorTemperatureCelsius {
                            KVRow(L10n.text("Comfort Target"), String(format: "%.1f °C", temp), symbol: "thermometer.medium")
                        }
                        if let dSeat = climate.driverSeatHeatingLevel, dSeat > 0 {
                            KVRow(L10n.text("Driver Seat Heating"), L10n.format("Level %d", dSeat), symbol: "carseat.left.fill")
                        }
                        if let pSeat = climate.passengerSeatHeatingLevel, pSeat > 0 {
                            KVRow(L10n.text("Passenger Seat Heating"), L10n.format("Level %d", pSeat), symbol: "carseat.right.fill")
                        }
                        if let stHeat = climate.steeringWheelHeatingLevel, stHeat > 0 {
                            KVRow(L10n.text("Steering Wheel Heating"), L10n.format("Level %d", stHeat), symbol: "steeringwheel")
                        }
                    }
                    if let air = state.airQuality {
                        let airVal = air.cleaningState == .on ? L10n.text("Active Purifying") : L10n.text("CleanZone Ready")
                        KVRow(L10n.text("Air Filtration"), airVal, symbol: "sparkles")
                        if let aqi = air.airQualityIndex {
                            KVRow(L10n.text("Cabin AQI"), "\(aqi) AQI", symbol: "wind")
                        }
                        if let pm = air.particulateMatter25 {
                            KVRow(L10n.text("Cabin PM2.5"), "\(pm) µg/m³", symbol: "aqi.medium")
                        }
                    }
                }
            }
        }
    }

    private var powertrainSpecsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "bolt.fill", title: L10n.text("Powertrain & Battery"), color: .green)

                VStack(spacing: 6) {
                    KVRow(L10n.text("Architecture"), state.powertrain.displayName, symbol: "bolt.car.fill")
                    if let capacity = state.reportedBatteryCapacityKwh ?? (state.powertrain.hasElectricRange ? Double(state.model.nominalUsableCapacityKwh) : nil), capacity > 0 {
                        KVRow(L10n.text("Battery Capacity"), String(format: "%.1f kWh", capacity), symbol: "battery.100.bolt")
                    }
                    if let gearbox = state.gearbox, !gearbox.isEmpty {
                        KVRow(L10n.text("Transmission"), gearbox, symbol: "gearshape.2.fill")
                    }
                    if let fuel = state.fuelType, !fuel.isEmpty {
                        KVRow(L10n.text("Fuel Type"), fuel, symbol: "fuelpump.fill")
                    }
                    if let odo = state.odometerKm {
                        KVRow(L10n.text("Total Odometer"), Format.distance(km: odo, unit: Preferences.distanceUnit), symbol: "speedometer")
                    }
                }
            }
        }
    }

    private var factoryBuildCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "wrench.and.screwdriver.fill", title: L10n.text("Factory Build & Identity"), color: .orange)

                VStack(spacing: 6) {
                    if let reg = state.registrationNo, !reg.isEmpty {
                        KVRow(L10n.text("License Plate"), reg, symbol: "menucard.fill")
                    }

                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "number.square.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(HisingenTheme.accent)
                                .frame(width: 14)
                            Text(L10n.text("VIN"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(state.vin, forType: .string)
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                vinCopied = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { vinCopied = false }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(state.vin)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Image(systemName: vinCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(vinCopied ? Color.green : Color.secondary)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)

                    if let week = state.formattedBuildWeek ?? state.structureWeek, !week.isEmpty {
                        KVRow(L10n.text("Factory Build Week"), week, symbol: "calendar")
                    }
                    if let pno = state.pno34 ?? state.internalVehicleIdentifier, !pno.isEmpty {
                        KVRow(L10n.text("Factory Spec Code"), pno, symbol: "barcode")
                    }
                    if let market = state.accountMarket, !market.isEmpty {
                        KVRow(L10n.text("Market Delivery"), market, symbol: "globe")
                    }
                    if let sw = state.softwareInfo?.installedVersion ?? state.softwareInfo?.version, !sw.isEmpty {
                        KVRow(L10n.text("Software Release"), sw, symbol: "arrow.triangle.2.circlepath.doc.on.clipboard")
                    }
                }
            }
        }
    }
}
