import AppKit
import SwiftUI

extension InfoTabView {
    var activityHistoryCard: some View {
        let latestEvent = asyncData.recentActivities.max { $0.timestamp < $1.timestamp }
        let latestCommand = asyncData.recentCommands.max { $0.executedAt < $1.executedAt }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "clock.arrow.circlepath", title: L10n.text("Recent Vehicle Activity"),
                           color: HisingenTheme.chartInfo)
                if let latestEvent, latestEvent.timestamp >= (latestCommand?.executedAt ?? .distantPast) {
                    VehicleActivityList(events: [latestEvent])
                } else if let latestCommand {
                    KVRow(L10n.text("Last Remote Command"), "\(latestCommand.command) · \(latestCommand.status)")
                    Text(Format.dateTimeFormatter.string(from: latestCommand.executedAt))
                        .hisType(.caption)
                        .foregroundStyle(HisingenTheme.inkMuted)
                } else {
                    Text(L10n.text("No vehicle changes or commands recorded."))
                        .hisType(.label)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
                if let onNavigateToHistory {
                    NavigationRow(title: L10n.text("Open in Log"), action: onNavigateToHistory)
                }
            }
        }
    }

    var chargeLocationsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "mappin.and.ellipse", title: L10n.text("Saved Charge Locations"),
                           color: HisingenTheme.semanticActive)
                ForEach(savedChargeLocations) { location in
                    let title = preferences.privacyRedactionEnabled || location.alias.isEmpty
                        ? L10n.text("Saved charge location")
                        : location.alias
                    if let onNavigateToChargeLocation {
                        NavigationRow(title: title) { onNavigateToChargeLocation(location.id) }
                    } else {
                        KVRow(title, location.ampLimit > 0 ? Format.amps(location.ampLimit) : L10n.text("Vehicle default"))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Parking location

    var parkingLocationCard: some View {
        if preferences.privacyRedactionEnabled {
            return AnyView(Card {
                Label(L10n.text("Screenshot Privacy Mode"), systemImage: "location.slash")
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
            })
        }
        guard let location = state.location, let lat = location.latitude, let lon = location.longitude else {
            return AnyView(Card {
                HisingenEmptyState(
                    symbol: "location.slash", title: L10n.text("Parking position unavailable."),
                    message: state.isVolvo
                        ? L10n.text("Location requires subscribing to the Location API in developer.volvocars.com and enabling 'Share Location' in vehicle settings.")
                        : L10n.text("No parking location was reported on the last refresh.")
                )
            })
        }

        let latStr = String(format: "%.4f° %@", locale: L10n.displayLocale, abs(lat), lat >= 0 ? L10n.text("N") : L10n.text("S"))
        let lonStr = String(format: "%.4f° %@", locale: L10n.displayLocale, abs(lon), lon >= 0 ? L10n.text("E") : L10n.text("W"))
        let modelTitle = state.identity.modelName ?? L10n.text("Vehicle")

        return AnyView(Card(compact: true) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeaderWithAccessory(
                    heading: CardHeader(symbol: "location", title: L10n.text("Parking Location"), color: HisingenTheme.semanticActive)
                ) {
                    Menu {
                        Button {
                            if let url = MapLinks.appleMapsPin(latitude: lat, longitude: lon,
                                                               label: modelTitle.isEmpty ? L10n.text("Car") : modelTitle) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label(L10n.text("Open in Apple Maps"), systemImage: "map")
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
                        Text(L10n.text("Open in Maps"))
                            .hisType(.body, weight: .semibold)
                            .foregroundStyle(HisingenTheme.ink)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(addressText ?? L10n.text(addressResolved ? "Unavailable" : "Resolving…"))
                        .hisType(.title)
                        .foregroundStyle(addressText == nil ? HisingenTheme.inkMuted : HisingenTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(reduceMotion ? .identity : .opacity)
                        .hisAnimation(Motion.theme, value: addressText)
                    Text(L10n.text("Address"))
                        .hisType(.label)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("Address"))
                .accessibilityValue(addressText ?? L10n.text(addressResolved ? "Unavailable" : "Resolving…"))
                .privacySensitive()

                VStack(spacing: 6) {
                    KVRow(L10n.text("GPS Coordinates"), "\(latStr), \(lonStr)")
                        .privacySensitive()
                    if let timestamp = location.timestamp {
                        KVRow(L10n.text("Observed"), Format.dateTimeFormatter.string(from: timestamp))
                    }
                    if let speed = location.speed, speed > 0 {
                        KVRow(L10n.text("Speed"), Format.speed(kmH: Int(speed.rounded()), unit: preferences.distanceUnit), symbol: "speedometer")
                    }
                    if let alt = location.altitudeMeters {
                        KVRow(L10n.text("Altitude"), L10n.format("%d m", Int(alt.rounded())), symbol: "mountain.2")
                    }
                    if let accuracy = location.accuracyMeters, accuracy > 0 {
                        KVRow(L10n.text("GPS Accuracy"), L10n.format("±%d m", Int(accuracy.rounded())), symbol: "scope")
                    }
                    if let heading = location.heading {
                        let cardinal = headingToCardinal(heading)
                        KVRow(L10n.text("Vehicle Heading"), "\(cardinal) (\(String(format: "%.0f°", locale: L10n.displayLocale, heading)))", symbol: "safari")
                    }
                    if let brake = location.parkingBrakeEngaged {
                        KVRow(L10n.text("Parking Brake"), brake ? L10n.text("Engaged") : L10n.text("Released"), symbol: "parkingsign.circle", valueWarning: !brake)
                    }
                    if let gear = location.gear, !gear.isEmpty {
                        KVRow(L10n.text("Gear Selector"), gear.uppercased(), symbol: "gearshape")
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
            cleaningSymbol = "aqi.medium"
            cleaningColor = .teal
        case .off:
            cleaningText = L10n.text("Off")
            cleaningSymbol = "power"
            cleaningColor = .secondary
        case .pending:
            cleaningText = L10n.text("Pending")
            cleaningSymbol = "clock"
            cleaningColor = HisingenTheme.semanticWarning
        case .unknown:
            cleaningText = L10n.text("Unavailable")
            cleaningSymbol = "questionmark.circle"
            cleaningColor = .secondary
        }

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "wind", title: L10n.text("CleanZone Air Quality & Filter"), color: HisingenTheme.chartPositive)
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
                        KVRow(L10n.text("Outdoor PM2.5"), L10n.format("%d µg/m³", outdoorPM), symbol: "sun.haze")
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
                    if let startedAt = air.startedAt, air.cleaningState == .on {
                        KVRow(L10n.text("Cycle Started"), Format.timeFormatter.string(from: startedAt),
                              symbol: "clock")
                    }
                    if let endingAt = air.endingAt, air.cleaningState == .on,
                       endingAt.timeIntervalSinceNow > 0 {
                        KVRow(L10n.text("Cycle Ends"), Format.timeFormatter.string(from: endingAt),
                              symbol: "clock.badge.checkmark")
                    }
                    if let measuredAt = air.measuredAt {
                        KVRow(L10n.text("Observed"), Format.dateTimeFormatter.string(from: measuredAt), symbol: "clock",
                              info: L10n.text("When the cabin air was last measured. The sensor also samples when the vehicle wakes up, not only during purification."))
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
                    if let completedAt = air.lastCycleCompleted {
                        KVRow(L10n.text("Last Cycle Finished"), Format.dateTimeFormatter.string(from: completedAt),
                              symbol: "clock.arrow.circlepath")
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
                                    .hisType(.label)
                                    .foregroundStyle(HisingenTheme.accent)
                                    .frame(width: 14)
                                Text(L10n.text("HEPA Filter Life"))
                                    .hisType(.label, weight: .medium)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                ProgressView(value: Double(filterLife), total: 100)
                                    .progressViewStyle(.linear)
                                    .frame(width: 60)
                                    .tint(filterLife > 20 ? .teal : HisingenTheme.semanticWarning)
                                    .hisAnimation(Motion.progress, value: filterLife)
                                Text("\(filterLife)%")
                                    .hisType(.label, weight: .bold)
                                    .foregroundStyle(filterLife > 20 ? Color.primary : HisingenTheme.semanticWarning)
                                    .hisTelemetryValue(filterLife, reduceMotion: reduceMotion)
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

                    // Hidden until the backend actually sends one: an unparsed air-quality
                    // wire field stays visible instead of disappearing silently.
                    ForEach((air.unknownWireFields ?? []).sorted { $0.field < $1.field }, id: \.field) { field in
                        KVRow(field.isBinary
                                  ? L10n.format("Field %d (raw)", field.field)
                                  : L10n.format("Field %d", field.field),
                              field.value, symbol: "curlybraces",
                              info: L10n.text("Air-quality wire field the backend sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports."))
                    }
                    // Same disclosure for the Data Portal's JSON: a key this build does not
                    // decode stays visible instead of being dropped at decode.
                    ForEach((air.unknownPortalFields ?? []).sorted { $0.key < $1.key }, id: \.key) { field in
                        KVRow(L10n.format("Field %@ (raw)", field.key), field.value, symbol: "curlybraces",
                              info: L10n.text("Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports."))
                    }

                    if let onNavigateToPlan, preferences.features.contains(.remotePreCleaning) {
                        NavigationRow(
                            title: L10n.text("Open in Plan"),
                            accessibilityName: "\(L10n.text("Open in Plan")), \(L10n.text("Climate"))"
                        ) { onNavigateToPlan(.controlsClimate) }
                    }
                    if let onNavigateToLogSection, !asyncData.airQualityHistory.isEmpty {
                        NavigationRow(title: L10n.text("Open Air Quality History")) {
                            onNavigateToLogSection(.historyAirQuality)
                        }
                    }
                }
            }
        })
    }
}
