import Charts
import SwiftUI

// `HistoryDashboardView` — long-horizon trend cards: consumption (electric + combustion),
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
        let smoothed: [SmoothedPoint] = points.count >= 8
            ? zip(points, Statistics.movingAverage(points.map(\.kwhPer100Km), windowSize: 5))
                .map { point, value in SmoothedPoint(id: point.id, timestamp: point.timestamp, value: value) }
            : []
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "gauge.high", title: L10n.text("Consumption Trend"), color: .mint)
                    Spacer()
                    if let average {
                        Text(preferences.energyConsumptionUnit.format(kwhPer100Km: average))
                            .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
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
                    // No `series:` — the trailing average is one unbroken line, unlike the raw
                    // reading which is split into gap segments above.
                    ForEach(smoothed) { point in
                        LineMark(
                            x: .value(L10n.text("Date"), point.timestamp),
                            y: .value(L10n.text("Smoothed"), point.value)
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
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Consumption Trend"),
                    yLabel: "kWh/100km",
                    points: points.map { ($0.timestamp, $0.kwhPer100Km) }
                ))
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
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                seasonalRow(seasonal)
                if let slopePerDay {
                    let monthlySlope = slopePerDay * 30
                    Text(L10n.format("Trending %@ kWh/100km per month", Format.signedNumber(monthlySlope, decimals: 2)))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(monthlySlope > 0.5 ? HisingenTheme.semanticWarning : .secondary)
                }
                Text(L10n.text("Vehicle-reported consumption between charges. Short drives and climate use raise it; motorway cruising lowers it."))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
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
            Text(label).font(.system(size: 8.5)).foregroundStyle(.secondary)
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
                            .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
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
                .chartYAxisLabel("L/100km")
                .frame(height: chartHeight)
                .accessibilityLabel(L10n.text("Fuel consumption trend chart"))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Fuel Consumption Trend"),
                    yLabel: "L/100km",
                    points: points.map { ($0.timestamp, $0.kwhPer100Km) }
                ))
                Text(L10n.text("Vehicle-reported litres per 100 km between fill-ups. Short, cold trips raise it."))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
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
                            .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
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
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Odometer History"),
                    yLabel: preferences.distanceUnit.suffix,
                    points: odometerPoints.map { ($0.timestamp, preferences.distanceUnit.convert(km: $0.odometerKm)) },
                    valueFormat: { String(format: "%.0f", $0) }
                ))
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
                }
                if let kmPerDay {
                    curveStat(L10n.text("Average Daily Distance"),
                              Format.distance(km: kmPerDay, decimals: 1, unit: preferences.distanceUnit) + "/" + L10n.text("day"))
                }
                Text(L10n.text("Monthly totals and the daily average use all recorded odometer history, independent of the period selector above."))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
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
                            .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
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
                    .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                        title: L10n.text("Battery Health Trend"),
                        yLabel: "%",
                        points: records.map { ($0.timestamp, $0.stateOfHealthPct) }
                    ))
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
                    KVRow(latest.measurementSource == "calculated-v2" ? L10n.text("Calculated estimate") : L10n.text("Legacy estimate"),
                          Format.count(batteryHealthRecords.count), symbol: "questionmark.circle",
                          info: L10n.text("This is a calculated trend from observed telemetry, not a battery-management-system measurement. Rows are only recorded when the estimate moves meaningfully."))
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
                            .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
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
                    }
                    .chartYAxisLabel(L10n.text("AQI"))
                    .frame(height: chartHeight)
                    .accessibilityLabel(L10n.text("Air quality index trend chart"))
                    .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                        title: L10n.text("Cabin Air Quality Trend"),
                        yLabel: L10n.text("AQI"),
                        points: aqiPoints.map { ($0.record.timestamp, $0.aqi) }
                    ))
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
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartYAxisLabel("µg/m³")
                    .frame(height: chartHeight * 0.7)
                    .accessibilityLabel(L10n.text("Cabin particulate matter trend chart"))
                    if !pm10Points.isEmpty {
                        HStack(spacing: 10) {
                            legendSwatch(HisingenTheme.chartInfo, "PM2.5")
                            legendSwatch(HisingenTheme.chartAttention, "PM10")
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
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
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
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
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
                                    .font(.system(size: 9.5))
                                Spacer()
                                if row.failed > 0 {
                                    Text(L10n.format("%d failed", row.failed))
                                        .font(.system(size: 8.5)).foregroundStyle(HisingenTheme.semanticWarning)
                                }
                                Text(Format.count(row.total)).font(.system(size: 9.5, weight: .semibold)).monospacedDigit()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                ForEach(commands.prefix(12)) { record in
                    HStack {
                        Image(systemName: record.status == "failed" ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(record.status == "failed" ? HisingenTheme.semanticCritical : HisingenTheme.semanticGood)
                        Text(record.command.replacingOccurrences(of: "-", with: " ").capitalized)
                            .font(.system(size: 10.5, weight: .medium))
                        if let ms = record.durationMs {
                            Text(L10n.format("%d ms", ms)).font(.system(size: 8.5)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(record.executedAt, style: .relative).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .help(record.errorMessage ?? record.status.capitalized)
                }
                if !failures.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("Recent failures")).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(Array(failures), id: \.id) { record in
                            Text("• " + (record.errorMessage ?? ""))
                                .font(.system(size: 8.5)).foregroundStyle(.tertiary).lineLimit(2)
                        }
                    }
                }
                dataConfidenceNote(for: commands.map(\.executedAt))
            }
        }
    }

    /// Cabin temperature trend from digital-twin climate readings. Hidden entirely on
    /// vehicles that never report interior temperature.
    var cabinClimateCard: AnyView {
        let chronological = cabinClimateRecords.sorted { $0.timestamp < $1.timestamp }
        guard let latest = chronological.last?.interiorCelsius else { return AnyView(EmptyView()) }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "thermometer.medium", title: L10n.text("Cabin Temperature Trend"), color: .orange)
                    Spacer()
                    Text(Format.temperature(celsius: latest, unit: preferences.temperatureUnit))
                        .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
                Chart(chronological) { record in
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
                Text(L10n.text("Recorded while the vehicle reported climate status. Setpoints appear dashed; gaps mean the car was asleep or not reporting."))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        })
    }
}
