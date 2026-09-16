import AppKit
import Charts
import SwiftUI

// `HistoryDashboardView` – trip cards: the hour-of-day histogram, distance over time, and
// the detected-trip list with expandable per-trip detail.

extension HistoryDashboardView {
    // MARK: - Driving patterns

    var drivingPatternsCard: AnyView {
        let hours = tripPresentation.hours
        let split = tripPresentation.weekdayWeekend
        guard aggregateTrips.count >= 4 else {
            return AnyView(Card {
                HisingenEmptyState(
                    symbol: "clock.arrow.circlepath",
                    title: L10n.text("Driving patterns need more trips"),
                    message: L10n.text("This section appears after four recorded trips in the selected period.")
                )
            })
        }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "clock.arrow.circlepath", title: L10n.text("Driving Patterns"), color: HisingenTheme.semanticActive)
                Chart(hours) { bucket in
                    BarMark(
                        x: .value(L10n.text("Hour"), bucket.hour),
                        y: .value(L10n.text("Trips"), bucket.tripCount)
                    )
                    .foregroundStyle(HisingenTheme.accent.gradient)
                    .cornerRadius(1.5)
                }
                .chartXScale(domain: 0...23)
                .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) }
                .chartYAxisLabel(L10n.text("Trips"))
                .frame(height: chartHeight * 0.7)
                .accessibilityLabel(L10n.text("Departures by hour of day chart"))
                .accessibilityValue(chartAccessibilityValue(points: hours.map { Double($0.tripCount) }))
                .hisAnimation(Motion.progress, value: periodDataKey)
                HStack(spacing: 12) {
                    curveStat(L10n.text("Weekday / day"),
                              Format.distance(km: split.weekdayKmPerDay, decimals: 1, unit: preferences.distanceUnit))
                    curveStat(L10n.text("Weekend / day"),
                              Format.distance(km: split.weekendKmPerDay, decimals: 1, unit: preferences.distanceUnit))
                    if let busiest = hours.max(by: { $0.tripCount < $1.tripCount }), busiest.tripCount > 0 {
                        curveStat(L10n.text("Busiest hour"), String(format: "%02d:00", busiest.hour))
                    }
                }
                dataConfidenceNote(for: aggregateTrips.map(\.startedAt))
            }
        })
    }

    // MARK: - Trips

    var mileageReports: [MonthlyMileageReport] {
        presentation.mileageReports
    }

    var selectedMileageReport: MonthlyMileageReport? {
        guard !mileageReports.isEmpty else { return nil }
        return mileageReportMonthStart
            .flatMap { selected in mileageReports.first { $0.monthStart == selected } }
            ?? mileageReports.first
    }

    var monthlyMileageReportCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "calendar.badge.checkmark", title: L10n.text("Monthly Mileage Report"), color: .indigo)
                    Spacer()
                    Picker(L10n.text("Month"), selection: Binding(
                        get: { selectedMileageReport?.monthStart },
                        set: { mileageReportMonthStart = $0 }
                    )) {
                        ForEach(mileageReports) { report in
                            Text(report.monthStart.formatted(.dateTime.month(.wide).year()))
                                .tag(Optional(report.monthStart))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let report = selectedMileageReport {
                    HStack(spacing: 8) {
                        mileageStat(L10n.text("Business"), trips: report.businessTrips,
                                    distance: report.businessKm, color: HisingenTheme.semanticActive)
                        mileageStat(L10n.text("Private"), trips: report.privateTrips,
                                    distance: report.privateKm, color: HisingenTheme.semanticGood)
                        mileageStat(L10n.text("Unclassified"), trips: report.unclassifiedTrips,
                                    distance: report.unclassifiedKm, color: .secondary)
                    }
                    HStack {
                        Text(L10n.format("%d trips · %@ total", report.totalTrips,
                                         Format.distance(km: report.totalKm, decimals: 1, unit: preferences.distanceUnit)))
                            .hisType(.micro)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            if let report = selectedMileageReport {
                                Button(L10n.text("Export Selected Month")) {
                                    exportCSV(
                                        MonthlyMileageReport.csv(reports: [report], vin: state.identity.vin),
                                        name: "mileage-\(report.monthStart.formatted(.dateTime.year().month(.twoDigits)))"
                                    )
                                }
                            }
                            Button(L10n.text("Export All Months")) {
                                exportCSV(
                                    MonthlyMileageReport.csv(reports: mileageReports, vin: state.identity.vin),
                                    name: "monthly-mileage"
                                )
                            }
                        } label: {
                            Label(L10n.text("Export report"), systemImage: "square.and.arrow.up")
                                .hisType(.micro)
                        }
                        .menuStyle(.borderlessButton)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    func mileageStat(_ title: String, trips: Int, distance: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Format.distance(km: distance, decimals: 1, unit: preferences.distanceUnit))
                .hisType(.label, weight: .bold, design: .rounded)
                .monospacedDigit()
                .foregroundStyle(color)
            Text(L10n.format("%@ · %d trips", title, trips))
                .hisType(.nano)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    }

    var distanceChartCard: some View {
        let longest = HistoryInsights.longestTrip(from: trips)
        let correlation = HistoryInsights.temperatureConsumptionCorrelation(from: trips)
        let weekly = HistoryInsights.weeklyDistance(from: trips)
        let daily = HistoryInsights.dailyDistance(from: trips)
        let bestDay = daily.max { $0.distanceKm < $1.distanceKm }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "chart.bar.fill", title: L10n.text("Distance Over Time"), color: HisingenTheme.semanticActive)
                Chart {
                    ForEach(trips) { trip in
                        BarMark(
                            x: .value(L10n.text("Date"), trip.endedAt, unit: .day),
                            y: .value(L10n.text("Distance"), preferences.distanceUnit.convert(km: trip.distanceKm))
                        )
                        .foregroundStyle(HisingenTheme.accent.gradient)
                        .cornerRadius(2)
                    }
                    if let scrubDistance, let hit = HistoryInsights.nearest(to: scrubDistance, in: daily, timestamp: \.day) {
                        RuleMark(x: .value(L10n.text("Date"), hit.day))
                            .foregroundStyle(Color.primary.opacity(0.25))
                            .annotation(position: .top, spacing: 0,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                Text("\(Format.dateFormatter.string(from: hit.day)) · \(Format.distance(km: hit.distanceKm, decimals: 1, unit: preferences.distanceUnit))")
                                    .historyScrubCallout()
                            }
                    }
                }
                .chartXSelection(value: $scrubDistance)
                .chartYAxisLabel(preferences.distanceUnit.suffix)
                .frame(height: chartHeight)
                .accessibilityLabel(L10n.text("Trip distance history chart"))
                .accessibilityValue(chartAccessibilityValue(points: trips.map { $0.distanceKm }))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Distance Over Time"),
                    yLabel: preferences.distanceUnit.suffix,
                    points: daily.map { ($0.day, preferences.distanceUnit.convert(km: $0.distanceKm)) }
                ))
                .hisAnimation(Motion.progress, value: periodDataKey)
                if weekly.count >= 3 {
                    Chart(weekly) { bucket in
                        BarMark(
                            x: .value(L10n.text("Week"), bucket.week, unit: .weekOfYear),
                            y: .value(L10n.text("Distance"), preferences.distanceUnit.convert(km: bucket.distanceKm))
                        )
                        .foregroundStyle(HisingenTheme.accent.opacity(0.55).gradient)
                        .cornerRadius(2)
                    }
                    .chartYAxisLabel(preferences.distanceUnit.suffix)
                    .frame(height: chartHeight * 0.62)
                    .accessibilityLabel(L10n.text("Weekly distance chart"))
                    .accessibilityValue(chartAccessibilityValue(points: weekly.map { $0.distanceKm }))
                    .hisAnimation(Motion.progress, value: periodDataKey)
                }
                if let longest {
                    HStack(spacing: 12) {
                        curveStat(L10n.text("Longest Trip"), Format.distance(km: longest.distanceKm, decimals: 1, unit: preferences.distanceUnit))
                        if let speed = HistoryInsights.averageSpeedKmh(longest) {
                            curveStat(L10n.text("Longest Trip Avg Speed"), Format.speed(kmH: Int(speed.rounded()), unit: preferences.distanceUnit))
                        }
                        if let bestDay {
                            curveStat(L10n.text("Best Day"), Format.distance(km: bestDay.distanceKm, decimals: 1, unit: preferences.distanceUnit))
                        }
                    }
                }
                if let slope = HistoryInsights.temperatureConsumptionSlope(from: trips) {
                    Text(L10n.format("Cold raises consumption by about %@ per 10 °C, across %d trips.",
                                     Format.percent(slope.percentPer10DegreesColder, decimals: 0),
                                     slope.observationCount))
                        .hisType(.micro).foregroundStyle(.tertiary)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                } else if let correlation, correlation < -0.2 {
                    Text(L10n.text("Colder trips consume more: consumption rises as ambient temperature drops."))
                        .hisType(.micro).foregroundStyle(.tertiary)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                }
                dataConfidenceNote(for: aggregateTrips.map(\.endedAt))
            }
        }
    }

    var tripListCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: L10n.text("Detected Trips"), color: .teal)
                    Spacer()
                    Menu {
                        Picker(L10n.text("Sort"), selection: $tripSort) {
                            ForEach(TripSort.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
                        }
                    } label: {
                        Label(L10n.text(tripSort.rawValue), systemImage: "arrow.up.arrow.down")
                            .hisType(.micro, weight: .medium)
                    }
                    .menuStyle(.borderlessButton)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
                }
                if snapshot.trips.count > 8 {
                    searchField(L10n.text("Search trips by date"), text: $tripSearchText,
                                count: trips.count, total: snapshot.trips.count)
                }
                PaginatedSection(items: trips, pageSize: HistoryPagination.tripsPerPage,
                                 resetKeys: [tripFilterText, periodLoadKey],
                                 newerHelp: L10n.text("Show newer trips"),
                                 olderHelp: L10n.text("Show older trips")) { visible, footer in
                    ForEach(visible) { trip in
                        tripRow(trip)
                        if trip.id != visible.last?.id { Divider().opacity(HisingenTheme.dividerOpacity) }
                    }
                    footer
                }
                .hisAnimation(Motion.cardChange, value: tripListKey)
                hiddenTripsSection
                Text(L10n.text("Trips are inferred from consecutive odometer or trip-meter changes. They are not a provider trip log and may combine journeys when telemetry is sparse."))
                    .hisType(.micro).foregroundStyle(.tertiary)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Hidden trips stay in the local ledger – hiding only filters them from the detected
    /// list, so every hide stays reversible here.
    var hiddenTrips: [TripHistoryEntry] {
        let hidden = preferences.hiddenTripIDs(for: state.identity.vin).subtracting(restoredTripIDs)
        return hiddenTripRows.filter { hidden.contains($0.id) }
    }

    /// Identity of the filtered + sorted trip list: a sort switch or filter edit reorders
    /// rows, so the list animates the shuffle instead of snapping. Count + endpoints keep
    /// the key cheap on capped (≤3 000 row) lists.
    var tripListKey: String {
        "\(tripSort.rawValue)_\(trips.count)_\(trips.first?.id ?? "")_\(trips.last?.id ?? "")"
    }

    /// Identity of the hidden-trip rows: a restore removes one, so the section animates
    /// the row removal.
    var hiddenTripsKey: String {
        let trips = hiddenTrips
        return "\(trips.count)_\(trips.first?.id ?? "")_\(trips.last?.id ?? "")"
    }

    @ViewBuilder
    var hiddenTripsSection: some View {
        let trips = hiddenTrips
        if !trips.isEmpty {
            DisclosureGroup(isExpanded: $showHiddenTrips) {
                ForEach(trips) { trip in
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                            .hisType(.nano, weight: .semibold)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text(Format.dateTimeFormatter.string(from: trip.endedAt))
                            .hisType(.caption)
                        Spacer()
                        Text(Format.distance(km: trip.distanceKm, decimals: 1, unit: preferences.distanceUnit))
                            .hisType(.caption, weight: .semibold, design: .rounded)
                            .monospacedDigit()
                        Button {
                            preferences.setTripHidden(false, id: trip.id, for: state.identity.vin)
                            restoredTripIDs.insert(trip.id)
                            expandedTripIDs.remove(trip.id)
                        } label: {
                            Label(L10n.text("Restore"), systemImage: "arrow.uturn.backward")
                                .hisType(.micro)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel(L10n.text("Restore this hidden trip to the detected list."))
                        .help(L10n.text("Restore this hidden trip to the detected list."))
                    }
                    .padding(.vertical, 2)
                }
            } label: {
                Label(L10n.format("Hidden trips (%d)", trips.count),
                      systemImage: "eye.slash")
                    .hisType(.micro, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .disclosureGroupStyle(WholeRowDisclosureStyle())
            .hisAnimation(Motion.cardChange, value: hiddenTripsKey)
            .accessibilityHint(L10n.text("Trips you hid from the detected list. Restoring puts them back."))
        }
    }

    @ViewBuilder
    func tripRow(_ trip: TripHistoryEntry) -> some View {
        let expanded = expandedTripIDs.contains(trip.id)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if expanded { expandedTripIDs.remove(trip.id) } else { expandedTripIDs.insert(trip.id) }
            } label: {
                HStack(spacing: 8) {
                    // Rotating glyph (WholeRowDisclosureStyle treatment) instead of a
                    // hard swap between chevron.right / chevron.down.
                    Image(systemName: "chevron.right")
                        .hisType(.nano, weight: .semibold).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .hisAnimation(Motion.interaction, value: expanded)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.dateTimeFormatter.string(from: trip.endedAt))
                            .hisType(.caption, weight: .semibold)
                        HStack(spacing: 5) {
                            Text(Format.shortDuration(minutes: max(1, Int(trip.duration / 60))))
                            if let speed = HistoryInsights.averageSpeedKmh(trip) {
                                Text("· " + Format.speed(kmH: Int(speed.rounded()), unit: preferences.distanceUnit))
                            }
                            if let temperature = trip.ambientTemperatureCelsius {
                                Text("· " + Format.temperature(celsius: temperature, unit: preferences.temperatureUnit))
                            }
                            if let consumption = trip.averageConsumption, state.powertrain.hasElectricRange,
                               HistoryInsights.efficiencyBounds.contains(consumption) {
                                Text("· " + Format.energyConsumption(kwhPer100Km: consumption, unit: preferences.energyConsumptionUnit))
                            }
                        }
                        .hisType(.micro).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.distance(km: trip.distanceKm, decimals: 1, unit: preferences.distanceUnit))
                        .hisType(.label, weight: .bold, design: .rounded)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tripRowAccessibilityLabel(trip))
            .accessibilityHint(expanded ? L10n.text("Collapse trip details") : L10n.text("Expand trip details"))

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    KVRow(L10n.text("Started"), Format.dateTimeFormatter.string(from: trip.startedAt), symbol: "flag")
                    KVRow(L10n.text("Ended"), Format.dateTimeFormatter.string(from: trip.endedAt), symbol: "flag.checkered")
                    HStack(spacing: 8) {
                        tripPurposeButton(.privateTrip, trip: trip)
                        tripPurposeButton(.business, trip: trip)
                        if snapshot.tripPurposes[trip.id] != nil {
                            Button {
                                setPurpose(nil, for: trip)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.pressable)
                            .help(L10n.text("Clear trip classification"))
                            .accessibilityLabel(L10n.text("Clear trip classification"))
                        }
                        if let lat = trip.startLatitude, let lon = trip.startLongitude {
                            Button { openMap(latitude: lat, longitude: lon) } label: {
                                Label(L10n.text("Start"), systemImage: "mappin")
                                    .hisType(.micro)
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel(L10n.text("Open trip start in Apple Maps"))
                        }
                        if let lat = trip.endLatitude, let lon = trip.endLongitude {
                            Button { openMap(latitude: lat, longitude: lon) } label: {
                                Label(L10n.text("End"), systemImage: "mappin.circle.fill")
                                    .hisType(.micro)
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel(L10n.text("Open trip endpoint in Apple Maps"))
                        }
                        if let sLat = trip.startLatitude, let sLon = trip.startLongitude,
                           let eLat = trip.endLatitude, let eLon = trip.endLongitude {
                            Button { openRoute(fromLat: sLat, fromLon: sLon, toLat: eLat, toLon: eLon) } label: {
                                Label(L10n.text("Route"), systemImage: "arrow.triangle.turn.up.right.diamond")
                                    .hisType(.micro)
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel(L10n.text("Open the trip route in Apple Maps"))
                        }
                        Spacer()
                        Button(role: .destructive) {
                            preferences.setTripHidden(true, id: trip.id, for: state.identity.vin)
                            expandedTripIDs.remove(trip.id)
                        } label: {
                            Label(L10n.text("Hide"), systemImage: "eye.slash").hisType(.micro)
                        }
                        .buttonStyle(.pressable)
                        .help(L10n.text("Hide this trip if segmentation combined or invented it"))
                    }
                }
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 1)
        .hisAnimation(Motion.layout, value: expanded)
    }

    func tripPurposeButton(_ purpose: TripPurpose, trip: TripHistoryEntry) -> some View {
        let selected = snapshot.tripPurposes[trip.id] == purpose
        return Button {
            setPurpose(purpose, for: trip)
        } label: {
            Label(purpose.displayName,
                  systemImage: purpose == .business ? "briefcase.fill" : "person.fill")
                .hisType(.micro, weight: selected ? .semibold : .regular)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(selected ? (purpose == .business ? HisingenTheme.semanticActive : HisingenTheme.semanticGood) : .gray)
        .hisAnimation(Motion.selection, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    func setPurpose(_ purpose: TripPurpose?, for trip: TripHistoryEntry) {
        database.setTripPurpose(purpose, tripID: trip.id, vin: trip.vin)
        if let purpose { snapshot.tripPurposes[trip.id] = purpose }
        else { snapshot.tripPurposes.removeValue(forKey: trip.id) }
    }

    func tripRowAccessibilityLabel(_ trip: TripHistoryEntry) -> String {
        var parts = [
            Format.dateTimeFormatter.string(from: trip.endedAt),
            Format.distance(km: trip.distanceKm, decimals: 1, unit: preferences.distanceUnit),
            Format.shortDuration(minutes: max(1, Int(trip.duration / 60)))
        ]
        if let speed = HistoryInsights.averageSpeedKmh(trip) {
            parts.append(Format.speed(kmH: Int(speed.rounded()), unit: preferences.distanceUnit))
        }
        return parts.joined(separator: ", ")
    }

    func openMap(latitude: Double, longitude: Double) {
        guard let url = MapLinks.appleMapsPin(latitude: latitude, longitude: longitude) else { return }
        NSWorkspace.shared.open(url)
    }

    func openRoute(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double) {
        guard let url = MapLinks.appleMapsDirections(fromLatitude: fromLat, fromLongitude: fromLon,
                                                     toLatitude: toLat, toLongitude: toLon) else { return }
        NSWorkspace.shared.open(url)
    }
}
