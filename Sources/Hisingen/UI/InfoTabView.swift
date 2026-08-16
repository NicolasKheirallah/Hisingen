import AppKit
import SwiftUI

@MainActor
struct InfoTabView: View {
    let state: VehicleState

    @State private var selectedAngleIndex: Int = Preferences.carRenderAngle.rawValue
    @State private var vinCopied = false

    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            heroVisualSection
            if let ext = state.exteriorStatus, !ext.openings.isEmpty {
                DoorsAndOpeningsCardView(ext: ext, isLocked: ext.isLocked)
            }
            if let tyres = state.healthDetails?.tyres, !tyres.isEmpty {
                TireStatusCardView(tyres: tyres, hasWarning: tyres.contains(where: { $0.warning.needsAttention }))
            }
            if state.location?.latitude != nil {
                parkingLocationCard
            }
            if state.airQuality != nil {
                airQualityCleanZoneCard
            }
            if state.tripMeterManualKm != nil || state.tripMeterAutomaticKm != nil || state.averageSpeedKmH != nil {
                tripComputerCard
            }
            fluidsAndLightingCard
            exteriorStylingCard
            interiorCabinCard
            powertrainSpecsCard
            serviceAndHealthCard
            warrantyAndProtectionCard
            factoryBuildCard
        }
    }

    private var heroVisualSection: some View {
        let isInterior = selectedAngleIndex == -1
        let currentImageData: Data? = {
            if isInterior {
                return state.interiorImageData ?? CarImageCache.shared.interiorImage(for: state.vin)
            }
            return CarImageCache.shared.image(for: state.vin, angle: selectedAngleIndex)
                ?? (selectedAngleIndex == Preferences.carRenderAngle.rawValue ? state.imageData : nil)
                ?? CarImageCache.shared.image(for: state.vin)
                ?? state.imageData
        }()

        let hasInterior = (state.interiorImageData != nil) || (CarImageCache.shared.interiorImage(for: state.vin) != nil)

        return Card {
            VStack(spacing: 10) {
                // Angle & Interior View Switcher
                HStack(spacing: 4) {
                    angleButton(title: L10n.text("Front"), angle: 0, icon: "car.side.front.open.fill")
                    angleButton(title: L10n.text("Side"), angle: 2, icon: "car.side.fill")
                    angleButton(title: L10n.text("Rear"), angle: 1, icon: "car.side.rear.open.fill")
                    if hasInterior {
                        angleButton(title: L10n.text("Interior"), angle: -1, icon: "carseat.left.fill")
                    }
                    Spacer()
                    if let color = state.externalColour, !color.isEmpty && !isInterior {
                        Pill(
                            text: color,
                            color: HisingenTheme.accent,
                            symbol: "paintpalette.fill"
                        )
                    } else if isInterior, let upholstery = state.upholstery, !upholstery.isEmpty {
                        Pill(
                            text: upholstery,
                            color: .purple,
                            symbol: "carseat.left.fill"
                        )
                    }
                }
                .padding(.horizontal, 2)

                if let currentImageData, let nsImage = NSImage(data: currentImageData) {
                    ZStack {
                        RadialGradient(
                            colors: [Color.primary.opacity(0.06), Color.clear],
                            center: .center,
                            startRadius: 40,
                            endRadius: 170
                        )

                        Image(nsImage: nsImage)
                            .interpolation(.high)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(1.33, anchor: .center)
                            .frame(maxWidth: .infinity)
                            .frame(height: 205)
                            .padding(.horizontal, 8)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            .id("\(state.vin)_\(selectedAngleIndex)")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .padding(.horizontal, -HisingenTheme.cardPadding)
                    .padding(.top, -4)
                    .clipped()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.04))
                            .frame(height: 120)
                        VStack(spacing: 6) {
                            Image(systemName: isInterior ? "carseat.left.fill" : "car.side.fill")
                                .font(.system(size: 38))
                                .foregroundStyle(HisingenTheme.accent.opacity(0.7))
                            Text(isInterior ? L10n.text("Interior View") : L10n.text("Studio Render"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.modelName ?? "Vehicle")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(HisingenTheme.ink)
                        if let year = state.modelYear {
                            Text(L10n.format("Model Year %@", year))
                                .font(.system(size: 11))
                                .foregroundStyle(HisingenTheme.inkMuted)
                        }
                    }
                    Spacer()
                    if let reg = state.registrationNo, !reg.isEmpty {
                        Text(reg)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
    }

    private func angleButton(title: String, angle: Int, icon: String) -> some View {
        let isSelected = selectedAngleIndex == angle
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedAngleIndex = angle
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9.5))
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(isSelected ? HisingenTheme.accent.opacity(0.18) : Color.primary.opacity(0.04), in: Capsule())
            .foregroundStyle(isSelected ? HisingenTheme.accent : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var parkingLocationCard: some View {
        guard let location = state.location, let lat = location.latitude, let lon = location.longitude else {
            return AnyView(EmptyView())
        }

        let latStr = String(format: "%.4f° %@", abs(lat), lat >= 0 ? "N" : "S")
        let lonStr = String(format: "%.4f° %@", abs(lon), lon >= 0 ? "E" : "W")
        let modelTitle = state.modelName ?? "Vehicle"

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "location.fill", title: L10n.text("Parking Location & Navigation"), color: .blue)
                    Spacer()
                    Button {
                        let query = "\(lat),\(lon)"
                        if let url = URL(string: "https://maps.apple.com/?q=\(modelTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Car")&ll=\(query)") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "map.fill")
                                .font(.system(size: 10))
                            Text(L10n.text("Open in Maps"))
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.blue)
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 6) {
                    KVRow(L10n.text("GPS Coordinates"), "\(latStr), \(lonStr)", symbol: "mappin.circle.fill")
                    if let alt = location.altitudeMeters {
                        KVRow(L10n.text("Altitude"), String(format: "%.0f m", alt), symbol: "mountain.2.fill")
                    }
                    if let heading = location.heading {
                        let cardinal = headingToCardinal(heading)
                        KVRow(L10n.text("Vehicle Heading"), "\(cardinal) (\(String(format: "%.0f°", heading)))", symbol: "safari.fill")
                    }
                    if let brake = location.parkingBrakeEngaged {
                        KVRow(L10n.text("Parking Brake"), brake ? L10n.text("Engaged") : L10n.text("Released"), symbol: "parkingsign.circle.fill", valueWarning: !brake)
                    }
                    if let gear = location.gear, !gear.isEmpty {
                        KVRow(L10n.text("Gear Selector"), gear.uppercased(), symbol: "gearshape.fill")
                    }
                }
            }
        })
    }

    private var airQualityCleanZoneCard: some View {
        guard let air = state.airQuality else { return AnyView(EmptyView()) }

        let aqiVal = air.airQualityIndex ?? 15
        let aqiColor: Color = aqiVal <= 50 ? .green : (aqiVal <= 100 ? .yellow : .orange)
        let aqiLabel = aqiVal <= 50 ? L10n.text("Good") : (aqiVal <= 100 ? L10n.text("Moderate") : L10n.text("Unhealthy"))

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "wind", title: L10n.text("CleanZone Air Quality & Filter"), color: .teal)
                    Spacer()
                    Pill(
                        text: air.cleaningState == .on ? L10n.text("Purifying") : L10n.text("CleanZone Active"),
                        color: air.cleaningState == .on ? .teal : aqiColor,
                        symbol: air.cleaningState == .on ? "sparkles" : "checkmark.shield.fill"
                    )
                }

                VStack(spacing: 6) {
                    KVRow(L10n.text("Air Quality Index"), "\(aqiVal) AQI (\(aqiLabel))", symbol: "aqi.low", valueWarning: aqiVal > 100)

                    if let cabinPM = air.particulateMatter25 {
                        let formattedCabin = cabinPM == 0 ? "< 1 µg/m³" : "\(cabinPM) µg/m³"
                        KVRow(L10n.text("Cabin PM2.5"), formattedCabin, symbol: "aqi.medium")
                    }
                    if let outdoorPM = air.externalParticulateMatter25 {
                        KVRow(L10n.text("Outdoor PM2.5"), "\(outdoorPM) µg/m³", symbol: "sun.haze.fill")
                    }
                    if let filterLife = air.filterRemainingPercent {
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: "allergens")
                                    .font(.system(size: 11))
                                    .foregroundStyle(HisingenTheme.accent)
                                    .frame(width: 14)
                                Text(L10n.text("HEPA Filter Life"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                ProgressView(value: Double(filterLife), total: 100)
                                    .progressViewStyle(.linear)
                                    .frame(width: 60)
                                    .tint(filterLife > 20 ? .teal : .orange)
                                Text("\(filterLife)%")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(filterLife > 20 ? Color.primary : Color.orange)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        })
    }

    private var tripComputerCard: some View {
        var rows: [KVRow] = []

        if let manualKm = state.tripMeterManualKm {
            rows.append(KVRow(L10n.text("Trip Meter (TM)"), Format.distance(km: Int(manualKm.rounded()), unit: Preferences.distanceUnit), symbol: "m.circle.fill"))
        }
        if let autoKm = state.tripMeterAutomaticKm {
            rows.append(KVRow(L10n.text("Auto Trip (TA)"), String(format: "%.1f km", autoKm), symbol: "a.circle.fill"))
        }
        if let speed = state.averageSpeedKmH, speed > 0 {
            rows.append(KVRow(L10n.text("Average Speed"), String(format: "%.0f km/h", speed), symbol: "gauge.with.needle.fill"))
        }
        if let odo = state.odometerKm {
            rows.append(KVRow(L10n.text("Total Distance"), Format.distance(km: odo, grouped: true, unit: Preferences.distanceUnit), symbol: "speedometer"))
        }

        guard !rows.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "gauge.with.dots.needle.bottom.50percent", title: L10n.text("Trip Computer & Distance"), color: .indigo)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        })
    }

    private var fluidsAndLightingCard: some View {
        var rows: [KVRow] = []

        if let health = state.healthDetails {
            let hasBrake = health.warnings.contains(.brakeFluid)
            rows.append(KVRow(L10n.text("Brake Fluid"), hasBrake ? L10n.text("Low / Check Required") : L10n.text("Normal"), symbol: "circle.circle", valueWarning: hasBrake))

            let hasWasher = health.warnings.contains(.washerFluid)
            rows.append(KVRow(L10n.text("Washer Fluid"), hasWasher ? L10n.text("Low Level") : L10n.text("Adequate"), symbol: "drop.triangle.fill", valueWarning: hasWasher))

            let hasCoolant = health.warnings.contains(.engineCoolant)
            rows.append(KVRow(L10n.text("Coolant System"), hasCoolant ? L10n.text("Check Level") : L10n.text("Optimal"), symbol: "thermometer.sun.fill", valueWarning: hasCoolant))

            let hasLight = health.warnings.contains(.exteriorLight) || !health.lightFailures.isEmpty
            rows.append(KVRow(L10n.text("Exterior Lighting"), hasLight ? L10n.text("Bulb Failure Detected") : L10n.text("All Bulbs Functional"), symbol: "lightbulb.fill", valueWarning: hasLight))

            if !health.tyres.isEmpty {
                let tyresOK = health.tyres.allSatisfy { !$0.warning.needsAttention }
                rows.append(KVRow(L10n.text("Tyre Pressure Status"), tyresOK ? L10n.text("All 4 Tyres OK") : L10n.text("Pressure Warning"), symbol: "circle.dashed", valueWarning: !tyresOK))
            }
        } else {
            rows.append(KVRow(L10n.text("Brake Fluid"), L10n.text("Normal"), symbol: "circle.circle"))
            rows.append(KVRow(L10n.text("Washer Fluid"), L10n.text("Adequate"), symbol: "drop.triangle.fill"))
            rows.append(KVRow(L10n.text("Coolant System"), L10n.text("Optimal"), symbol: "thermometer.sun.fill"))
            rows.append(KVRow(L10n.text("Exterior Lighting"), L10n.text("All Bulbs Functional"), symbol: "lightbulb.fill"))
        }

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "checklist", title: L10n.text("Fluids & Lighting Diagnostics"), color: .orange)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        }
    }

    private var exteriorStylingCard: some View {
        var rows: [KVRow] = []

        if let color = state.externalColour, !color.isEmpty {
            rows.append(KVRow(L10n.text("Exterior Paint"), color, symbol: "paintpalette.fill"))
        }
        if let wheels = state.wheels, !wheels.isEmpty {
            rows.append(KVRow(L10n.text("Wheels & Rims"), wheels, symbol: "circle.circle.fill"))
        }
        if let doors = state.exteriorStatus?.openings {
            rows.append(KVRow(L10n.text("Body Style"), L10n.format("%d Doors", max(4, doors.count)), symbol: "car.side.fill"))
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

    private var interiorCabinCard: some View {
        var rows: [KVRow] = []

        if let upholstery = state.upholstery, !upholstery.isEmpty {
            rows.append(KVRow(L10n.text("Interior Trim"), upholstery, symbol: "carseat.left.fill"))
        }
        if let steering = state.formattedSteeringOrientation, !steering.isEmpty {
            rows.append(KVRow(L10n.text("Steering Orientation"), steering, symbol: "steeringwheel"))
        }

        guard !rows.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "carseat.left.fill", title: L10n.text("Interior & Cabin"), color: .purple)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        })
    }

    private var powertrainSpecsCard: some View {
        var rows: [KVRow] = []

        rows.append(KVRow(L10n.text("Architecture"), state.powertrain.displayName, symbol: "bolt.car.fill"))
        if let capacity = state.reportedBatteryCapacityKwh ?? (state.powertrain.hasElectricRange ? Double(state.model.nominalUsableCapacityKwh) : nil), capacity > 0 {
            rows.append(KVRow(L10n.text("Battery Capacity"), String(format: "%.1f kWh", capacity), symbol: "battery.100.bolt"))
        }
        if state.powertrain.hasElectricRange && state.model.nominalWltpRangeKm > 0 {
            rows.append(KVRow(L10n.text("WLTP Range (Est.)"), String(format: "%.0f km", state.model.nominalWltpRangeKm), symbol: "road.lanes"))
        }
        if let gearbox = state.gearbox, !gearbox.isEmpty {
            rows.append(KVRow(L10n.text("Transmission"), gearbox.capitalized, symbol: "gearshape.2.fill"))
        }
        if let fuel = state.fuelType, !fuel.isEmpty {
            rows.append(KVRow(L10n.text("Fuel Type"), fuel, symbol: "fuelpump.fill"))
        }
        if let liters = state.fuelAmountLiters, liters > 0 {
            rows.append(KVRow(L10n.text("Fuel Level"), String(format: "%.1f L", liters), symbol: "drop.fill"))
        }
        if let avgFuel = state.averageFuelConsumptionLPer100Km, avgFuel > 0 {
            rows.append(KVRow(L10n.text("Avg Consumption"), String(format: "%.1f L/100km", avgFuel), symbol: "chart.line.uptrend.xyaxis"))
        }

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "bolt.fill", title: L10n.text("Powertrain & Specs"), color: .green)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        }
    }

    private var serviceAndHealthCard: some View {
        var rows: [KVRow] = []

        if let days = state.daysToService {
            var val = L10n.format("in %d days", days)
            if let km = state.distanceToServiceKm { val += " / \(Format.distance(km: km, unit: Preferences.distanceUnit))" }
            if let trigger = state.formattedServiceTrigger { val += " (\(trigger))" }
            rows.append(KVRow(L10n.text("Service Due"), val, symbol: "wrench.and.screwdriver", valueWarning: days < 30))
        }
        if let hours = state.engineHoursToService, hours > 0 {
            rows.append(KVRow(L10n.text("Engine Hours"), "\(hours) h", symbol: "timer"))
        }

        guard !rows.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "heart.text.square.fill", title: L10n.text("Service Schedule"), color: .orange)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        })
    }

    private var factoryBuildCard: some View {
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
                        KVRow(L10n.text("Software Release"), sw, symbol: "arrow.triangle.2.circlepath.doc.on.clipboard")
                    }
                }
            }
        }
    }

    private var warrantyAndProtectionCard: some View {
        let warranty = state.effectiveWarrantyInfo
        let isVolvo = (state.modelName?.lowercased().contains("volvo") == true) || (state.vin.uppercased().hasPrefix("YV"))
        let planTitle = warranty.planName ?? (isVolvo ? "Care by Volvo" : "Polestar Care")

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(
                        symbol: "shield.lefthalf.filled.badge.checkmark",
                        title: L10n.text("Warranty & Protection"),
                        color: .indigo
                    )
                    Spacer()
                    Pill(
                        text: planTitle,
                        color: .indigo,
                        symbol: "checkmark.seal.fill"
                    )
                }

                VStack(spacing: 6) {
                    if let factoryDate = warranty.factoryWarrantyValidUntil {
                        let isExpired = factoryDate < Date()
                        KVRow(
                            L10n.text("Manufacturer Warranty"),
                            Format.dateTimeFormatter.string(from: factoryDate),
                            symbol: "checkmark.shield.fill",
                            warning: isExpired
                        )
                    }

                    if let batteryDate = warranty.batteryWarrantyValidUntil, state.powertrain.hasElectricRange {
                        let isExpired = batteryDate < Date()
                        let kmLimit = warranty.batteryWarrantyKm.map { Format.distance(km: $0, grouped: true, unit: Preferences.distanceUnit) } ?? "160,000 km"
                        KVRow(
                            L10n.text("EV Battery (8 yr / 160k km)"),
                            "\(Format.dateTimeFormatter.string(from: batteryDate)) / \(kmLimit)",
                            symbol: "bolt.shield.fill",
                            warning: isExpired
                        )
                    }

                    if let roadsideDate = warranty.roadsideAssistanceValidUntil {
                        let isExpired = roadsideDate < Date()
                        let label = warranty.assistanceContact ?? L10n.text("Roadside Assistance")
                        KVRow(
                            label,
                            Format.dateTimeFormatter.string(from: roadsideDate),
                            symbol: "phone.badge.checkmark",
                            warning: isExpired
                        )
                    }

                    if warranty.includedMaintenance == true {
                        KVRow(
                            L10n.text("Scheduled Maintenance"),
                            L10n.text("Included (3 Years / 50,000 km)"),
                            symbol: "wrench.and.screwdriver.fill"
                        )
                    }

                    if let digitalDate = warranty.digitalServicesValidUntil {
                        let isExpired = digitalDate < Date()
                        KVRow(
                            L10n.text("Digital Services & Data"),
                            Format.dateTimeFormatter.string(from: digitalDate),
                            symbol: "antenna.radiowaves.left.and.right",
                            warning: isExpired
                        )
                    }

                    if let corrosionDate = warranty.corrosionWarrantyValidUntil {
                        let isExpired = corrosionDate < Date()
                        KVRow(
                            L10n.text("Corrosion Protection (12 yr)"),
                            Format.dateTimeFormatter.string(from: corrosionDate),
                            symbol: "shield.fill",
                            warning: isExpired
                        )
                    }
                }
            }
        }
    }

    private func headingToCardinal(_ heading: Double) -> String {
        let normalized = (heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int(((normalized + 22.5) / 45.0).truncatingRemainder(dividingBy: 8))
        return directions[index]
    }
}
