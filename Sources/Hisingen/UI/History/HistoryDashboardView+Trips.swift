import AppKit
import Charts
import SwiftUI

// `HistoryDashboardView` — trip cards: the hour-of-day histogram, distance over time, and
// the detected-trip list with expandable per-trip detail.

extension HistoryDashboardView {
    // MARK: - Driving patterns

    var drivingPatternsCard: AnyView {
        let hours = HistoryInsights.tripsByHourOfDay(from: trips)
        let split = HistoryInsights.weekdayWeekendDistance(from: trips)
        guard trips.count >= 4 else { return AnyView(EmptyView()) }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "clock.arrow.circlepath", title: L10n.text("Driving Patterns"), color: .blue)
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
                HStack(spacing: 12) {
                    curveStat(L10n.text("Weekday / day"),
                              Format.distance(km: split.weekdayKmPerDay, decimals: 1, unit: preferences.distanceUnit))
                    curveStat(L10n.text("Weekend / day"),
                              Format.distance(km: split.weekendKmPerDay, decimals: 1, unit: preferences.distanceUnit))
                    if let busiest = hours.max(by: { $0.tripCount < $1.tripCount }), busiest.tripCount > 0 {
                        curveStat(L10n.text("Busiest hour"), String(format: "%02d:00", busiest.hour))
                    }
                }
                dataConfidenceNote(for: trips.map(\.startedAt))
            }
        })
    }

    // MARK: - Trips

    var distanceChartCard: some View {
        let longest = HistoryInsights.longestTrip(from: trips)
        let correlation = HistoryInsights.temperatureConsumptionCorrelation(from: trips)
        let weekly = HistoryInsights.weeklyDistance(from: trips)
        let daily = HistoryInsights.dailyDistance(from: trips)
        let bestDay = daily.max { $0.distanceKm < $1.distanceKm }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "chart.bar.fill", title: L10n.text("Distance Over Time"), color: .blue)
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
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Distance Over Time"),
                    yLabel: preferences.distanceUnit.suffix,
                    points: daily.map { ($0.day, preferences.distanceUnit.convert(km: $0.distanceKm)) }
                ))
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
                if let correlation, correlation < -0.2 {
                    Text(L10n.text("Colder trips consume more: consumption rises as ambient temperature drops."))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                dataConfidenceNote(for: trips.map(\.endedAt))
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
                            .font(.system(size: 9, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                if snapshot.trips.count > 8 {
                    searchField(L10n.text("Search trips by date"), text: $tripSearchText,
                                count: trips.count, total: snapshot.trips.count)
                }
                ForEach(visibleTrips) { trip in
                    tripRow(trip)
                    if trip.id != visibleTrips.last?.id { Divider().opacity(0.25) }
                }
                if tripPageCount > 1 {
                    HStack(spacing: 8) {
                        Button { tripPage = max(0, tripPage - 1) } label: {
                            Label(L10n.text("Newer"), systemImage: "chevron.left").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless).disabled(tripPage == 0)
                        .help(L10n.text("Show newer trips"))
                        Spacer()
                        Text(L10n.format("Page %d of %d", tripPage + 1, tripPageCount))
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button { tripPage = min(tripPageCount - 1, tripPage + 1) } label: {
                            Label(L10n.text("Older"), systemImage: "chevron.right").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless).disabled(tripPage >= tripPageCount - 1)
                        .help(L10n.text("Show older trips"))
                    }
                    .padding(.top, 2)
                }
                Text(L10n.text("Trips are inferred from consecutive odometer or trip-meter changes. They are not a provider trip log and may combine journeys when telemetry is sparse."))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.dateTimeFormatter.string(from: trip.endedAt))
                            .font(.system(size: 10.5, weight: .semibold))
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
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.distance(km: trip.distanceKm, decimals: 1, unit: preferences.distanceUnit))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tripRowAccessibilityLabel(trip))
            .accessibilityHint(expanded ? L10n.text("Collapse trip details") : L10n.text("Expand trip details"))

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    KVRow(L10n.text("Started"), Format.dateTimeFormatter.string(from: trip.startedAt), symbol: "flag")
                    KVRow(L10n.text("Ended"), Format.dateTimeFormatter.string(from: trip.endedAt), symbol: "flag.checkered")
                    HStack(spacing: 8) {
                        if let lat = trip.startLatitude, let lon = trip.startLongitude {
                            Button { openMap(latitude: lat, longitude: lon) } label: {
                                Label(L10n.text("Start"), systemImage: "mappin")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.text("Open trip start in Apple Maps"))
                        }
                        if let lat = trip.endLatitude, let lon = trip.endLongitude {
                            Button { openMap(latitude: lat, longitude: lon) } label: {
                                Label(L10n.text("End"), systemImage: "mappin.circle.fill")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.text("Open trip endpoint in Apple Maps"))
                        }
                        if let sLat = trip.startLatitude, let sLon = trip.startLongitude,
                           let eLat = trip.endLatitude, let eLon = trip.endLongitude {
                            Button { openRoute(fromLat: sLat, fromLon: sLon, toLat: eLat, toLon: eLon) } label: {
                                Label(L10n.text("Route"), systemImage: "arrow.triangle.turn.up.right.diamond")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.text("Open the trip route in Apple Maps"))
                        }
                        Spacer()
                        Button(role: .destructive) {
                            preferences.setTripHidden(true, id: trip.id, for: state.vin)
                            expandedTripIDs.remove(trip.id)
                        } label: {
                            Label(L10n.text("Hide"), systemImage: "eye.slash").font(.system(size: 9))
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.text("Hide this trip if segmentation combined or invented it"))
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 1)
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
