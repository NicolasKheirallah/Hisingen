import Charts
import SwiftUI

/// The recorded curves of one charging session: charge level, power, the price per kWh, current
/// and voltage on one shared time axis, with one scrub cursor running through all of them.
///
/// Each line holds its last reported value until the next sample (`stepEnd`), the same rule for
/// every series. The charts used to mix step and linear interpolation, so a sparse power series
/// drew V-shaped dips to zero between two samples that read as real events, while the charge
/// level beside it was drawn honestly.
struct SessionCurveCharts: View {
    let curve: [HistoryInsights.ChargingCurvePoint]
    let targetSoc: Double?
    let averagePowerKw: Double?
    let showsTenToEighty: Bool
    /// What the home charger itself reported during the session: (time, kW).
    let chargerPower: [(Date, Double)]
    /// The price per kWh through the session, when a price source covers it.
    var prices: SessionPriceSeries? = nil
    var currencySymbol: String = ""
    let chartHeight: CGFloat
    let animationKey: String

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var scrub: Date?

    /// Width reserved for the value labels, so all stacked charts share one plot width.
    private let labelWidth: CGFloat = 34

    var body: some View {
        let gapThreshold = HistoryInsights.chargingCurveGapThreshold
        let socSegments = segmentIndex(curve, gapThreshold)
        let powerCurve = curve.filter { $0.powerKw != nil }
        let powerSegments = segmentIndex(powerCurve, gapThreshold)
        let currentCurve = curve.filter { $0.currentAmps != nil }
        let currentSegments = segmentIndex(currentCurve, gapThreshold)
        let rawVoltage = curve.filter { $0.voltageVolts != nil }
        let voltageMedian = Statistics.median(rawVoltage.compactMap(\.voltageVolts))
        // One reading far from the rest is almost always a bad sample. It stays on the chart as
        // a dot, unconnected, instead of being deleted or drawn as a real collapse.
        let isOutlier: (HistoryInsights.ChargingCurvePoint) -> Bool = { point in
            guard let volts = point.voltageVolts, let median = voltageMedian else { return false }
            return volts < median * 0.5
        }
        let voltageLine = rawVoltage.filter { !isOutlier($0) }
        let voltageOutliers = rawVoltage.filter(isOutlier)
        let voltageSegments = segmentIndex(voltageLine, gapThreshold)

        let first = curve.first?.timestamp ?? Date()
        let last = max(curve.last?.timestamp ?? first, first.addingTimeInterval(60))
        let domain = first...last
        let peak = powerCurve.compactMap(\.powerKw).max() ?? 0
        let hasPower = peak > 0
        let hasCurrent = currentCurve.contains { ($0.currentAmps ?? 0) > 0 }
        let hasVoltage = !voltageLine.isEmpty
        let priceSlots = prices?.slots ?? []
        let hasPrice = !priceSlots.isEmpty
        let pausedBands = hasPower ? pausedIntervals(powerCurve, gapThreshold) : []
        let band = showsTenToEighty ? tenToEightyInterval() : nil
        let gaps = zip(curve, curve.dropFirst()).filter { $1.timestamp.timeIntervalSince($0.timestamp) > gapThreshold }
        let hit = scrub.flatMap { HistoryInsights.nearest(to: $0, in: curve, timestamp: \.timestamp) }

        VStack(alignment: .leading, spacing: 6) {
            socChart(segments: socSegments, domain: domain, gaps: gaps.map { ($0.0.timestamp, $0.1.timestamp) },
                     band: band, hit: hit, showsLabels: !hasPower && !hasPrice && !hasCurrent && !hasVoltage)
            if hasPower {
                powerChart(points: powerCurve, segments: powerSegments, domain: domain, peak: peak,
                           paused: pausedBands, hit: hit, showsLabels: !hasPrice && !hasCurrent && !hasVoltage)
                if !pausedBands.isEmpty || !chargerPower.isEmpty {
                    HStack(spacing: 10) {
                        if !chargerPower.isEmpty {
                            HistoryChartLegendItem(color: HistoryChartColor.power, label: L10n.text("Car"))
                            HistoryChartLegendItem(color: HisingenTheme.ink, label: L10n.text("Charger"), dashed: true)
                        }
                        if !pausedBands.isEmpty {
                            HistoryChartLegendItem(color: HisingenTheme.inkMuted.opacity(0.35),
                                                   label: L10n.text("Paused"), band: true)
                        }
                        Spacer()
                    }
                }
            }
            if let prices, hasPrice {
                priceChart(prices, domain: domain, hit: hit, showsLabels: !hasCurrent && !hasVoltage)
            }
            if hasCurrent {
                currentChart(points: currentCurve, segments: currentSegments, domain: domain, hit: hit,
                             showsLabels: !hasVoltage)
            }
            if hasVoltage {
                voltageChart(line: voltageLine, outliers: voltageOutliers, segments: voltageSegments,
                             domain: domain, hit: hit)
            }
        }
    }

    // MARK: Charts

    private func socChart(segments: [Int64: Int], domain: ClosedRange<Date>, gaps: [(Date, Date)],
                          band: ClosedRange<Date>?, hit: HistoryInsights.ChargingCurvePoint?,
                          showsLabels: Bool) -> some View {
        Chart {
            ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
                shade(from: gap.0, to: gap.1, label: levelLabel, bottom: 0.0, top: 100.0,
                     fill: HisingenTheme.inkMuted.opacity(0.14))
            }
            if let band {
                shade(from: band.lowerBound, to: band.upperBound, label: levelLabel, bottom: 0.0, top: 100.0,
                     fill: HisingenTheme.ink.opacity(0.06), caption: "10→80%")
            }
            ForEach(curve) { point in
                series(point, label: levelLabel, value: point.soc, segment: segments[point.id] ?? 0,
                       color: HistoryChartColor.chargeLevel, stroke: StrokeStyle(lineWidth: 1.6), filled: true)
            }
            if let targetSoc, (1...100).contains(targetSoc) {
                reference(value: targetSoc, label: L10n.text("Target"),
                          text: L10n.format("Target %d%%", Int(targetSoc.rounded())))
            }
            cursor(hit, topLine: true)
        }
        .chartXScale(domain: domain)
        .chartXSelection(value: $scrub)
        .chartYScale(domain: 0...100)
        .historyTimeAxis(domain: domain, showsLabels: showsLabels)
        .historyYAxis("%", values: .stride(by: 25.0), labelWidth: labelWidth)
        .frame(height: chartHeight)
        .accessibilityLabel(L10n.text("Charging curve charge-level chart"))
        .accessibilityValue(chartAccessibilityValue(points: curve.map(\.soc)))
        .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
            title: L10n.text("Charge level"), yLabel: "%",
            points: curve.map { ($0.timestamp, $0.soc) },
            valueFormat: { String(format: "%.0f", locale: L10n.displayLocale, $0) }))
        .hisAnimation(Motion.progress, value: animationKey)
    }

    private func powerChart(points: [HistoryInsights.ChargingCurvePoint], segments: [Int64: Int],
                            domain: ClosedRange<Date>, peak: Double, paused: [(Date, Date)],
                            hit: HistoryInsights.ChargingCurvePoint?, showsLabels: Bool) -> some View {
        Chart {
            ForEach(Array(paused.enumerated()), id: \.offset) { _, interval in
                shade(from: interval.0, to: interval.1, label: powerLabel, bottom: 0.0, top: peak * 1.1,
                     fill: HisingenTheme.inkMuted.opacity(0.18))
            }
            ForEach(points) { point in
                series(point, label: powerLabel, value: point.powerKw ?? 0, segment: segments[point.id] ?? 0,
                       color: HistoryChartColor.power, stroke: StrokeStyle(lineWidth: 1.4), filled: true)
            }
            ForEach(Array(HistoryInsights.segments(of: chargerPower, maxGap: 10 * 60, timestamp: { $0.0 }).enumerated()), id: \.offset) { index, run in
                ForEach(Array(run.enumerated()), id: \.offset) { _, sample in
                    LineMark(x: .value(timeLabel, sample.0), y: .value(powerLabel, sample.1),
                             series: .value(segmentLabel, "charger-\(index)"))
                        .foregroundStyle(HisingenTheme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                        .interpolationMethod(.stepEnd)
                }
            }
            if let averagePowerKw, averagePowerKw > 0 {
                reference(value: averagePowerKw, label: powerLabel,
                          text: "\(L10n.text("Average")) \(Format.powerKw(averagePowerKw))")
            }
            cursor(hit, topLine: false)
        }
        .chartXScale(domain: domain)
        .chartXSelection(value: $scrub)
        .chartYScale(domain: 0...max(max(peak, chargerPower.map(\.1).max() ?? 0) * 1.25, 1))
        .historyTimeAxis(domain: domain, showsLabels: showsLabels)
        .historyYAxis("kW", labelWidth: labelWidth)
        .frame(height: chartHeight * 0.7)
        .accessibilityLabel(L10n.text("Charging curve power chart"))
        .accessibilityValue(chartAccessibilityValue(points: points.map { $0.powerKw ?? 0 }))
        .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
            title: L10n.text("Power"), yLabel: "kW",
            points: points.map { ($0.timestamp, $0.powerKw ?? 0) }))
        .hisAnimation(Motion.progress, value: animationKey)
    }

    /// Each slot's price as a stepped line, since a price holds for its whole slot. The dashed line
    /// is the average weighted by the energy that flowed in each slot: what the charge cost per kWh.
    private func priceChart(_ series: SessionPriceSeries, domain: ClosedRange<Date>,
                            hit: HistoryInsights.ChargingCurvePoint?, showsLabels: Bool) -> some View {
        let slots = series.slots
        let steps = priceSteps(slots, domain: domain)
        let top = slots.map(\.pricePerKwh).max() ?? 0
        let bottom = min(0, slots.map(\.pricePerKwh).min() ?? 0)
        let average = series.energyWeightedAverage(power: pricingPower, until: domain.upperBound)
        let unit = "\(currencySymbol)/kWh"
        return VStack(alignment: .leading, spacing: 3) {
            Chart {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    LineMark(x: .value(timeLabel, step.0), y: .value(priceLabel, step.1),
                             series: .value(segmentLabel, "price"))
                        .foregroundStyle(HisingenTheme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                        .interpolationMethod(.stepEnd)
                }
                if let average {
                    reference(value: average, label: priceLabel,
                              text: "\(L10n.text("Average")) \(Format.currency(average, symbol: unit))")
                }
                cursor(hit, topLine: false)
            }
            .chartXScale(domain: domain)
            .chartXSelection(value: $scrub)
            .chartYScale(domain: bottom...max(top * 1.25, 0.1))
            .historyTimeAxis(domain: domain, showsLabels: showsLabels)
            .historyYAxis(unit, values: .automatic(desiredCount: 3), labelWidth: labelWidth)
            .frame(height: chartHeight * 0.5)
            .accessibilityLabel("\(L10n.text("Charging Curve")): \(L10n.text("Price"))")
            .accessibilityValue(chartAccessibilityValue(points: slots.map(\.pricePerKwh)))
            .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                title: L10n.text("Price"), yLabel: unit,
                points: slots.map { ($0.start, $0.pricePerKwh) },
                valueFormat: { Format.number($0, decimals: 2) }))
            .hisAnimation(Motion.progress, value: animationKey)
            Text(priceBasisNote(series.basis))
                .hisType(.micro).foregroundStyle(HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The charger's own power when it reported, else the car's: what the energy weighting uses.
    private var pricingPower: [(Date, Double)] {
        chargerPower.isEmpty ? curve.compactMap { point in point.powerKw.map { (point.timestamp, $0) } } : chargerPower
    }

    /// Slot starts clamped to the chart, plus a closing point so the last slot draws to its end.
    private func priceSteps(_ slots: [HomePricePoint], domain: ClosedRange<Date>) -> [(Date, Double)] {
        var steps = slots.map { (max($0.start, domain.lowerBound), $0.pricePerKwh) }
        if let last = slots.last { steps.append((min(last.end, domain.upperBound), last.pricePerKwh)) }
        return steps
    }

    private func priceBasisNote(_ basis: SessionPriceSeries.Basis) -> String {
        switch basis {
        case .tibberWithGridFee: return L10n.text("Tibber's price per 15 minutes with the grid transfer fee added.")
        case .spotWithRates: return L10n.text("Spot price with the markup, other charges and VAT from your rate settings.")
        case .spot: return L10n.text("Spot price only. Taxes and grid fees are not included.")
        }
    }

    private func currentChart(points: [HistoryInsights.ChargingCurvePoint], segments: [Int64: Int],
                              domain: ClosedRange<Date>, hit: HistoryInsights.ChargingCurvePoint?,
                              showsLabels: Bool) -> some View {
        let top = points.compactMap(\.currentAmps).max() ?? 0
        return Chart {
            ForEach(points) { point in
                series(point, label: currentLabel, value: point.currentAmps ?? 0, segment: segments[point.id] ?? 0,
                       color: HistoryChartColor.current,
                       stroke: chartSeriesStroke(index: 1, differentiateWithoutColor: differentiateWithoutColor, width: 1.4),
                       filled: false)
            }
            cursor(hit, topLine: false)
        }
        .chartXScale(domain: domain)
        .chartXSelection(value: $scrub)
        .chartYScale(domain: 0...max(top * 1.25, 1))
        .historyTimeAxis(domain: domain, showsLabels: showsLabels)
        .historyYAxis("A", values: .automatic(desiredCount: 3), labelWidth: labelWidth)
        .frame(height: chartHeight * 0.5)
        .accessibilityLabel("\(L10n.text("Charging Curve")): \(L10n.text("Current"))")
        .accessibilityValue(chartAccessibilityValue(points: points.map { $0.currentAmps ?? 0 }))
        .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
            title: L10n.text("Current"), yLabel: "A",
            points: points.map { ($0.timestamp, $0.currentAmps ?? 0) }))
        .hisAnimation(Motion.progress, value: animationKey)
    }

    private func voltageChart(line: [HistoryInsights.ChargingCurvePoint],
                              outliers: [HistoryInsights.ChargingCurvePoint], segments: [Int64: Int],
                              domain: ClosedRange<Date>, hit: HistoryInsights.ChargingCurvePoint?) -> some View {
        let volts = line.compactMap(\.voltageVolts)
        let low = volts.min() ?? 0
        let high = volts.max() ?? 1
        let pad = max(5, (high - low) * 0.25)
        let voltRange = (low - pad)...(high + pad)
        return Chart {
            ForEach(line) { point in
                series(point, label: voltageLabel, value: point.voltageVolts ?? 0, segment: segments[point.id] ?? 0,
                       color: HistoryChartColor.voltage, stroke: StrokeStyle(lineWidth: 1.4), filled: false)
            }
            // A reading far outside the rest keeps its real value in the label and sits on the
            // floor of the plot, so it neither vanishes nor squashes the axis for every other sample.
            ForEach(outliers) { point in
                PointMark(x: .value(L10n.text("Time"), point.timestamp),
                          y: .value(L10n.text("Voltage"), max(point.voltageVolts ?? 0, voltRange.lowerBound)))
                    .symbolSize(16)
                    .foregroundStyle(HistoryChartColor.voltage)
                    .annotation(position: .top, spacing: 1) {
                        Text(Format.number(point.voltageVolts ?? 0, decimals: 0) + " V")
                            .hisType(.micro).foregroundStyle(HisingenTheme.inkMuted)
                    }
            }
            cursor(hit, topLine: false)
        }
        .chartXScale(domain: domain)
        .chartXSelection(value: $scrub)
        .chartYScale(domain: voltRange)
        .historyTimeAxis(domain: domain)
        .historyYAxis("V", values: .automatic(desiredCount: 3), labelWidth: labelWidth)
        .frame(height: chartHeight * 0.5)
        .accessibilityLabel("\(L10n.text("Charging Curve")): \(L10n.text("Voltage"))")
        .accessibilityValue(chartAccessibilityValue(points: (line + outliers).map { $0.voltageVolts ?? 0 }))
        .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
            title: L10n.text("Voltage"), yLabel: "V",
            points: (line + outliers).map { ($0.timestamp, $0.voltageVolts ?? 0) }))
        .hisAnimation(Motion.progress, value: animationKey)
    }

    // MARK: Scrub cursor

    /// The cursor line runs through every chart; only the top chart carries the callout, with
    /// every reading at that sample.
    @ChartContentBuilder
    private func cursor(_ hit: HistoryInsights.ChargingCurvePoint?, topLine: Bool) -> some ChartContent {
        if let hit {
            if topLine {
                RuleMark(x: .value(L10n.text("Time"), hit.timestamp))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(callout(for: hit)).historyScrubCallout()
                    }
            } else {
                RuleMark(x: .value(L10n.text("Time"), hit.timestamp))
                    .foregroundStyle(Color.primary.opacity(0.25))
            }
        }
    }

    private func callout(for point: HistoryInsights.ChargingCurvePoint) -> String {
        var parts = [
            point.timestamp.formatted(Date.FormatStyle().locale(L10n.clockLocale).hour().minute()),
            Format.percent(point.soc)
        ]
        if let power = point.powerKw { parts.append(Format.powerKw(power)) }
        if let price = prices?.price(at: point.timestamp) {
            parts.append(Format.currency(price, symbol: "\(currencySymbol)/kWh"))
        }
        if let amps = point.currentAmps { parts.append(Format.number(amps, decimals: 1) + " A") }
        if let volts = point.voltageVolts { parts.append(Format.number(volts, decimals: 0) + " V") }
        return parts.joined(separator: " · ")
    }

    // MARK: Derived series

    private func segmentIndex(_ points: [HistoryInsights.ChargingCurvePoint], _ gap: TimeInterval) -> [Int64: Int] {
        var result: [Int64: Int] = [:]
        for (index, run) in HistoryInsights.segments(of: points, maxGap: gap, timestamp: { $0.timestamp }).enumerated() {
            for point in run { result[point.id] = index }
        }
        return result
    }

    /// Stretches where the car reported zero power while plugged in, each ending at the next
    /// sample, as long as no observation gap hides what happened in between.
    private func pausedIntervals(_ points: [HistoryInsights.ChargingCurvePoint], _ gap: TimeInterval) -> [(Date, Date)] {
        zip(points, points.dropFirst()).compactMap { a, b in
            guard (a.powerKw ?? 1) <= 0, b.timestamp.timeIntervalSince(a.timestamp) <= gap else { return nil }
            return (a.timestamp, b.timestamp)
        }
    }

    /// The time the pack was first reported at 10% and first reported at 80%.
    private func tenToEightyInterval() -> ClosedRange<Date>? {
        guard let start = curve.first(where: { $0.soc >= 10 })?.timestamp,
              let end = curve.first(where: { $0.soc >= 80 })?.timestamp, end > start else { return nil }
        return start...end
    }
}

// MARK: - Shared mark builders

extension SessionCurveCharts {
    fileprivate var timeLabel: String { L10n.text("Time") }
    fileprivate var segmentLabel: String { L10n.text("Segment") }
    fileprivate var levelLabel: String { L10n.text("Charge level") }
    fileprivate var powerLabel: String { L10n.text("Power") }
    fileprivate var priceLabel: String { L10n.text("Price") }
    fileprivate var currentLabel: String { L10n.text("Current") }
    fileprivate var voltageLabel: String { L10n.text("Voltage") }

    /// One stepped series: an optional faint fill under a line. Split into its own builder so
    /// the four charts share one definition of "a curve" and the compiler can type-check each.
    @ChartContentBuilder
    fileprivate func series(_ point: HistoryInsights.ChargingCurvePoint, label: String, value: Double,
                            segment: Int, color: Color, stroke: StrokeStyle, filled: Bool) -> some ChartContent {
        if filled {
            AreaMark(x: .value(timeLabel, point.timestamp), y: .value(label, value),
                     series: .value(segmentLabel, segment))
                .foregroundStyle(color.opacity(0.16))
                .interpolationMethod(.stepEnd)
        }
        LineMark(x: .value(timeLabel, point.timestamp), y: .value(label, value),
                 series: .value(segmentLabel, segment))
            .foregroundStyle(color)
            .lineStyle(stroke)
            .interpolationMethod(.stepEnd)
    }
}

extension SessionCurveCharts {
    /// A shaded stretch of time over a value range: an observation gap, the 10 to 80% span, or a
    /// pause in power.
    @ChartContentBuilder
    fileprivate func shade(from start: Date, to end: Date, label: String, bottom: Double, top: Double,
                          fill: Color, caption: String? = nil) -> some ChartContent {
        RectangleMark(xStart: .value(timeLabel, start), xEnd: .value(timeLabel, end),
                      yStart: .value(label, bottom), yEnd: .value(label, top))
            .foregroundStyle(fill)
            .annotation(position: .top, alignment: .leading, spacing: 2) {
                if let caption {
                    Text(caption).hisType(.micro).foregroundStyle(HisingenTheme.inkMuted)
                }
            }
    }

    /// A dashed horizontal reference line with a short label at its trailing end.
    @ChartContentBuilder
    fileprivate func reference(value: Double, label: String, text: String) -> some ChartContent {
        RuleMark(y: .value(label, value))
            .foregroundStyle(HisingenTheme.inkMuted)
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .annotation(position: .top, alignment: .trailing, spacing: 1) {
                Text(text).hisType(.micro).foregroundStyle(HisingenTheme.inkMuted)
            }
    }
}
