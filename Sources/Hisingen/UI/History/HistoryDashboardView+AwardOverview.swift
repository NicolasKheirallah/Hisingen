import Charts
import SwiftUI

extension HistoryDashboardView {
    var awardHistoryOverview: some View {
        let totalDistance = aggregateTrips.reduce(0) { $0 + $1.distanceKm }
        let drivingTime = aggregateTrips.reduce(0) { $0 + $1.duration }
        let energy = chargingSessions.reduce(0) { $0 + $1.energyDeliveredKwh }
        let cost = aggregateChargingCost()

        var facts: [String] = []
        if !aggregateTrips.isEmpty {
            facts.append(L10n.format("%d trips", aggregateTrips.count))
            facts.append(L10n.format("%@ driving", Format.shortDuration(minutes: Int(drivingTime / 60))))
        }
        if !showsChargingSummary, energy > 0, !aggregateTrips.isEmpty { facts.append(Format.energyKwh(energy)) }
        if !showsChargingSummary, let cost {
            facts.append("\(Format.currency(cost.amount, symbol: cost.currency)) \(L10n.text("(estimated)"))")
        }

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(period.rawValue))
                        .hisType(.subhead)
                        .foregroundStyle(HisingenTheme.inkMuted)
                    if !aggregateTrips.isEmpty || energy > 0 {
                        Text(aggregateTrips.isEmpty ? Format.energyKwh(energy)
                             : Format.distance(km: totalDistance, decimals: 0, unit: preferences.distanceUnit))
                            .hisType(.displayLarge)
                            .monospacedDigit()
                            .foregroundStyle(HisingenTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if aggregateTrips.isEmpty && energy > 0 {
                        Text(L10n.text("Estimated Energy"))
                            .hisType(.label)
                            .foregroundStyle(HisingenTheme.inkMuted)
                    }
                    if !facts.isEmpty {
                        Text(facts.joined(separator: " · "))
                            .hisType(.label)
                            .monospacedDigit()
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if !showsHistoryExportHeader { exportMenu }
            }

            if state.powertrain.hasElectricRange || !chargingSessions.isEmpty {
                PanelRule()
                EnergyTrace(sessions: chargingSessions, window: activeRange)
            }
            recordingCoverageSection
        }
        .padding(.horizontal, HisingenTheme.cardPadding)
        .padding(.vertical, 10)
    }
}

struct EnergyTrace: View {
    let sessions: [HistoricalChargingSession]
    let window: ClosedRange<Date>?
    @ScaledMetric(relativeTo: .caption) private var plotHeight: CGFloat = 154

    struct Charge: Identifiable {
        let id: String
        let start: Date
        let end: Date
        let from: Double
        let to: Double
    }

    static func charges(_ sessions: [HistoricalChargingSession], in window: ClosedRange<Date>?) -> [Charge] {
        sessions.compactMap { session -> Charge? in
            guard let end = session.endedAt, let to = session.endSoc, end >= session.startedAt,
                  (0...100).contains(session.startSoc), (0...100).contains(to) else { return nil }
            if let window, !window.contains(session.startedAt) || !window.contains(end) { return nil }
            return Charge(id: session.id, start: session.startedAt, end: end, from: session.startSoc, to: to)
        }
        .sorted { $0.start < $1.start }
    }

    var body: some View {
        let charges = Self.charges(sessions, in: window)
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.text("Charge level"))
                .hisType(.subhead, weight: .medium)
                .foregroundStyle(HisingenTheme.ink)
                .accessibilityAddTraits(.isHeader)
            if let first = charges.first, let latest = charges.max(by: { $0.end < $1.end }) {
                let lower = window?.lowerBound ?? first.start
                let upper = max(window?.upperBound ?? latest.end, lower.addingTimeInterval(5 * 60))
                chart(charges, lower: lower, upper: upper)
                chartFooter(latest: latest)
            } else {
                Text(L10n.text(sessions.isEmpty ? "No charging sessions in this period." : "No complete charge readings in this period."))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Charge-level range of the plot. A trace whose charges all sit between 40 and 80% used to
    /// spend half its height on empty 0-40 and 80-100; a trace that spans most of the range keeps
    /// the full 0-100 ruling.
    private func levelDomain(_ charges: [Charge]) -> ClosedRange<Double> {
        guard let low = charges.map({ min($0.from, $0.to) }).min(),
              let high = charges.map({ max($0.from, $0.to) }).max(), high - low < 60 else { return 0...100 }
        var lower = max(0, (low - 5) / 10).rounded(.down) * 10
        var upper = min(100, ((high + 5) / 10).rounded(.up) * 10)
        if upper - lower < 20 { lower = max(0, upper - 20); upper = lower + 20 }
        return lower...min(100, upper)
    }

    private func chart(_ charges: [Charge], lower: Date, upper: Date) -> some View {
        let span = upper.timeIntervalSince(lower)
        let tickFormat = HistoryTimeAxis.format(span: span)
        let levels = levelDomain(charges)
        let yValues: AxisMarkValues = levels == 0...100 ? .stride(by: 25.0) : .automatic(desiredCount: 4)

        return Chart(charges) { charge in
            sessionMarks(charge)
        }
        .chartXScale(domain: lower...upper, range: .plotDimension(startPadding: 6, endPadding: 6))
        .chartYScale(domain: levels, range: .plotDimension(startPadding: 6, endPadding: 6))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisTick().foregroundStyle(HisingenTheme.hairline)
                if let date = value.as(Date.self) {
                    let fraction = date.timeIntervalSince(lower) / span
                    let anchor: UnitPoint = fraction < 0.12 ? .topLeading : fraction > 0.88 ? .topTrailing : .top
                    AxisValueLabel(centered: false, anchor: anchor, collisionResolution: .greedy) {
                        Text(date.formatted(tickFormat))
                            .hisType(.label)
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: yValues) { value in
                AxisGridLine().foregroundStyle(HisingenTheme.hairline)
                AxisValueLabel {
                    if let level = value.as(Double.self) {
                        Text(Format.percent(level))
                            .hisType(.label)
                            .monospacedDigit()
                            .foregroundStyle(HisingenTheme.inkMuted)
                    }
                }
            }
        }
        .frame(height: plotHeight)
        .accessibilityLabel(L10n.text("Battery at the start and end of each charge."))
        .accessibilityValue(accessibilitySummary(charges))
    }

    /// One charge, drawn from where it started to where it ended, so a charge with duration
    /// leans across the time axis instead of standing as a vertical tick at its end. Over a long
    /// window the lean is under a pixel and it reads as the tick it always was.
    @ChartContentBuilder
    private func sessionMarks(_ charge: Charge) -> some ChartContent {
        let startTime = PlottableValue.value(L10n.text("Start"), charge.start)
        let endTime = PlottableValue.value(L10n.text("Ended"), charge.end)
        let start = PlottableValue.value(L10n.text("Start"), charge.from)
        let end = PlottableValue.value(L10n.text("End"), charge.to)
        LineMark(x: startTime, y: start, series: .value(L10n.text("Session"), charge.id))
            .foregroundStyle(HisingenTheme.accent)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .accessibilityHidden(true)
        LineMark(x: endTime, y: end, series: .value(L10n.text("Session"), charge.id))
            .foregroundStyle(HisingenTheme.accent)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .accessibilityLabel(Text(Format.dateTimeFormatter.string(from: charge.end)))
            .accessibilityValue(Text(chargeRange(charge)))
        PointMark(x: startTime, y: start)
            .symbol { startMarker }
            .accessibilityHidden(true)
        PointMark(x: endTime, y: end)
            .symbol { endMarker }
            .accessibilityHidden(true)
    }

    private var startMarker: some View {
        Rectangle()
            .fill(HisingenTheme.canvas)
            .overlay(Rectangle().strokeBorder(HisingenTheme.inkMuted, lineWidth: 1))
            .frame(width: 6, height: 6)
    }

    private var endMarker: some View {
        Rectangle()
            .fill(HisingenTheme.accent)
            .frame(width: 6, height: 6)
    }

    private func chartFooter(latest: Charge) -> some View {
        let legend = HStack(spacing: 16) {
            Label { Text(L10n.text("Start")) } icon: { startMarker }
            Label { Text(L10n.text("End")) } icon: { endMarker }
        }
        .accessibilityHidden(true)
        let last = Text(L10n.format("%@ · %@", L10n.text("Last Charge"), chargeRange(latest)))
            .monospacedDigit()

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                legend
                Spacer(minLength: 12)
                last
            }
            VStack(alignment: .leading, spacing: 6) {
                legend
                last
            }
        }
        .hisType(.label)
        .foregroundStyle(HisingenTheme.inkMuted)
    }

    private func chargeRange(_ charge: Charge) -> String {
        L10n.format("%@ to %@", Format.percent(charge.from), Format.percent(charge.to))
    }

    private func accessibilitySummary(_ charges: [Charge]) -> String {
        guard let lowest = charges.map(\.from).min(), let last = charges.max(by: { $0.end < $1.end }) else { return "" }
        return L10n.format("%d charges, lowest start %@, last ended at %@",
                           charges.count,
                           Format.percent(lowest), Format.percent(last.to))
    }
}
