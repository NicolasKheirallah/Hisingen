import SwiftUI

extension HistoryDashboardView {
    /// Log (2026-11-16 redesign): the period as one sentence, then the energy trace.
    ///
    /// The trace is the energy line stretched over time, drawn only from what was recorded:
    /// each charging session rises as a solid segment from its start to its end level, and a
    /// dotted line joins one charge to the next, labelled with the distance driven in between.
    /// Hisingen does not store the battery level while driving, so the dotted stretch is not
    /// shaped to look like a discharge curve.
    var awardHistoryOverview: some View {
        let totalDistance = aggregateTrips.reduce(0) { $0 + $1.distanceKm }
        let drivingTime = aggregateTrips.reduce(0) { $0 + $1.duration }
        let energy = chargingSessions.reduce(0) { $0 + $1.energyDeliveredKwh }
        let cost = aggregateChargingCost()
        let condensed = HisingenTheme.layoutWidth < 600

        var facts: [String] = [
            L10n.format("%d trips", aggregateTrips.count),
            L10n.format("%@ driving", Format.shortDuration(minutes: Int(drivingTime / 60)))
        ]
        if energy > 0 { facts.append(Format.energyKwh(energy)) }
        if let cost {
            facts.append("\(Format.currency(cost.amount, symbol: cost.currency)) \(L10n.text("(estimated)"))")
        }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.format("%@ · %@",
                                     Format.distance(km: totalDistance, decimals: 0, unit: preferences.distanceUnit),
                                     L10n.text(period.rawValue)))
                        .hisType(size: condensed ? 26 : 32, relativeTo: .largeTitle, weight: .light)
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(facts.joined(separator: " · "))
                        .hisType(.label)
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
                Spacer()
                exportMenu
            }

            EnergyTrace(
                sessions: chargingSessions,
                trips: aggregateTrips,
                window: activeRange,
                currentLevel: state.energy.batteryPercentage,
                distanceUnit: preferences.distanceUnit
            )
        }
        .padding(.horizontal, condensed ? 16 : 24)
        .padding(.vertical, condensed ? 12 : 18)
    }
}

/// The energy line over time. See ``HistoryDashboardView/awardHistoryOverview``.
@MainActor
struct EnergyTrace: View {
    let sessions: [HistoricalChargingSession]
    let trips: [TripHistoryEntry]
    let window: ClosedRange<Date>?
    let currentLevel: Double?
    let distanceUnit: DistanceUnit

    private let plotHeight: CGFloat = 118

    struct Charge: Identifiable {
        let id: String
        let start: Date
        let end: Date
        let from: Double
        let to: Double
    }

    /// Completed sessions with both levels, oldest first, clipped to the window.
    static func charges(_ sessions: [HistoricalChargingSession], in window: ClosedRange<Date>?) -> [Charge] {
        sessions.compactMap { session -> Charge? in
            guard let end = session.endedAt, let to = session.endSoc else { return nil }
            if let window, end < window.lowerBound || session.startedAt > window.upperBound { return nil }
            return Charge(id: session.id, start: session.startedAt, end: end, from: session.startSoc, to: to)
        }
        .sorted { $0.start < $1.start }
    }

    var body: some View {
        let charges = Self.charges(sessions, in: window)
        let now = Date()
        let lower = window?.lowerBound ?? charges.first?.start ?? now.addingTimeInterval(-7 * 86_400)
        let upper = max(window?.upperBound ?? now, now)
        VStack(alignment: .leading, spacing: 6) {
            if charges.isEmpty {
                Text(L10n.text("No charging sessions in this period."))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .frame(maxWidth: .infinity, minHeight: plotHeight / 2, alignment: .leading)
            } else {
                GeometryReader { proxy in
                    let size = CGSize(width: proxy.size.width - 30, height: plotHeight)
                    ZStack(alignment: .topLeading) {
                        grid(size)
                        tracePaths(charges, lower: lower, upper: upper, now: now, size: size)
                        gapLabels(charges, lower: lower, upper: upper, size: size)
                        axisLabels(size)
                    }
                }
                .frame(height: plotHeight)
                HStack {
                    Text(Format.dateFormatter.string(from: lower))
                    Spacer()
                    Text(L10n.text("Now"))
                }
                .hisType(.micro)
                .foregroundStyle(HisingenTheme.inkMuted)
                .padding(.trailing, 30)
                Text(L10n.text("Solid: charging. Dotted: driving between charges."))
                    .hisType(.micro)
                    .foregroundStyle(HisingenTheme.inkMuted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Battery"))
        .accessibilityValue(accessibilitySummary(charges))
    }

    private func x(_ date: Date, lower: Date, upper: Date, width: CGFloat) -> CGFloat {
        let span = max(upper.timeIntervalSince(lower), 1)
        return CGFloat(min(max(date.timeIntervalSince(lower) / span, 0), 1)) * width
    }

    private func y(_ level: Double, height: CGFloat) -> CGFloat {
        height - CGFloat(min(max(level, 0), 100) / 100) * height
    }

    private func grid(_ size: CGSize) -> some View {
        Path { path in
            for level in [0.0, 50.0, 100.0] {
                let yy = y(level, height: size.height)
                path.move(to: CGPoint(x: 0, y: yy))
                path.addLine(to: CGPoint(x: size.width, y: yy))
            }
        }
        .stroke(HisingenTheme.hairline, lineWidth: 1)
    }

    private func tracePaths(_ charges: [Charge], lower: Date, upper: Date, now: Date, size: CGSize) -> some View {
        let point: (Date, Double) -> CGPoint = { date, level in
            CGPoint(x: x(date, lower: lower, upper: upper, width: size.width), y: y(level, height: size.height))
        }
        return ZStack(alignment: .topLeading) {
            Path { path in
                for (index, charge) in charges.enumerated() where index > 0 {
                    let previous = charges[index - 1]
                    path.move(to: point(previous.end, previous.to))
                    path.addLine(to: point(charge.start, charge.from))
                }
                if let last = charges.last, let currentLevel {
                    path.move(to: point(last.end, last.to))
                    path.addLine(to: point(now, currentLevel))
                }
            }
            .stroke(HisingenTheme.inkMuted, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 4]))

            Path { path in
                for charge in charges {
                    path.move(to: point(charge.start, charge.from))
                    path.addLine(to: point(charge.end, charge.to))
                }
            }
            .stroke(HisingenTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))

            if let currentLevel {
                Circle()
                    .fill(HisingenTheme.accent)
                    .frame(width: 8, height: 8)
                    .position(point(now, currentLevel))
            }
        }
    }

    /// The distance driven between two charges, written over the dotted stretch when there is
    /// room for it. Summed from recorded trips only.
    private func gapLabels(_ charges: [Charge], lower: Date, upper: Date, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(charges.enumerated()), id: \.element.id) { index, charge in
                if index > 0 {
                    let previous = charges[index - 1]
                    let driven = trips
                        .filter { $0.startedAt >= previous.end && $0.endedAt <= charge.start }
                        .reduce(0) { $0 + $1.distanceKm }
                    let x0 = x(previous.end, lower: lower, upper: upper, width: size.width)
                    let x1 = x(charge.start, lower: lower, upper: upper, width: size.width)
                    if driven >= 1, x1 - x0 >= 46 {
                        Text(Format.distance(km: driven, decimals: 0, unit: distanceUnit))
                            .hisType(.micro, weight: .medium)
                            .monospacedDigit()
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .fixedSize()
                            .position(x: (x0 + x1) / 2,
                                      y: max(10, (y(previous.to, height: size.height) + y(charge.from, height: size.height)) / 2 - 10))
                    }
                }
            }
        }
    }

    private func axisLabels(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach([100, 50, 0], id: \.self) { level in
                Text("\(level)%")
                    .hisType(.nano, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize()
                    .position(x: size.width + 16, y: y(Double(level), height: size.height))
            }
        }
    }

    private func accessibilitySummary(_ charges: [Charge]) -> String {
        guard let first = charges.first, let last = charges.last else {
            return L10n.text("No charging sessions in this period.")
        }
        let lowest = charges.map(\.from).min() ?? first.from
        return L10n.format("%d charges, lowest start %@, last ended at %@",
                           charges.count,
                           String(format: "%.0f%%", locale: L10n.displayLocale, lowest),
                           String(format: "%.0f%%", locale: L10n.displayLocale, last.to))
    }
}
