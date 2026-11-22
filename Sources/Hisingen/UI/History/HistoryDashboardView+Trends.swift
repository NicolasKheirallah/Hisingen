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
        return HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HistorySectionHeading(symbol: "gauge.high", title: L10n.text("Consumption Trend"), color: HisingenTheme.chartPositive)
                    Spacer()
                    if let average {
                        Text(preferences.energyConsumptionUnit.format(kwhPer100Km: average))
                            .hisType(.caption, weight: .semibold, design: .rounded).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                let unit = preferences.energyConsumptionUnit
                let plotAverage = average.map { unit.plotValue(kwhPer100Km: $0) }
                HistoryScrubChart(items: points, date: { $0.timestamp },
                                  callout: { "\(Format.dateFormatter.string(from: $0.timestamp)) · \(unit.format(kwhPer100Km: $0.kwhPer100Km))" }) {
                    // Raw readings are the evidence: muted points on a thin line. The moving
                    // average is the reading of them, so it is the solid, heavier line.
                    ForEach(points) { point in
                        LineMark(
                            x: .value(L10n.text("Date"), point.timestamp),
                            y: .value(L10n.text("Consumption"), unit.plotValue(kwhPer100Km: point.kwhPer100Km)),
                            series: .value(L10n.text("Segment"), segmentByID[point.id] ?? 0)
                        )
                        .foregroundStyle(HisingenTheme.chartInfo.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .interpolationMethod(.linear)
                        PointMark(
                            x: .value(L10n.text("Date"), point.timestamp),
                            y: .value(L10n.text("Consumption"), unit.plotValue(kwhPer100Km: point.kwhPer100Km))
                        )
                        .symbolSize(14)
                        .foregroundStyle(HisingenTheme.chartInfo.opacity(0.6))
                    }
                    // Split by the same gap rule as the raw reading, so an average drawn through a
                    // fortnight of missing data does not look like one drawn through readings.
                    ForEach(smoothed) { point in
                        LineMark(
                            x: .value(L10n.text("Date"), point.timestamp),
                            y: .value(L10n.text("Smoothed"), unit.plotValue(kwhPer100Km: point.value)),
                            series: .value(L10n.text("Segment"), smoothedSegmentByID[point.id] ?? 0)
                        )
                        .foregroundStyle(HisingenTheme.chartInfo)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.linear)
                    }
                    if let plotAverage {
                        RuleMark(y: .value(L10n.text("Average consumption"), plotAverage))
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .historyTimeAxis(spanning: points.map(\.timestamp))
                .historyYAxis(unit.title)
                .frame(height: chartHeight)
                .accessibilityLabel(L10n.text("Energy consumption trend chart"))
                .accessibilityValue(chartAccessibilityValue(points: smoothed.map { unit.plotValue(kwhPer100Km: $0.value) }))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Consumption Trend"),
                    yLabel: unit.title,
                    points: points.map { ($0.timestamp, unit.plotValue(kwhPer100Km: $0.kwhPer100Km)) }
                ))
                .hisAnimation(Motion.progress, value: periodDataKey)
                if !smoothed.isEmpty {
                    HStack(spacing: 10) {
                        HistoryChartLegendItem(color: HisingenTheme.chartInfo.opacity(0.6), label: L10n.text("Reading"))
                        HistoryChartLegendItem(color: HisingenTheme.chartInfo, label: L10n.text("5-point average"))
                        if plotAverage != nil {
                            HistoryChartLegendItem(color: HisingenTheme.inkMuted, label: L10n.text("Average consumption"), dashed: true)
                        }
                        Spacer()
                    }
                }
                if let median, let average, abs(median - average) > 0.5 {
                    Text(L10n.format("Typical drive: %@ (average is pulled by outlier trips)",
                                     preferences.energyConsumptionUnit.format(kwhPer100Km: median)))
                        .hisType(.micro).foregroundStyle(.secondary)
                }
                seasonalRow(seasonal)
                costPerDistanceStat(averageKwhPer100Km: average)
                energyUseByMonthSection
                if state.hasFreshReading(.battery), let battery = state.energy.batteryPercentage,
                   let estimate = HistoryInsights.historicalRange(
                    from: telemetryRecords, vin: state.identity.vin,
                    usableCapacityKwh: history.usableCapacityKwh(vin: state.identity.vin, state: state),
                    batteryPercentage: battery) {
                    Text(L10n.format("Range from recorded consumption: %@",
                                     Format.distance(km: estimate.typicalKm, unit: preferences.distanceUnit)))
                        .hisType(.caption, weight: .medium)
                    Text(L10n.format("%@ to %@ across %d observations. Uses current battery charge and configured usable capacity; this is not a route prediction.",
                                     Format.distance(km: estimate.shortestKm, unit: preferences.distanceUnit),
                                     Format.distance(km: estimate.longestKm, unit: preferences.distanceUnit),
                                     estimate.observationCount))
                        .hisType(.micro).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let slopePerDay {
                    let monthlySlope = slopePerDay * 30
                    Text(L10n.format("Trending %@ kWh/100km per month", Format.signedNumber(monthlySlope, decimals: 2)))
                        .hisType(.micro, weight: .medium)
                        .foregroundStyle(monthlySlope > 0.5 ? HisingenTheme.semanticWarning : .secondary)
                }
                Text(L10n.text("Vehicle-reported consumption between charges. Short drives and climate use raise it; motorway cruising lowers it."))
                    .hisType(.micro).foregroundStyle(.secondary)
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
        HistoryChartLegendItem(color: color, label: label, dashed: dashed)
    }

    // MARK: - Consumption trend (combustion / hybrid)

    var combustionConsumptionCard: some View {
        let points = combustionConsumptionPoints
        let segmentByID = gapSegmentIndex(of: points, timestamp: \.timestamp)
        let average = points.isEmpty ? nil : points.reduce(0) { $0 + $1.kwhPer100Km } / Double(points.count)
        return HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HistorySectionHeading(symbol: "fuelpump", title: L10n.text("Fuel Consumption Trend"), color: HisingenTheme.semanticWarning)
                    Spacer()
                    if let average {
                        Text(Format.fuelEconomy(lPer100Km: average, unit: preferences.fuelEconomyUnit))
                            .hisType(.caption, weight: .semibold, design: .rounded).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                let fuelUnit = preferences.fuelEconomyUnit
                HistoryScrubChart(items: points, date: { $0.timestamp },
                                  callout: { "\(Format.dateFormatter.string(from: $0.timestamp)) · \(Format.fuelEconomy(lPer100Km: $0.kwhPer100Km, unit: fuelUnit))" }) {
                    ForEach(points) { point in
                        LineMark(
                            x: .value(L10n.text("Date"), point.timestamp),
                            y: .value(L10n.text("Consumption"), fuelUnit.plotValue(lPer100Km: point.kwhPer100Km)),
                            series: .value(L10n.text("Segment"), segmentByID[point.id] ?? 0)
                        )
                        .foregroundStyle(HisingenTheme.chartAttention)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.linear)
                        PointMark(
                            x: .value(L10n.text("Date"), point.timestamp),
                            y: .value(L10n.text("Consumption"), fuelUnit.plotValue(lPer100Km: point.kwhPer100Km))
                        )
                        .symbolSize(14)
                        .foregroundStyle(HisingenTheme.chartAttention)
                    }
                }
                .historyTimeAxis(spanning: points.map(\.timestamp))
                .historyYAxis(fuelUnit.suffix)
                .frame(height: chartHeight)
                .accessibilityLabel(L10n.text("Fuel consumption trend chart"))
                .accessibilityValue(chartAccessibilityValue(points: points.map { fuelUnit.plotValue(lPer100Km: $0.kwhPer100Km) }))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Fuel Consumption Trend"),
                    yLabel: fuelUnit.suffix,
                    points: points.map { ($0.timestamp, fuelUnit.plotValue(lPer100Km: $0.kwhPer100Km)) }
                ))
                .hisAnimation(Motion.progress, value: periodDataKey)
                Text(L10n.text("Vehicle-reported litres per 100 km between fill-ups. Short, cold trips raise it."))
                    .hisType(.micro).foregroundStyle(.secondary)
                dataConfidenceNote(for: points.map(\.timestamp))
            }
        }
    }

    var odometerChartCard: some View {
        let covered = HistoryInsights.distanceCovered(from: odometerPoints)
        let segmentByID = gapSegmentIndex(of: odometerPoints, timestamp: \.timestamp)
        let kmPerDay = HistoryInsights.averageKmPerDay(from: allTimeOdometerPoints)
        let monthly = HistoryInsights.monthlyMileage(from: allTimeOdometerPoints)
        return HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HistorySectionHeading(symbol: "road.lanes", title: L10n.text("Odometer History"), color: HisingenTheme.chartInfo)
                    Spacer()
                    if let covered {
                        Text("+\(Format.distance(km: covered, decimals: 0, unit: preferences.distanceUnit))")
                            .hisType(.caption, weight: .semibold, design: .rounded).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                HistoryScrubChart(items: odometerPoints, date: { $0.timestamp },
                                  callout: { "\(Format.dateFormatter.string(from: $0.timestamp)) · \(Format.distance(km: $0.odometerKm, decimals: 0, unit: preferences.distanceUnit, grouped: true))" }) {
                    ForEach(odometerPoints) { point in
                        LineMark(
                            x: .value(L10n.text("Date"), point.timestamp),
                            y: .value(L10n.text("Odometer"), preferences.distanceUnit.convert(km: point.odometerKm)),
                            series: .value(L10n.text("Segment"), segmentByID[point.id] ?? 0)
                        )
                        .foregroundStyle(HisingenTheme.chartInfo)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .historyTimeAxis(spanning: odometerPoints.map(\.timestamp))
                .historyYAxis(preferences.distanceUnit.suffix)
                .frame(height: chartHeight)
                .accessibilityLabel(L10n.text("Odometer history chart"))
                .accessibilityValue(chartAccessibilityValue(points: odometerPoints.map { Double($0.odometerKm) }))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Odometer History"),
                    yLabel: preferences.distanceUnit.suffix,
                    points: odometerPoints.map { ($0.timestamp, preferences.distanceUnit.convert(km: $0.odometerKm)) },
                    valueFormat: { String(format: "%.0f", locale: L10n.displayLocale, $0) }
                ))
                .hisAnimation(Motion.progress, value: periodDataKey)
                if monthly.count >= 2 {
                    // This chart ignores the period selector, so it says so where it is drawn.
                    Text(L10n.text("All recorded history")).hisType(.caption).foregroundStyle(HisingenTheme.inkMuted)
                    Chart(monthly) { bucket in
                        BarMark(
                            x: .value(L10n.text("Month"), bucket.month, unit: .month),
                            y: .value(L10n.text("Distance"), preferences.distanceUnit.convert(km: bucket.distanceKm))
                        )
                        .foregroundStyle(HisingenTheme.chartInfo.opacity(0.6))
                    }
                    .historyTimeAxis(spanning: monthly.map(\.month), monthly: true)
                    .historyYAxis(preferences.distanceUnit.suffix)
                    .frame(height: chartHeight * 0.7)
                    .accessibilityLabel(L10n.text("Monthly mileage chart"))
                    .accessibilityValue(chartAccessibilityValue(points: monthly.map { $0.distanceKm }))
                    .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                        title: L10n.text("Monthly mileage chart"), yLabel: preferences.distanceUnit.suffix,
                        points: monthly.map { ($0.month, preferences.distanceUnit.convert(km: $0.distanceKm)) },
                        valueFormat: { String(format: "%.0f", locale: L10n.displayLocale, $0) }))
                    .hisAnimation(Motion.progress, value: lifetimeDataKey)
                }
                batteryWarrantyStat(kmPerDay: kmPerDay)
                if let kmPerDay {
                    curveStat(L10n.text("Average Daily Distance"),
                              Format.distance(km: kmPerDay, decimals: 1, unit: preferences.distanceUnit) + "/" + L10n.text("day"))
                }
                Text(L10n.text("Monthly totals and the daily average use all recorded odometer history, independent of the period selector above."))
                    .hisType(.micro).foregroundStyle(.secondary)
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
        return HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HistorySectionHeading(symbol: "heart.text.square", title: L10n.text("Battery Health Trend"), color: HisingenTheme.chartHealth)
                    Spacer()
                    if let latest {
                        Text(Format.percent(latest.stateOfHealthPct, decimals: 1))
                            .hisType(.label, weight: .bold, design: .rounded).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                batteryLevelSection
                if records.count >= 2 {
                    HistoryScrubChart(items: records, date: { $0.timestamp },
                                      callout: { "\(Format.dateFormatter.string(from: $0.timestamp)) · \(Format.percent($0.stateOfHealthPct, decimals: 1))" }) {
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
                    }
                    .chartYScale(domain: sohDomain(records))
                    .historyTimeAxis(spanning: records.map(\.timestamp))
                    .historyYAxis("%")
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
                          Format.distance(km: latest.odometerKm, decimals: 0, unit: preferences.distanceUnit, grouped: true), symbol: "road.lanes")
                    if let slope = HistoryInsights.batteryHealthTrendRobust(from: batteryHealthRecords).stateOfHealthPctPer10kKm,
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
        return HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HistorySectionHeading(symbol: "wind", title: L10n.text("Cabin Air Quality Trend"), color: HisingenTheme.chartPositive)
                    Spacer()
                    if let latestAqi = latest?.airQualityIndex {
                        Text(L10n.format("%d AQI", Int(latestAqi)))
                            .hisType(.caption, weight: .semibold, design: .rounded).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if !aqiPoints.isEmpty {
                    HistoryScrubChart(items: chronological.filter { $0.airQualityIndex != nil },
                                      date: { $0.timestamp },
                                      callout: { "\(Format.dateFormatter.string(from: $0.timestamp)) · \(L10n.format("%d AQI", Int($0.airQualityIndex ?? 0)))" }) {
                        ForEach(aqiPoints, id: \.record.id) { item in
                            LineMark(
                                x: .value(L10n.text("Date"), item.record.timestamp),
                                y: .value(L10n.text("Air Quality Index"), item.aqi),
                                series: .value(L10n.text("Segment"), aqiSegmentByID[item.record.id] ?? 0)
                            )
                            .foregroundStyle(HisingenTheme.chartInfo)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.linear)
                        }
                        RuleMark(y: .value(L10n.text("Moderate Threshold"), 50))
                            .foregroundStyle(HisingenTheme.semanticWarning.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, alignment: .leading) {
                                Text(L10n.text("Moderate"))
                                    .hisType(.micro, weight: .medium)
                                    .foregroundStyle(HisingenTheme.semanticWarning)
                            }
                    }
                    .historyTimeAxis(spanning: aqiPoints.map { $0.record.timestamp })
                    .historyYAxis(L10n.text("AQI"))
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
                            .foregroundStyle(HisingenTheme.chartInfo.opacity(0.14))
                            .interpolationMethod(.linear)
                            LineMark(
                                x: .value(L10n.text("Date"), item.record.timestamp),
                                y: .value("PM2.5", item.pm25),
                                series: .value(L10n.text("Series"), "PM2.5 line")
                            )
                            .foregroundStyle(HisingenTheme.chartInfo)
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                            .interpolationMethod(.linear)
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
                            .interpolationMethod(.linear)
                        }
                    }
                    .historyTimeAxis(spanning: pm25Points.map { $0.record.timestamp } + pm10Points.map { $0.record.timestamp })
                    .historyYAxis("µg/m³")
                    .frame(height: chartHeight * 0.7)
                    .accessibilityLabel(L10n.text("Cabin particulate matter trend chart"))
                    .accessibilityValue(chartAccessibilityValue(points: pm10Points.map { $0.pm10 }))
                    .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                        title: L10n.text("Cabin particulate matter trend chart"),
                        yLabel: "µg/m³",
                        series: [
                            .init(name: "PM2.5", points: pm25Points.map { ($0.record.timestamp, $0.pm25) }),
                            .init(name: "PM10", points: pm10Points.map { ($0.record.timestamp, $0.pm10) })
                        ]
                    ))
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
                    .hisType(.micro).foregroundStyle(.secondary)
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
        return HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HistorySectionHeading(symbol: "command", title: L10n.text("Automation & Commands"), color: HisingenTheme.semanticWarning)
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
                PaginatedSection(items: commands, pageSize: preferences.historyPageSize(for: .historyAutomations),
                                 resetKeys: [periodLoadKey],
                                 emptyMessage: L10n.text("No automations ran in this period.")) { visibleCommands, footer in
                    ForEach(visibleCommands) { record in
                        let outcome = auditOutcome(record.status)
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: outcome.symbol)
                                .foregroundStyle(outcome.color)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.command.replacingOccurrences(of: "-", with: " ").capitalized)
                                    .hisType(.caption, weight: .medium)
                                Text(outcome.label)
                                    .hisType(.micro)
                                    .foregroundStyle(HisingenTheme.inkMuted)
                            }
                            if let ms = record.durationMs {
                                Text(L10n.format("%d ms", ms)).hisType(.nano).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(record.executedAt, style: .relative).hisType(.micro).foregroundStyle(.secondary)
                        }
                        .help(record.errorMessage ?? outcome.label)
                    }
                    footer
                }
                if !failures.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("Recent failures")).hisType(.nano, weight: .semibold).foregroundStyle(.secondary)
                        ForEach(Array(failures), id: \.id) { record in
                            Text("• " + (record.errorMessage ?? ""))
                                .hisType(.nano).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func auditOutcome(_ status: String) -> (symbol: String, color: Color, label: String) {
        switch status {
        case "confirmed":
            ("checkmark.circle.fill", HisingenTheme.semanticGood, L10n.text("Matching vehicle reading observed"))
        case "completed":
            ("checkmark.circle.fill", HisingenTheme.semanticGood, L10n.text("Completed"))
        case "acknowledged":
            ("checkmark.circle.fill", HisingenTheme.semanticGood, L10n.text("Command acknowledged by the vehicle service"))
        case "failed":
            ("xmark.circle.fill", HisingenTheme.semanticCritical, L10n.text("Failed"))
        case "confirmation_timed_out":
            ("exclamationmark.triangle.fill", HisingenTheme.semanticWarning, L10n.text("Command outcome not confirmed"))
        case "accepted", "delivered":
            ("clock", HisingenTheme.inkMuted, L10n.text("Command sent: waiting for the vehicle"))
        default:
            ("questionmark.circle", HisingenTheme.inkMuted, L10n.text("Unknown"))
        }
    }

    /// Cabin temperature trend from digital-twin climate readings. Hidden entirely on
    /// vehicles that never report interior temperature.
    var cabinClimateCard: AnyView {
        let chronological = cabinClimateRecords.sorted { $0.timestamp < $1.timestamp }
        let plotted = chronological.filter { $0.interiorCelsius != nil }
        guard let latest = plotted.last?.interiorCelsius else { return AnyView(EmptyView()) }
        let setpointRecords = plotted.filter { $0.requestedCelsius != nil }
        let cabinGap: TimeInterval = 6 * 3_600
        func runs(_ records: [VehicleDatabase.CabinClimateRecord]) -> [Int64: Int] {
            var result: [Int64: Int] = [:]
            for (index, run) in HistoryInsights.segments(of: records, maxGap: cabinGap, timestamp: { $0.timestamp }).enumerated() {
                for record in run { result[record.id] = index }
            }
            return result
        }
        let interiorRuns = runs(plotted)
        let setpointRuns = runs(setpointRecords)
        return AnyView(HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HistorySectionHeading(symbol: "thermometer.medium", title: L10n.text("Cabin Temperature Trend"), color: HisingenTheme.semanticWarning)
                    Spacer()
                    Text(Format.temperature(celsius: latest, unit: preferences.temperatureUnit))
                        .hisType(.caption, weight: .semibold, design: .rounded).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                let tempUnit = preferences.temperatureUnit
                HistoryScrubChart(items: plotted, date: { $0.timestamp },
                                  callout: { "\(Format.dateFormatter.string(from: $0.timestamp)) · \(Format.temperature(celsius: $0.interiorCelsius ?? 0, unit: tempUnit))" }) {
                    // Each run of readings is its own line, and a stretch with no readings is a
                    // break, as the caption below says. It used to draw straight across the gap.
                    ForEach(plotted) { record in
                        LineMark(
                            x: .value(L10n.text("Date"), record.timestamp),
                            y: .value(L10n.text("Interior"), tempUnit.convert(celsius: record.interiorCelsius ?? 0)),
                            series: .value(L10n.text("Segment"), "interior-\(interiorRuns[record.id] ?? 0)")
                        )
                        .foregroundStyle(HisingenTheme.chartAttention)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.linear)
                    }
                    ForEach(setpointRecords) { record in
                        LineMark(
                            x: .value(L10n.text("Date"), record.timestamp),
                            y: .value(L10n.text("Setpoint"), tempUnit.convert(celsius: record.requestedCelsius ?? 0)),
                            series: .value(L10n.text("Segment"), "setpoint-\(setpointRuns[record.id] ?? 0)")
                        )
                        .foregroundStyle(HisingenTheme.chartInfo)
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                        .interpolationMethod(.linear)
                    }
                }
                .historyTimeAxis(spanning: plotted.map(\.timestamp))
                .historyYAxis(tempUnit.suffix)
                .frame(height: chartHeight * 0.9)
                .accessibilityLabel(L10n.text("Cabin temperature trend chart"))
                .accessibilityValue(chartAccessibilityValue(
                    points: plotted.compactMap { $0.interiorCelsius }
                        .map { tempUnit.convert(celsius: $0) }))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Cabin Temperature Trend"), yLabel: tempUnit.suffix,
                    points: plotted.compactMap { record in
                        record.interiorCelsius.map { (record.timestamp, tempUnit.convert(celsius: $0)) }
                    }))
                .hisAnimation(Motion.progress, value: lifetimeDataKey)
                HStack(spacing: 10) {
                    HistoryChartLegendItem(color: HisingenTheme.chartAttention, label: L10n.text("Interior"))
                    if !setpointRecords.isEmpty {
                        HistoryChartLegendItem(color: HisingenTheme.chartInfo, label: L10n.text("Setpoint"), dashed: true)
                    }
                    Spacer()
                }
                Text(L10n.text("Recorded while the vehicle reported climate status. Setpoints appear dashed; gaps mean the car was asleep or not reporting."))
                    .hisType(.micro).foregroundStyle(.secondary)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
            }
        })
    }
}
