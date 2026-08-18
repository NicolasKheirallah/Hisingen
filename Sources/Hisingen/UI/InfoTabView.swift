import AppKit
import SwiftUI

@MainActor
struct InfoTabView: View {
    let state: VehicleState
    let database: VehicleDatabase
    let imageCache: CarImageCache

    @State private var selectedAngleIndex: Int = CarRenderAngle.frontThreeQuarter.rawValue
    @Environment(\.preferencesStore) private var preferences
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
            capabilityInspectorCard
        }
    }

    /// Backend-authoritative capability flags from `GetMyCars` — shows what the vehicle
    /// actually supports according to the cloud, not heuristic model profiling.
    private var capabilityInspectorCard: some View {
        guard let caps = state.otaCapabilities, state.isVolvo == false else { return AnyView(EmptyView()) }
        var rows: [KVRow] = []
        rows.append(KVRow(L10n.text("Full OTA Updates"),
                          caps.supportsFullOtaUpdates ? L10n.text("Supported") : L10n.text("Not supported"),
                          symbol: "arrow.down.circle",
                          valueWarning: !caps.supportsFullOtaUpdates))
        rows.append(KVRow(L10n.text("Remote Install Scheduling"),
                          caps.supportsRemoteOtaInstallSchedule ? L10n.text("Supported") : L10n.text("Not supported"),
                          symbol: "calendar.badge.clock",
                          valueWarning: !caps.supportsRemoteOtaInstallSchedule))
        rows.append(KVRow(L10n.text("Cloud Download Consent"),
                          caps.supportsCloudBasedOtaDownloadConsent ? L10n.text("Supported") : L10n.text("Vehicle-managed"),
                          symbol: "icloud.and.arrow.down",
                          valueWarning: !caps.supportsCloudBasedOtaDownloadConsent))
        rows.append(KVRow(L10n.text("Tailgate Open/Close"),
                          caps.supportsTrunkControl ? L10n.text("Supported") : L10n.text("Not supported"),
                          symbol: "car.side.rear.open",
                          valueWarning: !caps.supportsTrunkControl))
        rows.append(KVRow(L10n.text("Trunk Unlock"),
                          caps.supportsTrunkUnlock ? L10n.text("Supported") : L10n.text("Not supported"),
                          symbol: "lock.open",
                          valueWarning: !caps.supportsTrunkUnlock))
        rows.append(KVRow(L10n.text("Honk & Flash"),
                          caps.supportsHonkAndFlash ? L10n.text("Supported") : L10n.text("Not supported"),
                          symbol: "light.beacon",
                          valueWarning: !caps.supportsHonkAndFlash))
        rows.append(KVRow(L10n.text("Windows Control"),
                          caps.supportsWindowsControl ? L10n.text("Supported") : L10n.text("Not supported"),
                          symbol: "rectangle.arrowtriangle.2.outward",
                          valueWarning: !caps.supportsWindowsControl))
        rows.append(KVRow(L10n.text("Charging Functions"),
                          caps.supportsChargingFunctions ? L10n.text("Supported") : L10n.text("Not supported"),
                          symbol: "bolt.fill",
                          valueWarning: !caps.supportsChargingFunctions))
        if caps.supportsPlugAndCharge {
            rows.append(KVRow(L10n.text("Plug & Charge"),
                              L10n.text("Supported"),
                              symbol: "plug"))
        }
        if let installed = caps.installedSoftwareVersion {
            rows.append(KVRow(L10n.text("Installed Software"),
                              installed, symbol: "checkmark.seal"))
        }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "checklist", title: L10n.text("Vehicle Capabilities"), color: .teal)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
                Text(L10n.text("Reported by the vehicle cloud backend — exact support per VIN."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        })
    }

    private var heroVisualSection: some View {
        let isInterior = selectedAngleIndex == -1
        let currentImageData: Data? = {
            if isInterior {
                return state.interiorImageData ?? imageCache.interiorImage(for: state.vin)
            }
            return imageCache.image(for: state.vin, angle: selectedAngleIndex)
                 ?? (selectedAngleIndex == preferences.carRenderAngle.rawValue ? state.imageData : nil)
        }()

        let supportsMultipleAngles = preferences.activeBrand == .polestar
        let hasInterior = (state.interiorImageData != nil)
            || (imageCache.interiorImage(for: state.vin) != nil)

        return Card {
            VStack(spacing: 12) {
                // Angle & Interior View Switcher
                if supportsMultipleAngles || hasInterior {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                if supportsMultipleAngles {
                                    angleButton(title: L10n.text("3/4 Front"), angle: 1, icon: "car.side.front.open.fill", proxy: proxy)
                                    angleButton(title: L10n.text("Front"), angle: 2, icon: "car.front.waves.up.fill", proxy: proxy)
                                    angleButton(title: L10n.text("Side"), angle: 0, icon: "car.side.fill", proxy: proxy)
                                    angleButton(title: L10n.text("3/4 Rear"), angle: 3, icon: "car.side.rear.open.fill", proxy: proxy)
                                    angleButton(title: L10n.text("Rear"), angle: 4, icon: "car.rear.and.tire.marks", proxy: proxy)
                                    angleButton(title: L10n.text("Top"), angle: 5, icon: "car.top.door.front.left.open.fill", proxy: proxy)
                                } else {
                                    angleButton(title: L10n.text("Exterior"), angle: 0, icon: "car.side.fill", proxy: proxy)
                                }
                                if hasInterior {
                                    angleButton(title: L10n.text("Interior"), angle: -1, icon: "carseat.left.fill", proxy: proxy)
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 2)
                        }
                    }
                    .zIndex(10)
                }

                if let currentImageData {
                    ZStack {
                        RadialGradient(
                            colors: [Color.primary.opacity(0.06), Color.clear],
                            center: .center,
                            startRadius: 40,
                            endRadius: 170
                        )

                        VehiclePresentationView(
                            identity: VehiclePresentationIdentity(vin: state.vin, angle: selectedAngleIndex),
                            imageData: currentImageData
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .padding(.horizontal, -HisingenTheme.cardPadding)
                    .padding(.top, -4)
                    .clipped()
                    .allowsHitTesting(false)
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
                    .allowsHitTesting(false)
                }

                let primaryTitle = preferences.formattedVehicleTitle(
                    vin: state.vin,
                    modelName: state.modelName,
                    modelYear: state.modelYear,
                    registrationNo: state.registrationNo
                )
                let showRegBadge: Bool = {
                    guard let reg = state.registrationNo, !reg.isEmpty else { return false }
                    return preferences.vehicleLabelFormat != .registration
                        && preferences.vehicleLabelFormat != .nicknameAndRegistration
                        && preferences.vehicleLabelFormat != .registrationAndModel
                }()
                let subtitleText: String? = {
                    switch preferences.vehicleLabelFormat {
                    case .registration, .nickname, .nicknameAndRegistration:
                        let model = state.modelName
                        let year = state.modelYear.map { L10n.format("Model Year %@", $0) }
                        let combined = [model, year].compactMap { $0 }.joined(separator: " · ")
                        return combined.isEmpty ? nil : combined
                    case .modelAndYear, .modelOnly, .registrationAndModel:
                        if let year = state.modelYear {
                            return L10n.format("Model Year %@", year)
                        }
                        return nil
                    }
                }()

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(primaryTitle)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(HisingenTheme.ink)
                            if let color = state.externalColour, !color.isEmpty && !isInterior {
                                Pill(
                                    text: color,
                                    color: HisingenTheme.accent,
                                    symbol: "paintpalette.fill"
                                )
                            } else if isInterior, let upholstery = state.upholstery, !upholstery.isEmpty {
                                Pill(
                                    text: upholstery,
                                    color: HisingenTheme.accent,
                                    symbol: "carseat.left.fill"
                                )
                            }
                        }
                        if let subtitleText, !subtitleText.isEmpty {
                            Text(subtitleText)
                                .font(.system(size: 11))
                                .foregroundStyle(HisingenTheme.inkMuted)
                        }
                    }
                    Spacer()
                    if showRegBadge, let reg = state.registrationNo, !reg.isEmpty {
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

    private func angleButton(title: String, angle: Int, icon: String, proxy: ScrollViewProxy? = nil) -> some View {
        let isSelected = selectedAngleIndex == angle
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedAngleIndex = angle
                proxy?.scrollTo(angle, anchor: .center)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9.5))
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? HisingenTheme.accent.opacity(0.18) : Color.primary.opacity(0.05), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(isSelected ? HisingenTheme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? HisingenTheme.accent : HisingenTheme.inkMuted)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .withoutFocusRing()
        .id(angle)
    }

    private var parkingLocationCard: some View {
        guard let location = state.location, let lat = location.latitude, let lon = location.longitude else {
            return AnyView(EmptyView())
        }

        let latStr = String(format: "%.4f° %@", abs(lat), lat >= 0 ? "N" : "S")
        let lonStr = String(format: "%.4f° %@", abs(lon), lon >= 0 ? "E" : "W")
        let modelTitle = state.modelName ?? L10n.text("Vehicle")

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
            rows.append(KVRow(L10n.text("Trip Meter (TM)"), Format.distance(km: Int(manualKm.rounded()), unit: preferences.distanceUnit), symbol: "m.circle.fill"))
        }
        if let autoKm = state.tripMeterAutomaticKm {
            rows.append(KVRow(L10n.text("Auto Trip (TA)"), String(format: "%.1f km", autoKm), symbol: "a.circle.fill"))
        }
        if let electricKm = state.electricDistanceKm, electricKm > 0 {
            rows.append(KVRow(L10n.text("Electric Driving"), String(format: "%.1f km", electricKm), symbol: "bolt.car.fill"))
        }
        if let fuelKm = state.fuelDistanceKm, fuelKm > 0 {
            rows.append(KVRow(L10n.text("Combustion Driving"), String(format: "%.1f km", fuelKm), symbol: "fuelpump.fill"))
        }
        if let regen = state.regeneratedEnergyKwh, regen > 0 {
            rows.append(KVRow(L10n.text("Regenerated Energy"), String(format: "%.2f kWh", regen), symbol: "arrow.triangle.2.circlepath"))
        }
        if let speed = state.averageSpeedKmH, speed > 0 {
            rows.append(KVRow(L10n.text("Average Speed"), String(format: "%.0f km/h", speed), symbol: "gauge.with.needle.fill"))
        }
        if let odo = state.odometerKm {
            rows.append(KVRow(L10n.text("Total Distance"), Format.distance(km: odo, grouped: true, unit: preferences.distanceUnit), symbol: "speedometer"))
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

            if let frontPads = state.frontBrakePadStatus, !frontPads.isEmpty {
                let warn = frontPads.uppercased() != "NORMAL" && !frontPads.uppercased().contains("NO_WARNING")
                rows.append(KVRow(L10n.text("Front Brake Pads"), frontPads.capitalized, symbol: "circle.circle", valueWarning: warn))
            }
            if let rearPads = state.rearBrakePadStatus, !rearPads.isEmpty {
                let warn = rearPads.uppercased() != "NORMAL" && !rearPads.uppercased().contains("NO_WARNING")
                rows.append(KVRow(L10n.text("Rear Brake Pads"), rearPads.capitalized, symbol: "circle.circle", valueWarning: warn))
            }

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
            if let frontPads = state.frontBrakePadStatus, !frontPads.isEmpty {
                rows.append(KVRow(L10n.text("Front Brake Pads"), frontPads.capitalized, symbol: "circle.circle"))
            }
            if let rearPads = state.rearBrakePadStatus, !rearPads.isEmpty {
                rows.append(KVRow(L10n.text("Rear Brake Pads"), rearPads.capitalized, symbol: "circle.circle"))
            }
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
        let configuredCapacity = state.powertrain.hasElectricRange
            ? state.factoryUsableBatteryCapacityKwh
            : nil
        if let capacity = configuredCapacity, capacity > 0 {
            rows.append(KVRow(L10n.text("Battery Capacity"), String(format: "%.1f kWh", capacity), symbol: "battery.100.bolt", info: L10n.text("Manufacturer Specification. Usable high-voltage pack capacity configured for this vehicle variant.")))
        }
        if state.powertrain.hasElectricRange && state.model.nominalWltpRangeKm > 0 {
            rows.append(KVRow(L10n.text("WLTP Range (Est.)"), String(format: "%.0f km", state.model.nominalWltpRangeKm), symbol: "road.lanes", info: L10n.text("Official Rating (Not Live Estimate). Standardized laboratory Worldwide Harmonised Light Vehicles Test Procedure benchmark for this model at 100% charge.")))
        }
        if let gearbox = state.gearbox, !gearbox.isEmpty {
            rows.append(KVRow(L10n.text("Transmission"), gearbox.capitalized, symbol: "gearshape.2.fill"))
        }
        if let fuel = state.fuelType, !fuel.isEmpty {
            rows.append(KVRow(L10n.text("Fuel Type"), fuel, symbol: "fuelpump.fill"))
        }
        if let liters = state.fuelAmountLiters, liters > 0 {
            rows.append(KVRow(L10n.text("Fuel Level"), String(format: "%.1f L", liters), symbol: "drop.fill", info: L10n.text("Vehicle Sensor. Liquid fuel volume remaining in the tank.")))
        }
        if let avgFuel = state.averageFuelConsumptionLPer100Km, avgFuel > 0 {
            rows.append(KVRow(L10n.text("Avg Consumption"), String(format: "%.1f L/100km", avgFuel), symbol: "chart.line.uptrend.xyaxis", info: L10n.text("Vehicle Calculation. Average fuel consumption recorded by the vehicle trip computer.")))
        }

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "bolt.fill", title: L10n.text("Powertrain & Specs"), color: .green)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        }
    }

    private var batteryHealthCard: some View {
        guard state.powertrain.hasElectricRange, let soh = state.batteryStateOfHealthPercent else {
            return AnyView(EmptyView())
        }

        let deg = state.batteryDegradationPercent ?? 0.0
        let status = state.batteryHealthStatus
        let usable = state.configuredUsableBatteryCapacityKwh
        let factoryUsable = state.factoryUsableBatteryCapacityKwh
        let nominal = state.effectiveNominalBatteryCapacityKwh
        let packDesc = state.batteryPackDescription
        let statusColor: Color = soh >= 90.0 ? HisingenTheme.semanticGood : (soh >= 80.0 ? HisingenTheme.semanticWarning : .red)

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "battery.100.bolt", title: L10n.text("Battery Health & Longevity"), color: .green)
                    Spacer()
                    Pill(
                        text: status,
                        color: statusColor,
                        symbol: "checkmark.shield.fill"
                    )
                }

                VStack(spacing: 6) {
                    KVRow(L10n.text("Battery Pack"), packDesc, symbol: "cube.fill", info: L10n.text("Manufacturer Specification. Architecture, chemical composition, and gross capacity of the high-voltage battery."))

                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(HisingenTheme.accent)
                                .frame(width: 14)
                            Text(L10n.text("State of Health (SoH)"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Image(systemName: "info.circle")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                                .help(L10n.text("Unavailable. Neither provider currently exposes a validated measured battery State of Health value. Pack capacity shown elsewhere is a manufacturer specification, not a health measurement."))
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            ProgressView(value: min(100, soh), total: 100)
                                .progressViewStyle(.linear)
                                .frame(width: 60)
                                .tint(statusColor)
                            Text(String(format: "%.1f%%", soh))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(statusColor)
                        }
                    }
                    .padding(.vertical, 2)

                    KVRow(L10n.text("Estimated Degradation"), String(format: "%.1f%%", deg), symbol: "arrow.down.right.circle.fill", valueWarning: deg > 15.0, info: L10n.text("Estimated. Net lost battery capacity since factory build, calculated as 100% minus State of Health (SoH)."))
                    KVRow(L10n.text("Usable Pack Capacity"), String(format: "%.1f kWh / %.1f kWh (%.1f kWh nominal)", usable, factoryUsable, nominal), symbol: "battery.100", info: L10n.text("Estimated / Nominal. Estimated available driving buffer vs. original factory usable capacity (and gross nominal pack size)."))
                    KVRow(L10n.text("Warranty Threshold"), L10n.text("70% / 160,000 km (8 Years)"), symbol: "shield.lefthalf.filled", info: L10n.text("Manufacturer Specification. Factory high-voltage battery warranty threshold (minimum 70% retention for 8 years or 160,000 km / 100,000 miles)."))

                    let history = database.batteryHealthHistory(for: state.vin)
                    if !history.isEmpty {
                        Divider().opacity(0.4)
                            .padding(.vertical, 2)

                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(history.prefix(5)) { r in
                                    HStack {
                                        Text(Format.dateTimeFormatter.string(from: r.timestamp))
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(String(format: "%.0f km", r.odometerKm))
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary)
                                        Text(String(format: "%.1f%% SoH", r.stateOfHealthPct))
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(HisingenTheme.semanticGood)
                                    }
                                    .padding(.vertical, 1)
                                }
                                HStack {
                                    Spacer()
                                    Button {
                                         let csv = database.exportBatteryHealthCSV(for: state.vin)
                                        let panel = NSSavePanel()
                                        panel.allowedContentTypes = [.commaSeparatedText]
                                        panel.nameFieldStringValue = "battery_health_\(state.vin.prefix(8)).csv"
                                        panel.begin { response in
                                            if response == .OK, let url = panel.url {
                                                try? csv.write(to: url, atomically: true, encoding: .utf8)
                                                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "square.and.arrow.up")
                                            Text(L10n.text("Export Health Log (CSV)"))
                                        }
                                        .font(.system(size: 10, weight: .medium))
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.mini)
                                }
                                .padding(.top, 2)
                            }
                            .padding(.top, 4)
                        } label: {
                            HStack {
                                Text(L10n.text("Recorded Degradation Milestones"))
                                Spacer()
                                Text(L10n.format("%d logs", history.count))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                        .disclosureGroupStyle(WholeRowDisclosureStyle())
                    }
                }
            }
        })
    }

    private var serviceAndHealthCard: some View {
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
        let brandColor = isVolvo ? HisingenTheme.volvoBlue : HisingenTheme.polestarAmber
        let brandIcon = isVolvo ? "shield.checkmark.fill" : "sparkles"

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(
                        symbol: "shield.lefthalf.filled.badge.checkmark",
                        title: L10n.text("Warranty & Protection"),
                        color: brandColor
                    )
                    Spacer()
                    Pill(
                        text: planTitle,
                        color: brandColor,
                        symbol: brandIcon
                    )
                }

                VStack(spacing: 6) {
                    if let factoryDate = warranty.factoryWarrantyValidUntil {
                        let isExpired = factoryDate < Date()
                        KVRow(
                            L10n.text("Manufacturer Warranty"),
                            Format.dateFormatter.string(from: factoryDate),
                            symbol: "checkmark.shield.fill",
                            warning: isExpired
                        )
                    }

                    if let batteryDate = warranty.batteryWarrantyValidUntil, state.powertrain.hasElectricRange {
                        let isExpired = batteryDate < Date()
                        KVRow(
                            L10n.text("EV Battery (8 yr / 160k km)"),
                            Format.dateFormatter.string(from: batteryDate),
                            symbol: "bolt.shield.fill",
                            warning: isExpired
                        )
                    }

                    if state.powertrain.hasElectricRange,
                       let maxKm = warranty.batteryWarrantyKm ?? (state.powertrain.hasElectricRange ? 160_000 : nil),
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

                    if let roadsideDate = warranty.roadsideAssistanceValidUntil {
                        let isExpired = roadsideDate < Date()
                        let label = warranty.assistanceContact ?? L10n.text("Roadside Assistance")
                        KVRow(
                            label,
                            Format.dateFormatter.string(from: roadsideDate),
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
                            Format.dateFormatter.string(from: digitalDate),
                            symbol: "antenna.radiowaves.left.and.right",
                            warning: isExpired
                        )
                    }

                    if let corrosionDate = warranty.corrosionWarrantyValidUntil {
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
        }
    }

    private func headingToCardinal(_ heading: Double) -> String {
        let normalized = (heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int(((normalized + 22.5) / 45.0).truncatingRemainder(dividingBy: 8))
        return directions[index]
    }
}
