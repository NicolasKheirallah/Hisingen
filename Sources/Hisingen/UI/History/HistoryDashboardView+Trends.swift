import Charts
import SwiftUI

// `HistoryDashboardView` – long-horizon trend cards: consumption (electric + combustion),
// odometer, battery health, cabin air quality, cabin temperature, and the automation log.

extension HistoryDashboardView {
    // MARK: - Consumption trend (electric)

    var efficiencyChartCard: some View {
        let points = efficiencyPoints
        let average = HistoryInsights.averageEfficiency(of: points)
        let median = Statistics.median(points.map(\.kwhPer100Km))
        let segmentByID = gapSegmentIndex(of: points, timestamp: \.timestamp)
        let seasonal = HistoryInsights.seasonalEfficiency(from: telemetryRecords)
        let slopePerDay = HistoryInsights.efficiencyTrendSlopePerDay(from: points)
        let smoothedBase: [SmoothedPoint] = points.count >= 8
            ? zip(points, Statistics.movingAverage(points.map(\.kwhPer100Km), windowSize: 5))
                .map { point, value in SmoothedPoint(id: point.id, timestamp: point.timestamp, value: value) }
            : []
        // The moving average carries the same timestamps as the readings it averages, so the raw
        // series' gap segments apply to it unchanged rather than needing a second rule.
        let smoothed = smoothedBase
        let smoothedSegmentByID = gapSegmentIndex(of: smoothedBase, timestamp: \.timestamp)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "gauge.high", title: L10n.text("Consumption Trend"), color: .mint)
                    Spacer()
                    if let average {
                        Text(preferences.energyConsumptionUnit.format(kwhPer100Km: average))
                            .hisType(.caption, weight: .semibold, design: .rounded).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Chart {
                    ForEach(points) { point in
                        LineMark(
                            x: .value(L10n.text("Date"), point.timestamp),
                            y: .value(L10n.text("Consumption"), point.kwhPer100Km),
                            series: .value(L10n.text("Segment"), segmentByID[point.id] ?? 0)
                        )
                        .foregroundStyle(HisingenTheme.chartInfo)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value(L10n.text("Date"), point.timestamp),
                            y: .value(L10n.text("Consumption"), point.kwhPer100Km)
                        )
                        .symbolSize(14)
                        .foregroundStyle(HisingenTheme.chartInfo.opacity(0.85))
                    }
                    // Split by the same gap rule as the raw reading. It used to run as one
                    // unbroken line across every gap, so an average drawn through a fortnight of
                    // missing data looked exactly like an average drawn through a fortnight of
                    // readings, and the app contradicted the gap rule it applies three lines above.
                    ForEach(smoothed) { point in
                        LineMark(
                            x: .value(L10n.text("Date"), point.timestamp),
                            y: .value(L10n.text("Smoothed"), point.value),
                            series: .value(L10n.text("Segment"), smoothedSegmentByID[point.id] ?? 0)
                        )
                        .foregroundStyle(HisingenTheme.chartInfo.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .interpolationMethod(.catmullRom)
                    }
                    if let scrubEfficiency, let hit = HistoryInsights.nearest(to: scrubEfficiency, in: points, timestamp: \.timestamp) {
                        RuleMark(x: .value(L10n.text("Date"), hit.timestamp))
                            .foregroundStyle(Color.primary.opacity(0.25))
                            .annotation(position: .top, spacing: 0,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                Text("\(Format.dateFormatter.string(from: hit.timestamp)) · \(preferences.energyConsumptionUnit.format(kwhPer100Km: hit.kwhPer100Km))")
                                    .historyScrubCallout()
                            }
                    }
                }
                .chartXSelection(value: $scrubEfficiency)
                .frame(height: chartHeight)
                .accessibilityLabel(L10n.text("Energy consumption trend chart"))
                .accessibilityValue(chartAccessibilityValue(points: smoothed.map { $0.value }))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Consumption Trend"),
                    yLabel: "kWh/100km",
                    points: points.map { ($0.timestamp, $0.kwhPer100Km) }
                ))
                .hisAnimation(Motion.progress, value: periodDataKey)
                if !smoothed.isEmpty {
                    HStack(spacing: 10) {
                        legendSwatch(HisingenTheme.chartInfo, L10n.text("Reading"))
                        legendSwatch(HisingenTheme.chartInfo.opacity(0.4), L10n.text("5-point average"), dashed: true)
                        Spacer()
                    }
                }
                if let median, let average, abs(median - average) > 0.5 {
                    Text(L10n.format("Typical drive: %@ (average is pulled by outlier trips)",
                                     preferences.energyConsumptionUnit.format(kwhPer100Km: median)))
                        .hisType(.micro).foregroundStyle(.secondary)
                }
                seasonalRow(seasonal)
                if state.hasFreshReading(.battery), let battery = state.energy.batteryPercentage,
                   let estimate = HistoryInsights.historicalRange(
                    from: telemetryRecords, vin: state.identity.vin,
                    usableCapacityKwh: state.configuredCapacityReference(
                        specification: preferences.vehicleSpecificationOverride(for: state.identity.vin)).kwh,
                    batteryPercentage: battery) {
                    Text(L10n.format("Range from recorded consumption: %@",
                                     Format.distance(km: estimate.typicalKm, unit: preferences.distanceUnit)))
                        .font(.caption.weight(.medium))
                    Text(L10n.format("%@ to %@ across %d observations. Uses current battery charge and configured usable capacity; this is not a route prediction.",
                                     Format.distance(km: estimate.shortestKm, unit: preferences.distanceUnit),
                                     Format.distance(km: estimate.longestKm, unit: preferences.distanceUnit),
                                     estimate.observationCount))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let slopePerDay {
                    let monthlySlope = slopePerDay * 30
                    Text(L10n.format("Trending %@ kWh/100km per month", Format.signedNumber(monthlySlope, decimals: 2)))
                        .hisType(.micro, weight: .medium)
                        .foregroundStyle(monthlySlope > 0.5 ? HisingenTheme.semanticWarning : .secondary)
                }
                Text(L10n.text("Vehicle-reported consumption between charges. Short drives and climate use raise it; motorway cruising lowers it."))
                    .hisType(.micro).foregroundStyle(.tertiary)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
                dataConfidenceNote(for: points.map(\.timestamp))
            }
        }
    }

    @ViewBuilder
    func seasonalRow(_ seasonal: HistoryInsights.SeasonalEfficiency) -> some View {
        if seasonal.coldAverage != nil || seasonal.warmAverage != nil {
            let coldLabel = preferences.temperatureUnit == .celsius ? L10n.text("Cold (<5°C)") : L10n.text("Cold (<41°F)")
            let mildLabel = preferences.temperatureUnit == .celsius ? L10n.text("Mild (5–15°C)") : L10n.text("Mild (41–59°F)")
            let warmLabel = preferences.temperatureUnit == .celsius ? L10n.text("Warm (>15°C)") : L10n.text("Warm (>59°F)")
            HStack(spacing: 12) {
                if let cold = seasonal.coldAverage {
                    curveStat(coldLabel, preferences.energyConsumptionUnit.format(kwhPer100Km: cold))
                }
                if let mild = seasonal.mildAverage {
                    curveStat(mildLabel, preferences.energyConsumptionUnit.format(kwhPer100Km: mild))
                }
                if let warm = seasonal.warmAverage {
                    curveStat(warmLabel, preferences.energyConsumptionUnit.format(kwhPer100Km: warm))
                }
            }
        }
    }

    func legendSwatch(_ color: Color, _ label: String, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 2.5)
                .overlay(dashed ? RoundedRectangle(cornerRadius: 1).stroke(color, style: StrokeStyle(lineWidth: 2.5, dash: [2, 2])) : nil)
            Text(label).hisType(.nano).foregroundStyle(.secondary)
        }
    }

    // MARK: - Consumption trend (combustion / hybrid)

    var combustionConsumptionCard: some View {
        let points = combustionConsumptionPoints
        let segmentByID = gapSegmentIndex(of: points, timestamp: \.timestamp)
        let average = points.isEmpty ? nil : points.reduce(0) { $0 + $1.kwhPer100Km } / Double(points.count)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "fuelpump.fill", title: L10n.text("Fuel Consumption Trend"), color: .orange)
                    Spacer()
                    if let average {
                        Text(Format.fuelEconomy(lPer100Km: average, unit: preferences.fuelEconomyUnit))
                            .hisType(.caption, weight: .semibold, design: .rounded).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Chart(points) { point in
                    LineMark(
                        x: .value(L10n.text("Date"), point.timestamp),
                        y: .value(L10n.text("Consumption"), point.kwhPer100Km),
                        series: .value(L10n.text("Segment"), segmentByID[point.id] ?? 0)
                    )
                    .foregroundStyle(HisingenTheme.chartAttention)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)
                }
                .chartYAxisLabel(L10n.text("L/100km"))
                .frame(height: chartHeight)
                .accessibilityLabel(L10n.text("Fuel consumption trend chart"))
                .accessibilityValue(chartAccessibilityValue(points: points.map { $0.kwhPer100Km }))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Fuel Consumption Trend"),
                    yLabel: "L/100km",
                    points: points.map { ($0.timestamp, $0.kwhPer100Km) }
                ))
                .hisAnimation(Motion.progress, value: periodDataKey)
                Text(L10n.text("Vehicle-reported litres per 100 km between fill-ups. Short, cold trips raise it."))
                    .hisType(.micro).foregroundStyle(.tertiary)
                dataConfidenceNote(for: points.map(\.timestamp))
            }
        }
    }

    var odometerChartCard: some View {
        let covered = HistoryInsights.distanceCovered(from: odometerPoints)
        let segmentByID = gapSegmentIndex(of: odometerPoints, timestamp: \.timestamp)
        let kmPerDay = HistoryInsights.averageKmPerDay(from: allTimeOdometerPoints)
        let monthly = HistoryInsights.monthlyMileage(from: allTimeOdometerPoints)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "road.lanes", title: L10n.text("Odometer History"), color: .indigo)
                    Spacer()
                    if let covered {
                        Text("+\(Format.distance(km: covered, decimals: 0, unit: preferences.distanceUnit))")
                            .hisType(.caption, weight: .semibold, design: .rounded).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Chart {
                    ForEach(odometerPoints) { point in
                        LineMark(
                            x: .value(L10n.text("Date"), point.timestamp),
                            y: .value(L10n.text("Odometer"), preferences.distanceUnit.convert(km: point.odometerKm)),
                            series: .value(L10n.text("Segment"), segmentByID[point.id] ?? 0)
                        )
                        .foregroundStyle(HisingenTheme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                    }
                    if let scrubOdometer, let hit = HistoryInsights.nearest(to: scrubOdometer, in: odometerPoints, timestamp: \.timestamp) {
                        RuleMark(x: .value(L10n.text("Date"), hit.timestamp))
                            .foregroundStyle(Color.primary.opacity(0.25))
                            .annotation(position: .top, spacing: 0,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                Text("\(Format.dateFormatter.string(from: hit.timestamp)) · \(Format.distance(km: hit.odometerKm, decimals: 0, unit: preferences.distanceUnit))")
                                    .historyScrubCallout()
                            }
                    }
                }
                .chartXSelection(value: $scrubOdometer)
                .chartYAxisLabel(preferences.distanceUnit.suffix)
                .frame(height: chartHeight)
                .accessibilityLabel(L10n.text("Odometer history chart"))
                .accessibilityValue(chartAccessibilityValue(points: odometerPoints.map { Double($0.odometerKm) }))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Odometer History"),
                    yLabel: preferences.distanceUnit.suffix,
                    points: odometerPoints.map { ($0.timestamp, preferences.distanceUnit.convert(km: $0.odometerKm)) },
                    valueFormat: { String(format: "%.0f", $0) }
                ))
                .hisAnimation(Motion.progress, value: periodDataKey)
                if monthly.count >= 2 {
                    Chart(monthly) { bucket in
                        BarMark(
                            x: .value(L10n.text("Month"), bucket.month, unit: .month),
                            y: .value(L10n.text("Distance"), preferences.distanceUnit.convert(km: bucket.distanceKm))
                        )
                        .foregroundStyle(HisingenTheme.accent.opacity(0.6))
                        .cornerRadius(2)
                    }
                    .chartYAxisLabel(preferences.distanceUnit.suffix)
                    .frame(height: chartHeight * 0.7)
                    .accessibilityLabel(L10n.text("Monthly mileage chart"))
                    .accessibilityValue(chartAccessibilityValue(points: monthly.map { $0.distanceKm }))
                    .hisAnimation(Motion.progress, value: lifetimeDataKey)
                }
                if let kmPerDay {
                    curveStat(L10n.text("Average Daily Distance"),
                              Format.distance(km: kmPerDay, decimals: 1, unit: preferences.distanceUnit) + "/" + L10n.text("day"))
                }
                Text(L10n.text("Monthly totals and the daily average use all recorded odometer history, independent of the period selector above."))
                    .hisType(.micro).foregroundStyle(.tertiary)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
                dataConfidenceNote(for: allTimeOdometerPoints.map(\.timestamp))
            }
        }
    }

    // MARK: - Battery health

    var batteryHealthCard: some View {
        let records = Array(batteryHealthRecords.reversed())
        let latest = batteryHealthRecords.first
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "heart.text.square", title: L10n.text("Battery Health Trend"), color: .pink)
                    Spacer()
                    if let latest {
                        Text(Format.percent(latest.stateOfHealthPct, decimals: 1))
                            .hisType(.label, weight: .bold, design: .rounded).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if records.count >= 2 {
                    Chart {
                        ForEach(records) { record in
                            LineMark(
                                x: .value(L10n.text("Date"), record.timestamp),
                                y: .value(L10n.text("State of Health"), record.stateOfHealthPct)
                            )
                            .foregroundStyle(HisingenTheme.chartHealth)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.monotone)
                            PointMark(
                                x: .value(L10n.text("Date"), record.timestamp),
                                y: .value(L10n.text("State of Health"), record.stateOfHealthPct)
                            )
                            .symbolSize(16)
                            .foregroundStyle(HisingenTheme.chartHealth.opacity(0.85))
                        }
                        if let scrubSoH, let hit = HistoryInsights.nearest(to: scrubSoH, in: records, timestamp: \.timestamp) {
                            RuleMark(x: .value(L10n.text("Date"), hit.timestamp))
                                .foregroundStyle(Color.primary.opacity(0.25))
                                .annotation(position: .top, spacing: 0,
                                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                    Text("\(Format.dateFormatter.string(from: hit.timestamp)) · \(Format.percent(hit.stateOfHealthPct, decimals: 1))")
                                        .historyScrubCallout()
                                }
                        }
                    }
                    .chartXSelection(value: $scrubSoH)
                    .chartYScale(domain: sohDomain(records))
                    .chartYAxisLabel("%")
                    .frame(height: chartHeight)
                    .accessibilityLabel(L10n.text("Battery health trend chart"))
                    .accessibilityValue(chartAccessibilityValue(points: records.map { $0.stateOfHealthPct }))
                    .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                        title: L10n.text("Battery Health Trend"),
                        yLabel: "%",
                        points: records.map { ($0.timestamp, $0.stateOfHealthPct) }
                    ))
                    .hisAnimation(Motion.progress, value: lifetimeDataKey)
                }
                if let latest {
                    KVRow(L10n.text("Degradation"),
                          Format.percent(latest.degradationPct, decimals: 1), symbol: "arrow.down.right")
                    KVRow(L10n.text("Estimated Usable Capacity"), Format.energyKwh(latest.effectiveUsableKwh), symbol: "battery.100")
                    KVRow(L10n.text("Recorded At Odometer"),
                          Format.distance(km: latest.odometerKm, decimals: 0, unit: preferences.distanceUnit), symbol: "road.lanes")
                    if let slope = HistoryInsights.batteryHealthTrend(from: batteryHealthRecords).stateOfHealthPctPer10kKm,
                       batteryHealthRecords.count >= 3 {
                        KVRow(L10n.text("Trend"), L10n.format("%@%% / 10,000 km", Format.signedNumber(slope, decimals: 2)), symbol: "chart.line.downtrend.xyaxis",
                              info: L10n.text("Slope of a straight-line fit through the recorded milestones. A small sample or a recent measurement-method change can swing this significantly."))
                        if let projected = HistoryInsights.projectedStateOfHealth(from: batteryHealthRecords, atOdometerKm: latest.odometerKm + 10_000) {
                            KVRow(L10n.text("Projected in +10,000 km"),
                                  Format.percent(projected, decimals: 1), symbol: "arrow.turn.right.up",
                                  info: L10n.text("A linear projection from the current trend, not a manufacturer estimate. Real degradation is rarely linear."))
                        }
                    }
                    // Named for what it shows. The label used to name the measurement *method*
                    // while the value was a record count, which read as "Full-charge range
                    // estimate - 4": neither a measurement nor a tally. The method policy is in
                    // the info text, where it belongs.
                    KVRow(L10n.text("Estimates recorded"),
                          Format.count(batteryHealthRecords.count), symbol: "questionmark.circle",
                          info: L10n.text("New SoH values are calculated only from vehicle-reported range at 100% charge divided by the configured WLTP range. Previous methods remain visible only for trend continuity."))
                }
                dataConfidenceNote(for: batteryHealthRecords.map(\.timestamp))
            }
        }
    }

    func sohDomain(_ records: [BatteryHealthRecord]) -> ClosedRange<Double> {
        let values = records.map(\.stateOfHealthPct)
        let minimum = (values.min() ?? 90) - 0.75
        return max(50, minimum)...100
    }

    // MARK: - Cabin air quality

    var airQualityCard: some View {
        let chronological = airQualityRecords.sorted { $0.timestamp < $1.timestamp }
        let aqiPoints = chronological.compactMap { record -> (record: AirQualityRecord, aqi: Double)? in
            record.airQualityIndex.map { (record, $0) }
        }
        let pm25Points = chronological.compactMap { record -> (record: AirQualityRecord, pm25: Double)? in
            record.particulateMatter25.map { (record, $0) }
        }
        let pm10Points = chronological.compactMap { record -> (record: AirQualityRecord, pm10: Double)? in
            record.particulateMatter10.map { (record, $0) }
        }
        let latest = chronological.last
        let filterEstimate = HistoryInsights.filterLifeEstimate(from: airQualityRecords)
        let aqiSegmentByID = Dictionary(uniqueKeysWithValues:
            HistoryInsights.segments(of: aqiPoints, maxGap: HistoryInsights.defaultChartGapThreshold, timestamp: { $0.record.timestamp })
                .enumerated().flatMap { index, run in run.map { ($0.record.id, index) } })
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "wind", title: L10n.text("Cabin Air Quality Trend"), color: .teal)
                    Spacer()
                    if let latestAqi = latest?.airQualityIndex {
                        Text("\(Int(latestAqi)) AQI")
                            .hisType(.caption, weight: .semibold, design: .rounded).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if !aqiPoints.isEmpty {
                    Chart(aqiPoints, id: \.record.id) { item in
                        LineMark(
                            x: .value(L10n.text("Date"), item.record.timestamp),
                            y: .value(L10n.text("Air Quality Index"), item.aqi),
                            series: .value(L10n.text("Segment"), aqiSegmentByID[item.record.id] ?? 0)
                        )
                        .foregroundStyle(HisingenTheme.chartInfo)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                        RuleMark(y: .value(L10n.text("Moderate Threshold"), 50))
                            .foregroundStyle(HisingenTheme.semanticWarning.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            // The adjacent PM chart draws a legend; this line was labelled for
                            // VoiceOver only, so a sighted reader saw a dashed rule with nothing
                            // saying what it marks.
                            .annotation(position: .top, alignment: .leading) {
                                Text(L10n.text("Moderate"))
                                    .hisType(.nano, weight: .medium)
                                    .foregroundStyle(HisingenTheme.semanticWarning)
                            }
                    }
                    .chartYAxisLabel(L10n.text("AQI"))
                    .frame(height: chartHeight)
                    .accessibilityLabel(L10n.text("Air quality index trend chart"))
                    .accessibilityValue(chartAccessibilityValue(points: aqiPoints.map { $0.aqi }))
                    .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                        title: L10n.text("Cabin Air Quality Trend"),
                        yLabel: L10n.text("AQI"),
                        points: aqiPoints.map { ($0.record.timestamp, $0.aqi) }
                    ))
                    .hisAnimation(Motion.progress, value: periodDataKey)
                }
                if pm25Points.count >= 2 || pm10Points.count >= 2 {
                    Chart {
                        ForEach(pm25Points, id: \.record.id) { item in
                            AreaMark(
                                x: .value(L10n.text("Date"), item.record.timestamp),
                                y: .value("PM2.5", item.pm25),
                                series: .value(L10n.text("Series"), "PM2.5")
                            )
                            .foregroundStyle(.linearGradient(colors: [HisingenTheme.chartInfo.opacity(0.25), HisingenTheme.chartInfo.opacity(0.02)],
                                                             startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        }
                        ForEach(pm10Points, id: \.record.id) { item in
                            LineMark(
                                x: .value(L10n.text("Date"), item.record.timestamp),
                                y: .value("PM10", item.pm10),
                                series: .value(L10n.text("Series"), "PM10")
                            )
                            .foregroundStyle(HisingenTheme.chartAttention)
                            .lineStyle(chartSeriesStroke(
                                index: 1,
                                differentiateWithoutColor: differentiateWithoutColor,
                                width: 1.2
                            ))
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartYAxisLabel("µg/m³")
                    .frame(height: chartHeight * 0.7)
                    .accessibilityLabel(L10n.text("Cabin particulate matter trend chart"))
                    .accessibilityValue(chartAccessibilityValue(points: pm10Points.map { $0.pm10 }))
                    .hisAnimation(Motion.progress, value: periodDataKey)
                    if !pm10Points.isEmpty {
                        HStack(spacing: 10) {
                            legendSwatch(HisingenTheme.chartInfo, "PM2.5")
                            legendSwatch(
                                HisingenTheme.chartAttention,
                                "PM10",
                                dashed: chartSeriesIsDashed(
                                    index: 1,
                                    differentiateWithoutColor: differentiateWithoutColor
                                )
                            )
                            Spacer()
                        }
                    }
                }
                if let filter = latest?.filterRemainingPercent {
                    KVRow(L10n.text("HEPA Filter Life"), "\(Int(filter))%", symbol: "allergens", valueWarning: filter <= 20)
                }
                if let filterEstimate {
                    KVRow(L10n.text("Filter Replacement (estimate)"),
                          L10n.format("≈ %d days", Int(filterEstimate.daysRemaining.rounded())),
                          symbol: "calendar.badge.exclamationmark",
                          info: L10n.text("Extrapolated from the observed filter-life decline between locally stored readings. Real wear depends on usage and conditions; treat it as a rough guide only."))
                }
                Text(L10n.text("Recorded from vehicle-reported CleanZone readings during normal refreshes. The provider keeps no history of its own, so coverage depends on how often Hisingen was running."))
                    .hisType(.micro).foregroundStyle(.tertiary)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
                dataConfidenceNote(for: chronological.map(\.timestamp))
            }
        }
    }

    // MARK: - Automation

    var automationHistoryCard: some View {
        let stats = commandStatistics
        let durations = commands.compactMap(\.durationMs)
        let averageLatency = durations.isEmpty ? nil : durations.reduce(0, +) / durations.count
        let breakdown = Dictionary(grouping: commands, by: \.command)
            .map { (command: $0.key, total: $0.value.count, failed: $0.value.filter { $0.status == "failed" }.count) }
            .sorted { $0.total > $1.total }
        let failures = commands.filter { $0.status == "failed" && ($0.errorMessage?.isEmpty == false) }.prefix(3)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "command", title: L10n.text("Automation & Commands"), color: .orange)
                    Spacer()
                    if let rate = stats.successRatePct {
                        Text(Format.percent(rate))
                            .hisType(.caption, weight: .semibold, design: .rounded)
                            .monospacedDigit()
                            .foregroundStyle(rate >= 90 ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning)
                    }
                }
                HStack(spacing: 12) {
                    curveStat(L10n.text("Commands"), Format.count(stats.totalCount))
                    if let mostUsed = stats.mostUsedCommand {
                        curveStat(L10n.text("Most Used"), mostUsed.replacingOccurrences(of: "-", with: " ").capitalized)
                    }
                    if let averageLatency {
                        curveStat(L10n.text("Avg Latency"), L10n.format("%d ms", averageLatency))
                    }
                }
                if breakdown.count > 1 {
                    VStack(spacing: 3) {
                        ForEach(breakdown.prefix(6), id: \.command) { row in
                            HStack(spacing: 6) {
                                Text(row.command.replacingOccurrences(of: "-", with: " ").capitalized)
                                    .hisType(.micro)
                                Spacer()
                                if row.failed > 0 {
                                    Text(L10n.format("%d failed", row.failed))
                                        .hisType(.nano).foregroundStyle(HisingenTheme.semanticWarning)
                                }
                                Text(Format.count(row.total)).hisType(.micro, weight: .semibold).monospacedDigit()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                PaginatedSection(items: commands, pageSize: 12, resetKeys: [periodLoadKey],
                                 emptyMessage: L10n.text("No automations ran in this period.")) { visibleCommands, footer in
                    ForEach(visibleCommands) { record in
                        HStack {
                            Image(systemName: record.status == "failed" ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(record.status == "failed" ? HisingenTheme.semanticCritical : HisingenTheme.semanticGood)
                            Text(record.command.replacingOccurrences(of: "-", with: " ").capitalized)
                                .hisType(.caption, weight: .medium)
                            if let ms = record.durationMs {
                                Text(L10n.format("%d ms", ms)).hisType(.nano).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(record.executedAt, style: .relative).hisType(.micro).foregroundStyle(.secondary)
                        }
                        .help(record.errorMessage ?? record.status.capitalized)
                    }
                    footer
                }
                if !failures.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("Recent failures")).hisType(.nano, weight: .semibold).foregroundStyle(.secondary)
                        ForEach(Array(failures), id: \.id) { record in
                            Text("• " + (record.errorMessage ?? ""))
                                .hisType(.nano).foregroundStyle(.tertiary).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    /// Cabin temperature trend from digital-twin climate readings. Hidden entirely on
    /// vehicles that never report interior temperature.
    var cabinClimateCard: AnyView {
        let chronological = cabinClimateRecords.sorted { $0.timestamp < $1.timestamp }
        let plotted = chronological.filter { $0.interiorCelsius != nil }
        guard let latest = plotted.last?.interiorCelsius else { return AnyView(EmptyView()) }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "thermometer.medium", title: L10n.text("Cabin Temperature Trend"), color: .orange)
                    Spacer()
                    Text(Format.temperature(celsius: latest, unit: preferences.temperatureUnit))
                        .hisType(.caption, weight: .semibold, design: .rounded).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Chart(plotted) { record in
                    LineMark(
                        x: .value(L10n.text("Date"), record.timestamp),
                        y: .value(L10n.text("Interior"), preferences.temperatureUnit.convert(celsius: record.interiorCelsius ?? 0))
                    )
                    .foregroundStyle(HisingenTheme.chartAttention)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)
                    if let requested = record.requestedCelsius {
                        LineMark(
                            x: .value(L10n.text("Date"), record.timestamp),
                            y: .value(L10n.text("Setpoint"), preferences.temperatureUnit.convert(celsius: requested))
                        )
                        .foregroundStyle(HisingenTheme.accent.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .chartYAxisLabel(preferences.temperatureUnit.suffix)
                .frame(height: chartHeight * 0.9)
                .accessibilityLabel(L10n.text("Cabin temperature trend chart"))
                .accessibilityValue(chartAccessibilityValue(
                    points: plotted.compactMap { $0.interiorCelsius }
                        .map { preferences.temperatureUnit.convert(celsius: $0) }))
                .hisAnimation(Motion.progress, value: lifetimeDataKey)
                Text(L10n.text("Recorded while the vehicle reported climate status. Setpoints appear dashed; gaps mean the car was asleep or not reporting."))
                    .hisType(.micro).foregroundStyle(.tertiary)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
            }
        })
    }
}
