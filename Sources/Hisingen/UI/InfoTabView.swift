import AppKit
import Charts
import SwiftUI

@MainActor
struct InfoTabView: View {
    let state: VehicleState
    let database: VehicleDatabase
    let imageCache: CarImageCache

    @State private var selectedAngleIndex: Int = CarRenderAngle.frontThreeQuarter.rawValue
    @Environment(\.preferencesStore) private var preferences
    @State private var vinCopied = false

    private var availableExteriorAngles: [CarRenderAngle] {
        CarRenderAngle.allCases.filter { angle in
            imageCache.image(for: state.vin, angle: angle.rawValue) != nil
                || (angle == preferences.carRenderAngle && state.imageData != nil)
        }
    }

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
            batteryHealthCard
            serviceAndHealthCard
            warrantyAndProtectionCard
            factoryBuildCard
            capabilityInspectorCard
            activityHistoryCard
        }
        .onAppear {
            let preferred = preferences.carRenderAngle
            selectedAngleIndex = availableExteriorAngles.contains(preferred)
                ? preferred.rawValue
                : (availableExteriorAngles.first?.rawValue ?? selectedAngleIndex)
        }
    }

    private var activityHistoryCard: some View {
        let telemetry = database.recentTelemetry(for: state.vin, limit: 30)
        let commands = database.recentCommandAudits(for: state.vin, limit: 5)
        guard !telemetry.isEmpty || !commands.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "clock.arrow.circlepath", title: L10n.text("Vehicle Activity History"), color: .indigo)
                if let newest = telemetry.first, let oldest = telemetry.last,
                   let newOdometer = newest.odometerKm, let oldOdometer = oldest.odometerKm,
                   newOdometer >= oldOdometer {
                    KVRow(
                        L10n.text("Distance Recorded"),
                        Format.distance(km: newOdometer - oldOdometer, unit: preferences.distanceUnit),
                        symbol: "road.lanes"
                    )
                }
                if !commands.isEmpty {
                    Divider().opacity(0.4)
                    Text(L10n.text("Recent remote commands"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(commands) { record in
                        HStack(spacing: 7) {
                            Image(systemName: record.status == "failed" ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(record.status == "failed" ? HisingenTheme.semanticCritical : HisingenTheme.semanticGood)
                            Text(record.command.replacingOccurrences(of: "-", with: " ").capitalized)
                                .font(.system(size: 10.5, weight: .medium))
                            Spacer()
                            Text(record.executedAt, style: .relative)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        .help(record.errorMessage ?? record.status.capitalized)
                    }
                }
                Text(L10n.text("Stored locally on this Mac. Location coordinates are excluded unless location history is enabled."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        })
    }

    /// Capability flags observed in the undocumented GetMyCars response. A true flag is a
    /// positive observation; false can also mean the field was absent, so it is not proof that
    /// the vehicle lacks the capability.
    private var capabilityInspectorCard: some View {
        guard let caps = state.otaCapabilities, state.isVolvo == false else { return AnyView(EmptyView()) }
        var rows: [KVRow] = []
        rows.append(KVRow(L10n.text("Full OTA Updates"),
                          caps.supportsFullOtaUpdates ? L10n.text("Reported supported") : L10n.text("Not reported"),
                          symbol: "arrow.down.circle",
                          valueWarning: false))
        rows.append(KVRow(L10n.text("Remote Install Scheduling"),
                          caps.supportsRemoteOtaInstallSchedule ? L10n.text("Reported supported") : L10n.text("Not reported"),
                          symbol: "calendar.badge.clock",
                          valueWarning: false))
        rows.append(KVRow(L10n.text("Cloud Download Consent"),
                          caps.supportsCloudBasedOtaDownloadConsent ? L10n.text("Reported supported") : L10n.text("Not reported"),
                          symbol: "icloud.and.arrow.down",
                          valueWarning: false))
        rows.append(KVRow(L10n.text("Tailgate Open/Close"),
                          caps.supportsTrunkControl ? L10n.text("Reported supported") : L10n.text("Not reported"),
                          symbol: "car.side.rear.open",
                          valueWarning: false))
        rows.append(KVRow(L10n.text("Trunk Unlock"),
                          caps.supportsTrunkUnlock ? L10n.text("Reported supported") : L10n.text("Not reported"),
                          symbol: "lock.open",
                          valueWarning: false))
        rows.append(KVRow(L10n.text("Honk & Flash"),
                          caps.supportsHonkAndFlash ? L10n.text("Reported supported") : L10n.text("Not reported"),
                          symbol: "light.beacon",
                          valueWarning: false))
        rows.append(KVRow(L10n.text("Windows Control"),
                          caps.supportsWindowsControl ? L10n.text("Reported supported") : L10n.text("Not reported"),
                          symbol: "rectangle.arrowtriangle.2.outward",
                          valueWarning: false))
        rows.append(KVRow(L10n.text("Charging Functions"),
                          caps.supportsChargingFunctions ? L10n.text("Reported supported") : L10n.text("Not reported"),
                          symbol: "bolt.fill",
                          valueWarning: false))
        if caps.supportsPlugAndCharge {
            rows.append(KVRow(L10n.text("Plug & Charge"),
                              L10n.text("Supported"),
                              symbol: "plug"))
        }
        if let installed = caps.installedSoftwareVersion {
            rows.append(KVRow(L10n.text("Backend-Reported Software"),
                              installed, symbol: "checkmark.seal", info: L10n.text("Unverified value from an undocumented backend field.")))
        }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "checklist", title: L10n.text("Vehicle Capabilities"), color: .teal)
                Text(L10n.text("Positive flags were reported by the backend. “Not reported” does not prove that the vehicle lacks a capability."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
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

        let exteriorAngles = availableExteriorAngles
        let supportsMultipleAngles = exteriorAngles.count > 1
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
                                    ForEach(exteriorAngles, id: \.self) { angle in
                                        angleButton(title: angle.title, angle: angle.rawValue, icon: angle.symbol, proxy: proxy)
                                    }
                                } else {
                                    let exteriorAngle = exteriorAngles.first?.rawValue ?? preferences.carRenderAngle.rawValue
                                    angleButton(title: L10n.text("Exterior"), angle: exteriorAngle, icon: "car.side.fill", proxy: proxy)
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

        let aqiVal = air.airQualityIndex
        let cleaningText: String
        let cleaningSymbol: String
        let cleaningColor: Color
        switch air.cleaningState {
        case .on:
            cleaningText = L10n.text("Purifying")
            cleaningSymbol = "sparkles"
            cleaningColor = .teal
        case .off:
            cleaningText = L10n.text("Off")
            cleaningSymbol = "power"
            cleaningColor = .secondary
        case .pending:
            cleaningText = L10n.text("Pending")
            cleaningSymbol = "clock"
            cleaningColor = .orange
        case .unknown:
            cleaningText = L10n.text("Unavailable")
            cleaningSymbol = "questionmark.circle"
            cleaningColor = .secondary
        }

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "wind", title: L10n.text("CleanZone Air Quality & Filter"), color: .teal)
                    Spacer()
                    Pill(
                        text: cleaningText,
                        color: cleaningColor,
                        symbol: cleaningSymbol
                    )
                }

                VStack(spacing: 6) {
                    if let aqiVal {
                        let aqiLabel = aqiVal <= 50 ? L10n.text("Good") : (aqiVal <= 100 ? L10n.text("Moderate") : L10n.text("Unhealthy"))
                        KVRow(L10n.text("Air Quality Index"), "\(aqiVal) AQI (\(aqiLabel))", symbol: "aqi.low", valueWarning: aqiVal > 100)
                    } else {
                        KVRow(L10n.text("Air Quality Index"), L10n.text("Unavailable"), symbol: "aqi.low", info: L10n.text("The vehicle did not report an air-quality index."))
                    }

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

                    airQualityTrendChart
                }
            }
        })
    }

    /// Local trend view over `air_quality_history` — the vehicle/provider APIs don't expose any
    /// history of their own, so this is entirely reconstructed from samples Hisingen has already
    /// recorded during normal refreshes (see `VehicleStateStore.save(_:)` /
    /// `VehicleDatabase.recordAirQuality`).
    @ViewBuilder
    private var airQualityTrendChart: some View {
        let history = database.recentAirQuality(for: state.vin, limit: 200)
            .filter { $0.airQualityIndex != nil }
            .sorted { $0.timestamp < $1.timestamp }
        if history.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Air Quality Trend"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Chart(history) { record in
                    LineMark(
                        x: .value(L10n.text("Date"), record.timestamp),
                        y: .value(L10n.text("Air Quality Index"), record.airQualityIndex ?? 0)
                    )
                    .foregroundStyle(.teal)
                    .interpolationMethod(.monotone)
                    RuleMark(y: .value(L10n.text("Moderate Threshold"), 50))
                        .foregroundStyle(.orange.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartYAxisLabel(L10n.text("AQI"))
                .frame(height: 90)
                .accessibilityLabel(L10n.text("Air quality index history chart"))
            }
        }
    }

    private var tripComputerCard: some View {
        var rows: [KVRow] = []

        if let manualKm = state.tripMeterManualKm {
            rows.append(KVRow(L10n.text("Trip Meter (TM)"), Format.distance(km: Int(manualKm.rounded()), unit: preferences.distanceUnit), symbol: "m.circle.fill"))
        }
        if let autoKm = state.tripMeterAutomaticKm {
            rows.append(KVRow(L10n.text("Automatic Trip (AT)"), Format.distance(km: autoKm, unit: preferences.distanceUnit), symbol: "a.circle.fill"))
        }
        if let electricKm = state.electricDistanceKm, electricKm > 0 {
            rows.append(KVRow(L10n.text("Electric Driving"), Format.distance(km: electricKm, unit: preferences.distanceUnit), symbol: "bolt.car.fill"))
        }
        if let fuelKm = state.fuelDistanceKm, fuelKm > 0 {
            rows.append(KVRow(L10n.text("Combustion Driving"), Format.distance(km: fuelKm, unit: preferences.distanceUnit), symbol: "fuelpump.fill"))
        }
        if let regen = state.regeneratedEnergyKwh, regen > 0 {
            rows.append(KVRow(L10n.text("Regenerated Energy"), String(format: "%.2f kWh", regen), symbol: "arrow.triangle.2.circlepath"))
        }
        if let speed = state.averageSpeedKmH, speed > 0 {
            rows.append(KVRow(L10n.text("Average Speed"), Format.speed(kmH: Int(speed.rounded()), unit: preferences.distanceUnit), symbol: "gauge.with.needle.fill"))
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
            let brakeReported = health.reportedWarnings.contains(.brakeFluid)
            rows.append(KVRow(
                L10n.text("Brake Fluid"),
                hasBrake ? L10n.text("Low / Check Required") : (brakeReported ? L10n.text("No warning reported") : L10n.text("Unavailable")),
                symbol: "circle.circle",
                valueWarning: hasBrake,
                info: L10n.text("Warning status only. The provider does not report a measured brake-fluid level.")
            ))

            if let frontPads = state.frontBrakePadStatus, !frontPads.isEmpty {
                let warn = frontPads.uppercased() != "NORMAL" && !frontPads.uppercased().contains("NO_WARNING")
                rows.append(KVRow(L10n.text("Front Brake Pads"), frontPads.capitalized, symbol: "circle.circle", valueWarning: warn))
            }
            if let rearPads = state.rearBrakePadStatus, !rearPads.isEmpty {
                let warn = rearPads.uppercased() != "NORMAL" && !rearPads.uppercased().contains("NO_WARNING")
                rows.append(KVRow(L10n.text("Rear Brake Pads"), rearPads.capitalized, symbol: "circle.circle", valueWarning: warn))
            }

            let hasWasher = health.warnings.contains(.washerFluid)
            let washerReported = health.reportedWarnings.contains(.washerFluid)
            rows.append(KVRow(L10n.text("Washer Fluid"), hasWasher ? L10n.text("Low Level") : (washerReported ? L10n.text("No warning reported") : L10n.text("Unavailable")), symbol: "drop.triangle.fill", valueWarning: hasWasher, info: L10n.text("Warning status only. The provider does not report a measured washer-fluid level.")))

            let hasCoolant = health.warnings.contains(.engineCoolant)
            let coolantReported = health.reportedWarnings.contains(.engineCoolant)
            rows.append(KVRow(L10n.text("Coolant System"), hasCoolant ? L10n.text("Check Level") : (coolantReported ? L10n.text("No warning reported") : L10n.text("Unavailable")), symbol: "thermometer.sun.fill", valueWarning: hasCoolant, info: L10n.text("Warning status only. The provider does not report a measured coolant level.")))

            let hasLight = health.warnings.contains(.exteriorLight) || !health.lightFailures.isEmpty
            let lightsReported = health.reportedWarnings.contains(.exteriorLight)
            rows.append(KVRow(L10n.text("Exterior Lighting"), hasLight ? L10n.text("Bulb Failure Detected") : (lightsReported ? L10n.text("No warning reported") : L10n.text("Unavailable")), symbol: "lightbulb.fill", valueWarning: hasLight, info: L10n.text("Warning status only; this is not a live electrical test of every exterior lamp.")))

            if !health.tyres.isEmpty {
                let hasTyreWarning = health.tyres.contains { $0.warning.needsAttention }
                let allReported = health.tyres.count == 4 && health.tyres.allSatisfy { $0.warning != .unknown || $0.kilopascals != nil }
                let tyreStatus = hasTyreWarning
                    ? L10n.text("Pressure Warning")
                    : (allReported ? L10n.text("No warning reported") : L10n.text("Unavailable"))
                rows.append(KVRow(L10n.text("Tyre Pressure Status"), tyreStatus, symbol: "circle.dashed", valueWarning: hasTyreWarning, info: L10n.text("Some providers expose warning status without a numeric tyre-pressure measurement.")))
            }
        } else {
            rows.append(KVRow(L10n.text("Brake Fluid"), L10n.text("Unavailable"), symbol: "circle.circle"))
            if let frontPads = state.frontBrakePadStatus, !frontPads.isEmpty {
                rows.append(KVRow(L10n.text("Front Brake Pads"), frontPads.capitalized, symbol: "circle.circle"))
            }
            if let rearPads = state.rearBrakePadStatus, !rearPads.isEmpty {
                rows.append(KVRow(L10n.text("Rear Brake Pads"), rearPads.capitalized, symbol: "circle.circle"))
            }
            rows.append(KVRow(L10n.text("Washer Fluid"), L10n.text("Unavailable"), symbol: "drop.triangle.fill"))
            rows.append(KVRow(L10n.text("Coolant System"), L10n.text("Unavailable"), symbol: "thermometer.sun.fill"))
            rows.append(KVRow(L10n.text("Exterior Lighting"), L10n.text("Unavailable"), symbol: "lightbulb.fill"))
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
        let sessions = database.recentChargingSessions(for: state.vin, limit: 20)
            .map { $0.toDomainSession(database: database) }
        guard let estimate = BatteryHealthEstimator.estimate(
            state: state, chargingSessions: sessions,
            specification: preferences.vehicleSpecificationOverride(for: state.vin)
        ) else {
            return AnyView(EmptyView())
        }

        let soh = estimate.stateOfHealthPercent
        let deg = estimate.degradationPercent
        let status = L10n.text("Calculated") + " · " + estimate.confidence.displayName
        let usable = estimate.estimatedUsableCapacityKwh
        let factoryUsable = estimate.referenceUsableCapacityKwh
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
                        symbol: "function"
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
                            Text(L10n.text("Calculated State of Health (SoH)"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            InformationButton(message: estimate.methodologySummary)
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

                    KVRow(L10n.text("Calculated Degradation"), String(format: "%.1f%%", deg), symbol: "arrow.down.right.circle.fill", valueWarning: deg > 15.0, info: estimate.methodologySummary)
                    KVRow(L10n.text("Estimated Usable Capacity"), String(format: "%.1f kWh / %.1f kWh (%.1f kWh nominal)", usable, factoryUsable, nominal), symbol: "battery.100", info: L10n.text("Calculated from the displayed SoH estimate and configured reference capacity. It is not a measured BMS capacity."))
                    KVRow(L10n.text("Typical Warranty Reference"), L10n.text("70% / 160,000 km (8 Years)"), symbol: "shield.lefthalf.filled", info: L10n.text("General reference only. Warranty coverage varies by vehicle, market and in-service date; verify your vehicle documents."))

                    DisclosureGroup(L10n.text("Calculation Signals")) {
                        VStack(spacing: 7) {
                            ForEach(estimate.signals) { signal in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(signal.title.capitalized)
                                            .font(.system(size: 10.5, weight: .semibold))
                                        Spacer()
                                        Text(String(format: "%.1f%% · %.0f%% weight", signal.estimatedSOHPercent, signal.weight * 100))
                                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(signal.explanation)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.system(size: 11, weight: .medium))

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
                                    .help(r.measurementSource == "calculated-v2"
                                        ? L10n.text("Calculated estimate using Hisingen's current multi-signal method; not a BMS measurement.")
                                        : L10n.text("Legacy calculated estimate retained for trend continuity; not a BMS measurement."))
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
                                Text(L10n.text("Calculated SoH Milestones"))
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
                        KVRow(L10n.text("Backend-Reported Software"), sw, symbol: "arrow.triangle.2.circlepath.doc.on.clipboard", info: L10n.text("Unverified value from an undocumented Polestar backend field; compare it with the version shown in the vehicle."))
                    }
                }
            }
        }
    }

    private var warrantyAndProtectionCard: AnyView {
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

    private func headingToCardinal(_ heading: Double) -> String {
        let normalized = (heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int(((normalized + 22.5) / 45.0).truncatingRemainder(dividingBy: 8))
        return directions[index]
    }
}
