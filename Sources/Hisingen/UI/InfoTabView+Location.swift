import AppKit
import Charts
import SwiftUI

extension InfoTabView {
    // MARK: - Activity history

    var activityHistoryCard: some View {
        let telemetry = asyncData.recentTelemetry
        let commands = asyncData.recentCommands
        guard !telemetry.isEmpty || !commands.isEmpty else { return AnyView(EmptyView()) }

        let odometerPoints = telemetry
            .compactMap { record -> (Date, Double)? in record.odometerKm.map { (record.timestamp, $0) } }
            .sorted { $0.0 < $1.0 }

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "clock.arrow.circlepath", title: L10n.text("Vehicle Activity History"), color: .indigo)
                    Spacer()
                    Button {
                        onNavigateToHistory()
                    } label: {
                        HStack(spacing: 3) {
                            Text(L10n.text("View all"))
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HisingenTheme.accent)
                }

                if let newest = telemetry.first, let oldest = telemetry.last,
                   let newOdometer = newest.odometerKm, let oldOdometer = oldest.odometerKm,
                   newOdometer >= oldOdometer {
                    KVRow(
                        L10n.text("Distance Recorded"),
                        Format.distance(km: newOdometer - oldOdometer, unit: preferences.distanceUnit),
                        symbol: "road.lanes"
                    )
                }

                if odometerPoints.count >= 2 {
                    let values = odometerPoints.map(\.1)
                    let lo = values.min() ?? 0
                    let hi = max(values.max() ?? 1, lo + 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Odometer Trend"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        Chart(Array(odometerPoints.enumerated()), id: \.offset) { _, point in
                            LineMark(
                                x: .value(L10n.text("Date"), point.0),
                                y: .value(L10n.text("Odometer"), point.1)
                            )
                            .foregroundStyle(.indigo)
                            .interpolationMethod(.monotone)
                        }
                        .chartYScale(domain: lo...hi)
                        .frame(height: 80)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.text("Odometer history chart"))
                        .accessibilityValue(chartAccessibilityValue(points: values))
                    }
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

    // MARK: - Saved charge locations

    var chargeLocationsCard: some View {
        let locations = savedChargeLocations
        guard !locations.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "mappin.and.ellipse", title: L10n.text("Saved Charge Locations"), color: .blue)
                VStack(spacing: 8) {
                    ForEach(locations) { location in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(location.alias.isEmpty ? L10n.text("Unnamed location") : location.alias)
                                    .font(.system(size: 11.5, weight: .semibold))
                                Spacer()
                                if let mode = location.optimisedChargingModeName, location.optimisedChargingEnabled {
                                    Pill(text: mode, color: HisingenTheme.accent, symbol: "leaf.fill")
                                }
                            }
                            if location.ampLimit > 0 {
                                KVRow(L10n.text("Current Limit"), "\(location.ampLimit) A", symbol: "gauge.with.dots.needle.bottom.100percent")
                            }
                            if location.minimumSoc > 0 {
                                KVRow(L10n.text("Minimum Charge"), "\(location.minimumSoc)%", symbol: "battery.25")
                            }
                            if let lat = location.latitude, let lon = location.longitude {
                                KVRow(L10n.text("Coordinates"),
                                      String(format: "%.4f, %.4f", lat, lon),
                                      symbol: "mappin.circle")
                                    .privacySensitive()
                            }
                        }
                        .padding(.vertical, 2)
                        if location.id != locations.last?.id {
                            Divider().opacity(0.35)
                        }
                    }
                }
                Text(L10n.text("Saved in the vehicle's charging backend. Managed from the Controls tab."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        })
    }

    // MARK: - Parking location

    var parkingLocationCard: some View {
        guard let location = state.location, let lat = location.latitude, let lon = location.longitude else {
            return AnyView(EmptyView())
        }

        let latStr = String(format: "%.4f° %@", abs(lat), lat >= 0 ? L10n.text("N") : L10n.text("S"))
        let lonStr = String(format: "%.4f° %@", abs(lon), lon >= 0 ? L10n.text("E") : L10n.text("W"))
        let modelTitle = state.modelName ?? L10n.text("Vehicle")

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "location.fill", title: L10n.text("Parking Location & Navigation"), color: .blue)
                    Spacer()
                    Menu {
                        Button {
                            if let url = MapLinks.appleMapsPin(latitude: lat, longitude: lon,
                                                               label: modelTitle.isEmpty ? L10n.text("Car") : modelTitle) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label(L10n.text("Open in Apple Maps"), systemImage: "map.fill")
                        }
                        Button {
                            if let url = URL(string: "https://www.google.com/maps/search/?api=1&query=\(lat),\(lon)") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label(L10n.text("Open in Google Maps"), systemImage: "globe")
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(lat), \(lon)", forType: .string)
                        } label: {
                            Label(L10n.text("Copy Coordinates"), systemImage: "doc.on.doc")
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
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                VStack(spacing: 6) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 11))
                                .foregroundStyle(HisingenTheme.accent)
                                .frame(width: 14)
                            Text(L10n.text("Address"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(addressText ?? L10n.text(addressResolved ? "Unavailable" : "Resolving…"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .privacySensitive()
                    }
                    .padding(.vertical, 1)
                    KVRow(L10n.text("GPS Coordinates"), "\(latStr), \(lonStr)", symbol: "mappin.circle.fill")
                        .privacySensitive()
                    if let alt = location.altitudeMeters {
                        KVRow(L10n.text("Altitude"), L10n.format("%d m", Int(alt.rounded())), symbol: "mountain.2.fill")
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

    // MARK: - CleanZone air quality

    var airQualityCleanZoneCard: some View {
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
                        KVRow(L10n.text("Air Quality Index"), L10n.format("%d AQI (%@)", aqiVal, aqiLabel), symbol: "aqi.low", valueWarning: aqiVal > 100)
                    } else {
                        KVRow(L10n.text("Air Quality Index"), L10n.text("Unavailable"), symbol: "aqi.low", info: L10n.text("The vehicle did not report an air-quality index."))
                    }

                    if let cabinPM = air.particulateMatter25 {
                        let formattedCabin = cabinPM == 0 ? L10n.text("< 1 µg/m³") : L10n.format("%d µg/m³", cabinPM)
                        KVRow(L10n.text("Cabin PM2.5"), formattedCabin, symbol: "aqi.medium")
                    }
                    if let cabinPM10 = air.particulateMatter10 {
                        let formattedPM10 = cabinPM10 == 0 ? L10n.text("< 1 µg/m³") : L10n.format("%d µg/m³", cabinPM10)
                        KVRow(L10n.text("Cabin PM10"), formattedPM10, symbol: "aqi.high")
                    }
                    if let outdoorPM = air.externalParticulateMatter25 {
                        KVRow(L10n.text("Outdoor PM2.5"), L10n.format("%d µg/m³", outdoorPM), symbol: "sun.haze.fill")
                        if let cabinPM = air.particulateMatter25 {
                            let delta = max(0, outdoorPM - cabinPM)
                            KVRow(L10n.text("Purifier Effect"),
                                  delta >= 1 ? L10n.format("%d µg/m³ PM2.5 removed", delta)
                                             : L10n.text("No measurable reduction"),
                                  symbol: "arrow.down.forward.and.arrow.up.backward",
                                  info: L10n.text("Difference between the outdoor and in-cabin PM2.5 readings at the same sample."))
                        }
                    }
                    if let runtimeLeft = air.runtimeRemainingMinutes, air.cleaningState == .on || air.cleaningState == .pending {
                        KVRow(L10n.text("Purification Time Left"),
                              Format.shortDuration(minutes: runtimeLeft), symbol: "timer")
                    }
                    if let endingAt = air.endingAt, air.cleaningState == .on,
                       endingAt.timeIntervalSinceNow > 0 {
                        KVRow(L10n.text("Cycle Ends"), Format.timeFormatter.string(from: endingAt),
                              symbol: "clock.badge.checkmark")
                    }
                    if let reason = air.startReason, reason != .unspecified,
                       air.cleaningState == .on || air.cleaningState == .pending {
                        KVRow(L10n.text("Started By"), reason.displayName, symbol: "person.wave.2")
                    }
                    if let lastValid = air.lastCycleValid {
                        KVRow(L10n.text("Last Cycle"),
                              lastValid ? L10n.text("Completed normally") : L10n.text("Did not complete"),
                              symbol: lastValid ? "checkmark.seal" : "exclamationmark.triangle",
                              valueWarning: !lastValid)
                    }
                    if let errorKind = air.errorKind, errorKind != .none {
                        KVRow(L10n.text("Purifier Status"), errorKind.displayName,
                              symbol: errorKind == .interrupted ? "pause.circle" : "xmark.octagon",
                              warning: errorKind == .generic)
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
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.text("HEPA filter life"))
                        .accessibilityValue("\(filterLife)%")
                    }
                    if let estimate = HistoryInsights.filterLifeEstimate(from: asyncData.airQualityHistory) {
                        KVRow(L10n.text("Filter Replacement (estimate)"),
                              L10n.format("≈ %d days", Int(estimate.daysRemaining.rounded())),
                              symbol: "calendar.badge.exclamationmark",
                              info: L10n.text("A guesstimate extrapolated from the observed filter-life decline between locally stored readings. Real wear depends on usage and conditions; treat it as a rough guide only."))
                    }

                    airQualityTrendChart
                }
            }
        })
    }

    /// Local trend view over stored `air_quality_history` samples — the vehicle/provider APIs
    /// don't expose any history of their own, so this is entirely reconstructed from readings
    /// Hisingen recorded during normal refreshes.
    @ViewBuilder
    var airQualityTrendChart: some View {
        let history = asyncData.airQualityHistory
            .filter { $0.airQualityIndex != nil }
            .sorted { $0.timestamp < $1.timestamp }
        if history.count >= 2 {
            let values = history.compactMap(\.airQualityIndex)
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("Air quality index history chart"))
                .accessibilityValue(chartAccessibilityValue(points: values))
            }
        }
    }
}
