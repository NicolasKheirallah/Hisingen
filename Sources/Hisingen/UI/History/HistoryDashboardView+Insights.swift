import Charts
import SwiftUI

// `HistoryDashboardView` – sections that draw what the app already stored but the Log never
// showed: battery level and parked drain, what charging saved, consumption against temperature,
// where the energy went, how much of the time Hisingen was actually recording, and the figures
// that look ahead. Each one draws only when its data exists, so a car without it shows nothing.

extension HistoryDashboardView {
    // MARK: - Battery level and parked drain

    @ViewBuilder
    var batteryLevelSection: some View {
        let levels = snapshot.batteryLevels
        if levels.count >= 3 {
            let drain = HistoryInsights.parkedDrain(levels: levels, trips: snapshot.reportTrips)
            let first = levels.first?.timestamp ?? Date()
            let last = levels.last?.timestamp ?? first
            let updates = HistoryInsights.softwareChanges(from: snapshot.softwareVersions)
                .filter { $0.date >= first && $0.date <= last }
            let plotted = Self.thinned(levels, to: 900)
            let runs = Self.runIndex(plotted)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Battery Level")).hisType(.subhead, weight: .medium).foregroundStyle(HisingenTheme.ink)
                HistoryScrubChart(items: plotted, date: { $0.timestamp },
                                  callout: { "\(Format.dateTimeFormatter.string(from: $0.timestamp)) · \(Format.percent($0.value ?? 0))" }) {
                    ForEach(Self.pluggedStretches(plotted), id: \.0) { stretch in
                        RectangleMark(xStart: .value(L10n.text("Time"), stretch.0), xEnd: .value(L10n.text("Time"), stretch.1),
                                      yStart: .value(L10n.text("Charge level"), 0.0), yEnd: .value(L10n.text("Charge level"), 100.0))
                            .foregroundStyle(HisingenTheme.inkMuted.opacity(0.14))
                    }
                    ForEach(plotted) { record in
                        LineMark(x: .value(L10n.text("Time"), record.timestamp),
                                 y: .value(L10n.text("Charge level"), record.value ?? 0),
                                 series: .value(L10n.text("Segment"), runs[record.id] ?? 0))
                            .foregroundStyle(HistoryChartColor.chargeLevel)
                            .lineStyle(StrokeStyle(lineWidth: 1.4))
                            .interpolationMethod(.stepEnd)
                    }
                    ForEach(updates) { update in
                        RuleMark(x: .value(L10n.text("Time"), update.date))
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, alignment: .leading, spacing: 1) {
                                Text(update.version).hisType(.micro).foregroundStyle(HisingenTheme.inkMuted)
                            }
                    }
                }
                .chartYScale(domain: 0...100)
                .historyTimeAxis(domain: first...max(last, first.addingTimeInterval(60)))
                .historyYAxis("%", values: .stride(by: 25.0))
                .frame(height: chartHeight)
                .accessibilityLabel(L10n.text("Battery Level"))
                .accessibilityValue(chartAccessibilityValue(points: plotted.compactMap(\.value)))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Battery Level"), yLabel: "%",
                    points: plotted.compactMap { record in record.value.map { (record.timestamp, $0) } },
                    valueFormat: { String(format: "%.0f", locale: L10n.displayLocale, $0) }))
                .hisAnimation(Motion.progress, value: periodDataKey)
                HStack(spacing: 10) {
                    HistoryChartLegendItem(color: HisingenTheme.inkMuted.opacity(0.35), label: L10n.text("Plugged in"), band: true)
                    if !updates.isEmpty {
                        HistoryChartLegendItem(color: HisingenTheme.inkMuted, label: L10n.text("Software"), dashed: true)
                    }
                    Spacer()
                }
                if let perDay = drain.percentPerDay {
                    curveStat(L10n.text("Lost While Parked"), Format.percent(perDay, decimals: 1) + "/" + L10n.text("day"))
                }
                Text(L10n.text("Parked drain counts only stretches between two readings taken unplugged with no trip in between, so it is a floor, not a total."))
                    .hisType(.micro).foregroundStyle(.secondary)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// At most `limit` rows, evenly spaced, always keeping the first and last, so a year of
    /// half-hourly readings does not make the chart draw twenty thousand points.
    nonisolated static func thinned(_ records: [VehicleMetricRecord], to limit: Int) -> [VehicleMetricRecord] {
        guard records.count > limit, limit > 2 else { return records }
        let stride = Double(records.count - 1) / Double(limit - 1)
        return (0..<limit).map { records[min(records.count - 1, Int((Double($0) * stride).rounded()))] }
    }

    /// Readings more than 12 hours apart start a new line, so a week with the app closed is a
    /// break and not a ramp.
    nonisolated static func runIndex(_ records: [VehicleMetricRecord]) -> [Int64: Int] {
        var result: [Int64: Int] = [:]
        for (index, run) in HistoryInsights.segments(of: records, maxGap: 12 * 3_600, timestamp: { $0.timestamp }).enumerated() {
            for record in run { result[record.id] = index }
        }
        return result
    }

    nonisolated static func pluggedStretches(_ records: [VehicleMetricRecord]) -> [(Date, Date)] {
        zip(records, records.dropFirst()).compactMap { earlier, later in
            guard earlier.text == "plugged", later.timestamp.timeIntervalSince(earlier.timestamp) <= 12 * 3_600 else { return nil }
            return (earlier.timestamp, later.timestamp)
        }
    }

    // MARK: - Recording coverage

    @ViewBuilder
    var recordingCoverageSection: some View {
        let days = HistoryInsights.recordingCoverage(timestamps: snapshot.coverageTimestamps)
        if days.count >= 2 {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Recording Coverage")).hisType(.subhead, weight: .medium).foregroundStyle(HisingenTheme.ink)
                Chart(days) { day in
                    BarMark(x: .value(L10n.text("Date"), day.day, unit: .day),
                            y: .value(L10n.text("Hour"), day.hours))
                        .foregroundStyle(HisingenTheme.chartInfo)
                }
                .chartYScale(domain: 0...24)
                .historyTimeAxis(spanning: days.map(\.day))
                .historyYAxis("h", values: .stride(by: 12.0))
                .frame(height: chartHeight * 0.5)
                .accessibilityLabel(L10n.text("Recording Coverage"))
                .accessibilityValue(chartAccessibilityValue(points: days.map { Double($0.hours) }))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Recording Coverage"), yLabel: "h",
                    points: days.map { ($0.day, Double($0.hours)) },
                    valueFormat: { String(format: "%.0f", locale: L10n.displayLocale, $0) }))
                Text(L10n.text("Hours per day with a reading. A short day means Hisingen was not running, not that the car did nothing."))
                    .hisType(.micro).foregroundStyle(.secondary)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Cost and energy

    /// Electricity cost of 100 distance units: the period's average consumption at the average rate
    /// the stored sessions actually paid (or the typed rate, with a fixed tariff).
    @ViewBuilder
    func costPerDistanceStat(averageKwhPer100Km: Double?) -> some View {
        if state.powertrain.hasElectricRange, let consumption = averageKwhPer100Km,
           let costPerKm100 = HistoryInsights.costPer100Km(
               consumptionKwhPer100Km: consumption, pricePerKwh: effectiveLifetimePricePerKwh()) {
            let miles = preferences.distanceUnit == .miles
            curveStat(miles ? L10n.text("Cost per 100 mi") : L10n.text("Cost per 100 km"),
                      Format.currency(miles ? costPerKm100 * 1.609344 : costPerKm100, symbol: preferences.currencySymbol))
        }
    }

    @ViewBuilder
    var energyUseByMonthSection: some View {
        let months = HistoryInsights.monthlyEnergySplit(samples: snapshot.energySamples)
        if months.count >= 2 {
            let parts: [(kind: String, color: Color, value: (HistoryInsights.MonthlyEnergySplit) -> Double)] = [
                (L10n.text("Driving"), HisingenTheme.chartInfo, { $0.driving }),
                (L10n.text("Climate"), HisingenTheme.chartAttention, { $0.climate }),
                (L10n.text("Battery"), HisingenTheme.chartHealth, { $0.battery }),
                (L10n.text("Other"), HisingenTheme.chartPositive, { $0.other })
            ]
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Energy Use by Month")).hisType(.subhead, weight: .medium).foregroundStyle(HisingenTheme.ink)
                Chart {
                    ForEach(months) { month in
                        ForEach(parts, id: \.kind) { part in
                            BarMark(x: .value(L10n.text("Month"), month.month, unit: .month),
                                    y: .value(L10n.text("Energy"), part.value(month) / 1_000))
                                .foregroundStyle(by: .value(L10n.text("Series"), part.kind))
                        }
                    }
                }
                .chartForegroundStyleScale(domain: parts.map(\.kind), range: parts.map(\.color))
                .chartLegend(.hidden)
                .historyTimeAxis(spanning: months.map(\.month), monthly: true)
                .historyYAxis("kWh")
                .frame(height: chartHeight * 0.8)
                .accessibilityLabel(L10n.text("Energy Use by Month"))
                .accessibilityValue(chartAccessibilityValue(points: months.map { $0.total / 1_000 }))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Energy Use by Month"), yLabel: "kWh",
                    points: months.map { ($0.month, $0.total / 1_000) },
                    valueFormat: { String(format: "%.0f", locale: L10n.displayLocale, $0) }))
                HStack(spacing: 10) {
                    ForEach(parts, id: \.kind) { part in
                        HistoryChartLegendItem(color: part.color, label: part.kind, band: true)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Consumption and temperature

    @ViewBuilder
    func temperatureConsumptionSection(trips: [TripHistoryEntry]) -> some View {
        let unit = preferences.energyConsumptionUnit
        let tempUnit = preferences.temperatureUnit
        let points = HistoryInsights.temperatureConsumptionPoints(from: trips)
        if points.count >= 8 {
            let fit = HistoryInsights.linearFit(points.map { ($0.temperature, $0.consumption) })
            let lo = points.map(\.temperature).min() ?? 0
            let hi = points.map(\.temperature).max() ?? 1
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Consumption vs Temperature")).hisType(.subhead, weight: .medium).foregroundStyle(HisingenTheme.ink)
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        PointMark(x: .value(L10n.text("Temperature"), tempUnit.convert(celsius: point.temperature)),
                                  y: .value(L10n.text("Consumption"), unit.plotValue(kwhPer100Km: point.consumption)))
                            .symbolSize(18)
                            .foregroundStyle(HisingenTheme.chartInfo.opacity(0.6))
                    }
                    if let fit {
                        ForEach([lo, hi], id: \.self) { celsius in
                            LineMark(x: .value(L10n.text("Temperature"), tempUnit.convert(celsius: celsius)),
                                     y: .value(L10n.text("Consumption"),
                                               unit.plotValue(kwhPer100Km: max(0.1, fit.intercept + fit.slope * celsius))),
                                     series: .value(L10n.text("Series"), "fit"))
                                .foregroundStyle(HisingenTheme.chartAttention)
                                .lineStyle(StrokeStyle(lineWidth: 1.6))
                        }
                    }
                }
                .historyYAxis(unit.title)
                .chartXAxisLabel(tempUnit.suffix)
                .frame(height: chartHeight)
                .accessibilityLabel(L10n.text("Consumption vs Temperature"))
                .accessibilityValue(chartAccessibilityValue(points: points.map { unit.plotValue(kwhPer100Km: $0.consumption) }))
            }
        }
        let months = HistoryInsights.monthlyNormalisedConsumption(from: trips)
        if months.count >= 2 {
            let reference = Format.temperature(celsius: 15, unit: tempUnit)
            let normalisedName = L10n.format("Normalised to %@", reference)
            VStack(alignment: .leading, spacing: 6) {
                Chart {
                    ForEach(months) { month in
                        LineMark(x: .value(L10n.text("Month"), month.month, unit: .month),
                                 y: .value(L10n.text("Consumption"), unit.plotValue(kwhPer100Km: month.raw)),
                                 series: .value(L10n.text("Series"), "raw"))
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        LineMark(x: .value(L10n.text("Month"), month.month, unit: .month),
                                 y: .value(L10n.text("Consumption"), unit.plotValue(kwhPer100Km: month.normalised)),
                                 series: .value(L10n.text("Series"), "normalised"))
                            .foregroundStyle(HisingenTheme.chartInfo)
                            .lineStyle(StrokeStyle(lineWidth: 1.8))
                        PointMark(x: .value(L10n.text("Month"), month.month, unit: .month),
                                  y: .value(L10n.text("Consumption"), unit.plotValue(kwhPer100Km: month.normalised)))
                            .symbolSize(14)
                            .foregroundStyle(HisingenTheme.chartInfo)
                    }
                }
                .historyTimeAxis(spanning: months.map(\.month), monthly: true)
                .historyYAxis(unit.title)
                .frame(height: chartHeight * 0.7)
                .accessibilityLabel(normalisedName)
                .accessibilityValue(chartAccessibilityValue(points: months.map { unit.plotValue(kwhPer100Km: $0.normalised) }))
                HStack(spacing: 10) {
                    HistoryChartLegendItem(color: HisingenTheme.inkMuted, label: L10n.text("Average consumption"), dashed: true)
                    HistoryChartLegendItem(color: HisingenTheme.chartInfo, label: normalisedName)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Charging trends

    @ViewBuilder
    var spotSavingsRow: some View {
        if let savings = HistoryInsights.spotSavings(
            sessions: chargingSessions, fixedPricePerKwh: preferences.electricityPricePerKwh) {
            let amount = Format.currency(abs(savings.saved), symbol: preferences.currencySymbol)
            let sign = savings.saved >= 0 ? "" : "-"
            let percent = savings.percent.map { " (" + Format.percent(abs($0), decimals: 0) + ")" } ?? ""
            KVRow(L10n.text("Saved vs Fixed Rate"), sign + amount + percent, symbol: "tag",
                  info: L10n.text("Market-priced sessions against what the same energy would have cost at your fixed rate. Sessions without market prices are left out."))
        }
    }

    @ViewBuilder
    var sessionTrendSection: some View {
        let sessions = chargingSessions.filter { $0.peakPowerKw > 0 }.sorted { $0.startedAt < $1.startedAt }
        if sessions.count >= 4 {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Peak Power by Session")).hisType(.subhead, weight: .medium).foregroundStyle(HisingenTheme.ink)
                HistoryScrubChart(items: sessions, date: { $0.startedAt },
                                  callout: { "\(Format.dateFormatter.string(from: $0.startedAt)) · \(Format.powerKw($0.peakPowerKw))" }) {
                    ForEach(sessions) { session in
                        PointMark(x: .value(L10n.text("Date"), session.startedAt),
                                  y: .value(L10n.text("Peak"), session.peakPowerKw))
                            .symbolSize(22)
                            .foregroundStyle(HistoryChartColor.power)
                    }
                }
                .chartYScale(domain: 0...((sessions.map(\.peakPowerKw).max() ?? 1) * 1.15))
                .historyTimeAxis(spanning: sessions.map(\.startedAt))
                .historyYAxis("kW")
                .frame(height: chartHeight * 0.8)
                .accessibilityLabel(L10n.text("Peak Power by Session"))
                .accessibilityValue(chartAccessibilityValue(points: sessions.map(\.peakPowerKw)))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Peak Power by Session"), yLabel: "kW",
                    points: sessions.map { ($0.startedAt, $0.peakPowerKw) }))
            }
        }
    }

    @ViewBuilder
    func timeOfDaySection(_ byTimeOfDay: [HistoryInsights.TimeOfDay: Double]) -> some View {
        let buckets = HistoryInsights.TimeOfDay.allCases.filter { (byTimeOfDay[$0] ?? 0) > 0 }
        if buckets.count >= 2 {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Energy by Time of Day")).hisType(.subhead, weight: .medium).foregroundStyle(HisingenTheme.ink)
                Chart(buckets, id: \.self) { bucket in
                    BarMark(x: .value(L10n.text("Hour"), L10n.text(bucket.rawValue)),
                            y: .value(L10n.text("Energy"), byTimeOfDay[bucket] ?? 0))
                        .foregroundStyle(HistoryChartColor.chargeLevel)
                }
                .historyYAxis("kWh")
                .frame(height: chartHeight * 0.6)
                .accessibilityLabel(L10n.text("Energy by Time of Day"))
                .accessibilityValue(chartAccessibilityValue(points: buckets.map { byTimeOfDay[$0] ?? 0 }))
            }
        }
    }

    // MARK: - Session detail

    /// What the charger itself measured for this session, kept apart from what the car's battery
    /// gained. The two answer different questions, and the difference is the loss. The price leads
    /// the stats row above; this row says how it was reached.
    @ViewBuilder
    func wallboxRows(_ session: HistoricalChargingSession, cheapest: CheapestOption? = nil) -> some View {
        if let wallbox = session.wallbox {
            VStack(alignment: .leading, spacing: 4) {
                KVRow(L10n.text("Battery-side energy"), Format.energyKwh(session.energyDeliveredKwh))
                KVRow(L10n.text("Energy delivered by charger"), Format.energyKwh(wallbox.energyKwh))
                if let loss = chargingLoss(session, wallbox: wallbox) {
                    KVRow(L10n.text("Charging Loss"), "\(Format.number(loss.share * 100, decimals: 1)) % · \(Format.energyKwh(loss.kwh))",
                          info: L10n.text("The charger's energy minus the battery-side energy, as a share of what the charger delivered. The battery side is itself an estimate, so a figure far from the usual one points at the estimate as often as at the charger."))
                }
                if wallbox.cost != nil || wallbox.partialCost != nil {
                    KVRow(L10n.text("Pricing"),
                          wallbox.isEstimatedCost ? L10n.text("Session total at the average price") : L10n.text("By when the energy flowed"),
                          info: wallbox.costAssumptions.isEmpty ? nil : wallbox.costAssumptions.joined(separator: ". ") + ".")
                }
                if let cheapest, cheapest.saving >= 1, let paid = wallbox.cost, cheapest.saving >= paid * 0.03 {
                    let symbol = wallbox.currency ?? session.currencySymbol ?? preferences.currencySymbol
                    KVRow(L10n.text("Could Have Saved"), Format.currency(cheapest.saving, symbol: symbol),
                          info: L10n.format("The same energy in the cheapest slots while the cable was in, at up to %@, would have cost %@. A floor: it lets the charger pause as often as the prices ask, and a car that has to be ready by a set time cannot always do that.",
                                            Format.powerKw(cheapest.rateKw), Format.currency(cheapest.cost, symbol: symbol)))
                }
                if let missing = wallbox.missingKwh, missing > 0.05 {
                    KVRow(L10n.text("Unpriced Energy"), Format.energyKwh(missing), warning: true)
                }
            }
        }
    }

    /// What the charger delivered that the battery did not take in. Only when the battery side is
    /// trustworthy enough to subtract: a low-confidence estimate would put its own error in the figure.
    func chargingLoss(_ session: HistoricalChargingSession, wallbox: WallboxMeasurement) -> (share: Double, kwh: Double)? {
        guard session.energySource != .wallboxOnly, session.confidence != .low,
              session.energyDeliveredKwh > 0, wallbox.energyKwh > session.energyDeliveredKwh else { return nil }
        let kwh = wallbox.energyKwh - session.energyDeliveredKwh
        let share = kwh / wallbox.energyKwh
        return share <= 0.35 ? (share, kwh) : nil
    }

    /// One short note per session, saved when the field loses focus or the reader presses Return.
    @ViewBuilder
    func sessionNoteField(_ session: HistoricalChargingSession) -> some View {
        TextField(L10n.text("Session note"), text: $sessionNoteDraft)
            .textFieldStyle(.plain)
            .hisType(.caption)
            .padding(5)
            .background(Color.primary.opacity(0.04), in: Rectangle())
            .onSubmit { saveSessionNote(for: session) }
            .onChange(of: session.id, initial: true) { _, _ in
                sessionNoteDraft = sessionNotes[session.id] ?? ""
            }
            .onDisappear { saveSessionNote(for: session) }
            .accessibilityLabel(L10n.text("Session note"))
    }

    func saveSessionNote(for session: HistoricalChargingSession) {
        let trimmed = sessionNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (sessionNotes[session.id] ?? "") else { return }
        history.setSessionNote(trimmed, sessionID: session.id, vin: session.vin)
        if trimmed.isEmpty { sessionNotes.removeValue(forKey: session.id) } else { sessionNotes[session.id] = trimmed }
    }

    // MARK: - Looking ahead

    @ViewBuilder
    var monthProjectionText: some View {
        let month = snapshot.thisMonth
        let distance = HistoryInsights.monthEndProjection(monthToDate: month.distanceKm)
        let energy = HistoryInsights.monthEndProjection(monthToDate: month.energyKwh)
        if distance != nil || energy != nil {
            let parts = [distance.map { Format.distance(km: $0, decimals: 0, unit: preferences.distanceUnit) },
                         energy.map { Format.energyKwh($0) }].compactMap { $0 }
            Text(L10n.format("On pace for %@", parts.joined(separator: " · ")))
                .hisType(.micro).foregroundStyle(.secondary)
                .hisCaptionLeading()
        }
    }

    @ViewBuilder
    func batteryWarrantyStat(kmPerDay: Double?) -> some View {
        if let warranty = state.maintenance.warranty, let odometer = state.maintenance.odometerKm,
           let outlook = HistoryInsights.batteryWarrantyOutlook(
               odometerKm: Double(odometer), limitKm: warranty.batteryWarrantyKm,
               validUntil: warranty.batteryWarrantyValidUntil, kmPerDay: kmPerDay) {
            curveStat(L10n.text("Battery Warranty Remaining"),
                      Format.distance(km: outlook.kilometresLeft, decimals: 0, unit: preferences.distanceUnit, grouped: true))
            if outlook.distanceRunsOutFirst, let date = outlook.reachesLimitOn {
                Text(L10n.format("At this pace the distance limit is reached around %@",
                                 date.formatted(Date.FormatStyle().locale(L10n.clockLocale).month(.abbreviated).year())))
                    .hisType(.micro).foregroundStyle(.secondary)
                    .hisCaptionLeading()
            }
        }
    }
}
