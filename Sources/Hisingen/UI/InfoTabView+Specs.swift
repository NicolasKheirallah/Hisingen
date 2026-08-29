import AppKit
import SwiftUI

extension InfoTabView {
    // MARK: - Exterior & styling

    var exteriorStylingCard: some View {
        var rows: [KVRow] = []

        if let color = state.externalColour, !color.isEmpty {
            rows.append(KVRow(L10n.text("Exterior Paint"), color, symbol: "paintpalette.fill"))
        }
        if let wheels = state.wheels, !wheels.isEmpty {
            rows.append(KVRow(L10n.text("Wheels & Rims"), wheels, symbol: "circle.circle.fill"))
        }
        if let doorCount = state.exteriorStatus?.physicalDoorCount, doorCount > 0 {
            rows.append(KVRow(L10n.text("Door Sensors Reported"), L10n.format("%d Doors", doorCount), symbol: "car.side.fill", info: L10n.text("Count of physical door records returned by the vehicle API; this is not a decoded body-style specification.")))
        }

        guard !rows.isEmpty || !state.packages.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "car.fill", title: L10n.text("Exterior & Styling"), color: .blue)

                VStack(spacing: 6) {
                    ForEach(rows.indices, id: \.self) { rows[$0] }

                    if !state.packages.isEmpty {
                        HStack(alignment: .top) {
                            HStack(spacing: 6) {
                                Image(systemName: "shippingbox.fill")
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
                }
            }
        })
    }

    // MARK: - Interior & cabin

    var interiorCabinCard: some View {
        var rows: [KVRow] = []

        if let upholstery = state.upholstery, !upholstery.isEmpty {
            rows.append(KVRow(L10n.text("Interior Trim"), upholstery, symbol: "carseat.left.fill"))
        }
        if let steering = state.formattedSteeringOrientation, !steering.isEmpty {
            rows.append(KVRow(L10n.text("Steering Orientation"), steering, symbol: "steeringwheel"))
        }
        if let climate = state.climateStatus {
            if let interior = climate.interiorTemperatureCelsius {
                rows.append(KVRow(L10n.text("Cabin Temperature"),
                                  Format.temperature(celsius: interior, unit: preferences.temperatureUnit),
                                  symbol: "thermometer.medium"))
            }
            if let requested = climate.requestedTemperatureCelsius {
                rows.append(KVRow(L10n.text("Requested Temperature"),
                                  Format.temperature(celsius: requested, unit: preferences.temperatureUnit),
                                  symbol: "thermometer.and.liquid.waves"))
            }
            if let level = climate.driverSeatHeatingLevel, level > 0 {
                rows.append(KVRow(L10n.text("Driver Seat Heating"), L10n.format("Level %d", level), symbol: "carseat.left.and.heat.waves"))
            }
            if let level = climate.passengerSeatHeatingLevel, level > 0 {
                rows.append(KVRow(L10n.text("Passenger Seat Heating"), L10n.format("Level %d", level), symbol: "carseat.right.and.heat.waves"))
            }
            if let level = climate.steeringWheelHeatingLevel, level > 0 {
                rows.append(KVRow(L10n.text("Steering Wheel Heating"), L10n.format("Level %d", level), symbol: "steeringwheel.and.heat.waves"))
            }
        }

        guard !rows.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "carseat.left.fill", title: L10n.text("Interior & Cabin"), color: .purple)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        })
    }

    // MARK: - Powertrain & specs

    var powertrainSpecsCard: some View {
        var rows: [KVRow] = []

        rows.append(KVRow(L10n.text("Architecture"), state.powertrain.displayName, symbol: "bolt.car.fill"))
        let specification = preferences.vehicleSpecificationOverride(for: state.vin)
        let configuredCapacity = state.powertrain.hasElectricRange
            ? (specification?.usableBatteryCapacityKwh
                ?? state.reportedBatteryCapacityKwh ?? state.factoryUsableBatteryCapacityKwh)
            : nil
        if let capacity = configuredCapacity, capacity > 0 {
            let isUserReference = specification?.usableBatteryCapacityKwh != nil
            let isProviderReported = !isUserReference && state.reportedBatteryCapacityKwh != nil
            rows.append(KVRow(
                isUserReference ? L10n.text("User-Entered Usable Capacity")
                    : (isProviderReported ? L10n.text("Reported Battery Capacity") : L10n.text("Model-Reference Battery Capacity")),
                String(format: "%.1f kWh", capacity),
                symbol: "battery.100.bolt",
                info: isUserReference
                    ? L10n.text("VIN-specific reference entered in Settings. Used for calculated energy and SoH estimates; not provider telemetry.")
                    : isProviderReported
                    ? L10n.text("Vehicle specification returned by the provider. This is not measured battery health or current usable capacity.")
                    : L10n.text("Static model-family reference used because the provider did not report the exact vehicle variant capacity.")
            ))
        }
        let wltp = specification?.wltpRangeKm ?? state.model.nominalWltpRangeKm
        if state.powertrain.hasElectricRange && wltp > 0 {
            rows.append(KVRow(
                specification?.wltpRangeKm != nil ? L10n.text("User-Entered WLTP Range") : L10n.text("Model-Reference WLTP Range"),
                Format.distance(km: wltp, decimals: 0, unit: preferences.distanceUnit), symbol: "road.lanes",
                info: specification?.wltpRangeKm != nil
                    ? L10n.text("VIN-specific reference entered in Settings. It is not a live range value.")
                    : L10n.text("Static model-family benchmark, not a VIN-specific rating or live vehicle estimate. Exact range varies by variant, wheels, market and model year.")
            ))
        }
        if state.powertrain.hasElectricRange, let connector = state.model.connectorSpec {
            rows.append(KVRow(
                L10n.text("Charge Port (reference)"),
                L10n.format("%@ · %d kW AC / %d kW DC", connector.connector, Int(connector.acKw), Int(connector.dcKw)),
                symbol: "powerplug.fill",
                info: L10n.text("Static model-family reference. Connector standard and peak charging rates vary by market and model year; this is not a VIN-specific rating.")
            ))
        }
        if let gearbox = state.gearbox, !gearbox.isEmpty {
            rows.append(KVRow(L10n.text("Transmission"), gearbox.capitalized, symbol: "gearshape.2.fill"))
        }
        if let fuel = state.fuelType, !fuel.isEmpty {
            rows.append(KVRow(L10n.text("Fuel Type"), fuel, symbol: "fuelpump.fill"))
        }
        if let liters = state.fuelAmountLiters, liters > 0 {
            rows.append(KVRow(L10n.text("Fuel Level"), Format.fuelVolume(liters: liters, unit: preferences.fuelVolumeUnit), symbol: "drop.fill", info: L10n.text("Vehicle Sensor. Liquid fuel volume remaining in the tank.")))
        }
        if let avgFuel = state.averageFuelConsumptionLPer100Km, avgFuel > 0 {
            rows.append(KVRow(L10n.text("Avg Consumption"), Format.fuelEconomy(lPer100Km: avgFuel, unit: preferences.fuelEconomyUnit), symbol: "chart.line.uptrend.xyaxis", info: L10n.text("Vehicle Calculation. Average fuel consumption recorded by the vehicle trip computer.")))
        }

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "bolt.fill", title: L10n.text("Powertrain & Specs"), color: .green)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        }
    }

    // MARK: - Service schedule

    var serviceAndHealthCard: some View {
        var rows: [KVRow] = []

        if let days = state.daysToService {
            var val = L10n.format("in %d days", days)
            if let km = state.distanceToServiceKm { val += " / \(Format.distance(km: km, unit: preferences.distanceUnit))" }
            if let trigger = state.formattedServiceTrigger { val += " (\(trigger))" }
            rows.append(KVRow(L10n.text("Service Due"), val, symbol: "wrench.and.screwdriver", valueWarning: days < 30))
        }
        if let hours = state.engineHoursToService, hours > 0 {
            rows.append(KVRow(L10n.text("Engine Hours"), "\(hours) h", symbol: "timer"))
        }
        if let workshopName = state.preferredWorkshopName, !workshopName.isEmpty {
            var val = workshopName
            if let id = state.preferredWorkshopId, !id.isEmpty { val += " (\(id))" }
            rows.append(KVRow(L10n.text("Service Center"), val, symbol: "building.2.fill"))
        } else if let id = state.preferredWorkshopId, !id.isEmpty {
            rows.append(KVRow(L10n.text("Service Center ID"), id, symbol: "building.2.fill"))
        }

        guard !rows.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "heart.text.square.fill", title: L10n.text("Service Schedule"), color: .orange)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        })
    }

    // MARK: - Factory build & identity

    var factoryBuildCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "slider.horizontal.2.square.on.square", title: L10n.text("Factory Build & Identity"), color: HisingenTheme.accent)

                VStack(spacing: 6) {
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
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                withAnimation { vinCopied = false }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(state.vin)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .privacySensitive()
                                Image(systemName: vinCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(vinCopied ? Color.green : Color.secondary)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("Copy VIN"))
                    }
                    .padding(.vertical, 2)

                    if let internalID = state.internalVehicleIdentifier, !internalID.isEmpty {
                        KVRow(L10n.text("Vehicle ID"), internalID, symbol: "barcode")
                    }
                    if let week = state.formattedBuildWeek ?? state.structureWeek, !week.isEmpty {
                        KVRow(L10n.text("Factory Build Week"), week, symbol: "calendar")
                    }
                    if let pno = state.pno34, !pno.isEmpty {
                        KVRow(L10n.text("Factory Spec (PNO34)"), pno, symbol: "tag.fill")
                    }
                    if let market = state.accountMarket, !market.isEmpty {
                        KVRow(L10n.text("Market Delivery"), market, symbol: "globe")
                    }
                    if state.availability == .available {
                        KVRow(L10n.text("Cloud Connectivity"), state.availability.displayName, symbol: "antenna.radiowaves.left.and.right")
                    }
                    if let sw = state.softwareInfo?.installedVersion ?? state.softwareInfo?.version, !sw.isEmpty {
                        KVRow(L10n.text("Backend-Reported Software"), sw, symbol: "arrow.triangle.2.circlepath.doc.on.clipboard", info: L10n.text("Unverified value from an undocumented Polestar backend field; compare it with the version shown in the vehicle."))
                    }
                }
            }
        }
    }

    // MARK: - Warranty & protection

    var warrantyAndProtectionCard: AnyView {
        let warranty = state.warrantyInfo
        let userInServiceDate = preferences.warrantyInServiceDate(for: state.vin)
        let isVolvo = (state.modelName?.lowercased().contains("volvo") == true) || (state.vin.uppercased().hasPrefix("YV"))
        let planTitle = warranty?.planName
        let brandColor = isVolvo ? HisingenTheme.volvoBlue : HisingenTheme.polestarAmber
        let brandIcon = isVolvo ? "shield.checkmark.fill" : "sparkles"

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(
                        symbol: "shield.lefthalf.filled.badge.checkmark",
                        title: L10n.text("Warranty & Protection"),
                        color: brandColor
                    )
                    Spacer()
                    if let planTitle {
                        Pill(text: planTitle, color: brandColor, symbol: brandIcon)
                    }
                }

                VStack(spacing: 6) {
                    if warranty == nil, userInServiceDate == nil {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "calendar.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                            Text(L10n.text("Warranty dates are not supplied by the vehicle API. Add the verified in-service date in Settings → Vehicle Data if you want it recorded here."))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }

                    if let userInServiceDate {
                        KVRow(
                            L10n.text("In-Service Date"),
                            Format.dateFormatter.string(from: userInServiceDate),
                            symbol: "calendar.badge.checkmark",
                            info: L10n.text("User-entered from warranty or delivery documents. The vehicle API does not provide this date.")
                        )
                    }

                    if let factoryDate = warranty?.factoryWarrantyValidUntil {
                        let isExpired = factoryDate < Date()
                        KVRow(
                            L10n.text("Manufacturer Warranty"),
                            Format.dateFormatter.string(from: factoryDate),
                            symbol: "checkmark.shield.fill",
                            warning: isExpired
                        )
                    }

                    if let batteryDate = warranty?.batteryWarrantyValidUntil, state.powertrain.hasElectricRange {
                        let isExpired = batteryDate < Date()
                        KVRow(
                            L10n.text("EV Battery (8 yr / 160k km)"),
                            Format.dateFormatter.string(from: batteryDate),
                            symbol: "bolt.shield.fill",
                            warning: isExpired
                        )
                    }

                    if state.powertrain.hasElectricRange,
                       let maxKm = warranty?.batteryWarrantyKm,
                       let odo = state.odometerKm {
                        let remainingKm = max(0, maxKm - odo)
                        let isMileageExpired = odo >= maxKm
                        KVRow(
                            L10n.text("Battery Warranty Remaining"),
                            Format.distance(km: remainingKm, grouped: true, unit: preferences.distanceUnit),
                            symbol: "gauge.with.needle",
                            warning: isMileageExpired
                        )
                    }

                    if let roadsideDate = warranty?.roadsideAssistanceValidUntil {
                        let isExpired = roadsideDate < Date()
                        let label = warranty?.assistanceContact ?? L10n.text("Roadside Assistance")
                        KVRow(
                            label,
                            Format.dateFormatter.string(from: roadsideDate),
                            symbol: "phone.badge.checkmark",
                            warning: isExpired
                        )
                    }

                    if warranty?.includedMaintenance == true {
                        KVRow(
                            L10n.text("Scheduled Maintenance"),
                            L10n.text("Included (3 Years / 50,000 km)"),
                            symbol: "wrench.and.screwdriver.fill"
                        )
                    }

                    if let digitalDate = warranty?.digitalServicesValidUntil {
                        let isExpired = digitalDate < Date()
                        KVRow(
                            L10n.text("Digital Services & Data"),
                            Format.dateFormatter.string(from: digitalDate),
                            symbol: "antenna.radiowaves.left.and.right",
                            warning: isExpired
                        )
                    }

                    if let corrosionDate = warranty?.corrosionWarrantyValidUntil {
                        let isExpired = corrosionDate < Date()
                        KVRow(
                            L10n.text("Corrosion Protection (12 yr)"),
                            Format.dateFormatter.string(from: corrosionDate),
                            symbol: "shield.fill",
                            warning: isExpired
                        )
                    }
                }
            }
        })
    }
}
