import Charts
import SwiftUI

// `HistoryDashboardView` — charging cards: the selected-session curve, the sessions list,
// charging-by-month, the per-location breakdown, and the aggregate trends card.

extension HistoryDashboardView {
    // MARK: - Charging curve

    var chargingCurveCard: some View {
        let session = selectedSession
        let curve = selectedSessionCurve
        let samples = selectedSessionSamples
        let peak = curve.compactMap(\.powerKw).max()
        let socGain = (curve.last?.soc ?? 0) - (curve.first?.soc ?? 0)
        let durationMinutes = session.map { max(0, Int(($0.endedAt ?? Date()).timeIntervalSince($0.startedAt) / 60)) }
        let chargingType = HistoryInsights.chargingType(from: samples, peakPowerKw: peak)
        let tenToEighty = HistoryInsights.tenToEightyDuration(from: curve)
        let idleTail = HistoryInsights.idleTailDuration(from: curve)
        let lossPct: Double? = state.powertrain.hasElectricRange
            ? HistoryInsights.estimatedChargingLossPct(from: samples, packCapacityKwh: state.configuredUsableBatteryCapacityKwh)
            : nil
        let displayedCost = session.flatMap { stored in
            stored.estimatedCost
                ?? stored.tariffPricePerKwh.map { $0 * stored.energyDeliveredKwh }
                ?? (stored.summaryVersion < 2 ? preferences.electricityPricePerKwh * stored.energyDeliveredKwh : nil)
        }
        let tariffSplit = tariffSplitForSelectedSession()
        let isAnomalous = session.map { snapshot.anomalousSessionIDs.contains($0.id) } ?? false
        let curveGapCount = zip(curve, curve.dropFirst()).filter {
            $1.timestamp.timeIntervalSince($0.timestamp) > HistoryInsights.chargingCurveGapThreshold
        }.count
        let curveSegmentByID = gapSegmentIndex(of: curve, maxGap: HistoryInsights.chargingCurveGapThreshold, timestamp: \.timestamp)
        let powerCurve = curve.filter { $0.powerKw != nil }
        let powerSegmentByID = gapSegmentIndex(of: powerCurve, maxGap: HistoryInsights.chargingCurveGapThreshold, timestamp: \.timestamp)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "chart.dots.scatter", title: L10n.text("Charging Curve"), color: .green)
                    if selectedSession?.endedAt == nil {
                        HStack(spacing: 3) {
                            Circle().fill(HisingenTheme.chartPositive).frame(width: 5, height: 5)
                            Text(L10n.text("Live")).font(.system(size: 8.5, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .accessibilityLabel(L10n.text("Session in progress"))
                    }
                    if let badgeColor = chargingTypeBadgeColor(chargingType) {
                        Text(chargingType.displayName)
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(badgeColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(badgeColor)
                    }
                    Spacer()
                    Button {
                        selectedSessionID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("Close the charging curve"))
                    .accessibilityLabel(L10n.text("Close charging curve"))
                }
                if let session, let name = session.locationName, !name.isEmpty {
                    Label(name, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if isAnomalous {
                    footnote("exclamationmark.triangle.fill",
                             L10n.text("Peak power for this session was far below what this vehicle usually reaches here — possibly a failing cable or a derated charger."))
                        .foregroundStyle(HisingenTheme.semanticWarning)
                }
                if let session {
                    HStack(spacing: 5) {
                        Label("\(session.confidence.displayName) · \(session.energySource.displayName)", systemImage: "checkmark.seal")
                        if let coverage = session.sampleCoverage {
                            Text("· " + L10n.format("%d%% observed", Int((coverage * 100).rounded()))).monospacedDigit()
                        }
                        Spacer()
                        if curveGapCount > 0 {
                            Label(L10n.format("%d observation gaps", curveGapCount), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(HisingenTheme.semanticWarning)
                        }
                    }
                    .font(.system(size: 8.5, weight: .medium)).foregroundStyle(.secondary)
                }
                Chart(curve) { point in
                    AreaMark(
                        x: .value(L10n.text("Time"), point.timestamp),
                        y: .value(L10n.text("Charge level"), point.soc),
                        series: .value(L10n.text("Segment"), curveSegmentByID[point.id] ?? 0)
                    )
                    .foregroundStyle(.linearGradient(colors: [HisingenTheme.chartPositive.opacity(0.28), HisingenTheme.chartPositive.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.stepEnd)
                    LineMark(
                        x: .value(L10n.text("Time"), point.timestamp),
                        y: .value(L10n.text("Charge level"), point.soc),
                        series: .value(L10n.text("Segment"), curveSegmentByID[point.id] ?? 0)
                    )
                    .foregroundStyle(HisingenTheme.chartPositive)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.stepEnd)
                }
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("%")
                .frame(height: chartHeight)
                .accessibilityLabel(L10n.text("Charging curve charge-level chart"))
                if let peak, peak > 0 {
                    Chart(powerCurve) { point in
                        AreaMark(
                            x: .value(L10n.text("Time"), point.timestamp),
                            y: .value(L10n.text("Power"), point.powerKw ?? 0),
                            series: .value(L10n.text("Segment"), powerSegmentByID[point.id] ?? 0)
                        )
                        .foregroundStyle(.linearGradient(colors: [HisingenTheme.chartAttention.opacity(0.25), HisingenTheme.chartAttention.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.linear)
                        LineMark(
                            x: .value(L10n.text("Time"), point.timestamp),
                            y: .value(L10n.text("Power"), point.powerKw ?? 0),
                            series: .value(L10n.text("Segment"), powerSegmentByID[point.id] ?? 0)
                        )
                        .foregroundStyle(HisingenTheme.chartAttention)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                        .interpolationMethod(.linear)
                    }
                    .chartYAxisLabel("kW")
                    .frame(height: chartHeight * 0.72)
                    .accessibilityLabel(L10n.text("Charging curve power chart"))
                }
                if curve.contains(where: { $0.voltageVolts != nil || $0.currentAmps != nil }) {
                    Chart(curve) { point in
                        if let voltage = point.voltageVolts {
                            LineMark(
                                x: .value(L10n.text("Time"), point.timestamp),
                                y: .value(L10n.text("Voltage"), voltage),
                                series: .value(L10n.text("Segment"), "voltage-\(curveSegmentByID[point.id] ?? 0)")
                            )
                            .foregroundStyle(by: .value(L10n.text("Series"), L10n.text("Voltage (V)")))
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                            .interpolationMethod(.linear)
                        }
                        if let current = point.currentAmps {
                            LineMark(
                                x: .value(L10n.text("Time"), point.timestamp),
                                y: .value(L10n.text("Current"), current),
                                series: .value(L10n.text("Segment"), "current-\(curveSegmentByID[point.id] ?? 0)")
                            )
                            .foregroundStyle(by: .value(L10n.text("Series"), L10n.text("Current (A)")))
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                            .interpolationMethod(.linear)
                        }
                    }
                    .chartForegroundStyleScale([
                        L10n.text("Voltage (V)"): HisingenTheme.chartInfo,
                        L10n.text("Current (A)"): HisingenTheme.chartAttention
                    ])
                    .frame(height: chartHeight * 0.62)
                    .accessibilityLabel(L10n.text("Charging curve voltage and current chart"))
                }
                curveStatsRow(session: session, socGain: socGain, durationMinutes: durationMinutes, peak: peak)
                if tenToEighty != nil || idleTail != nil || lossPct != nil || displayedCost != nil {
                    HStack(spacing: 12) {
                        if let tenToEighty {
                            curveStat("10→80%", Format.shortDuration(minutes: max(1, Int(tenToEighty / 60))))
                        }
                        if let idleTail, idleTail >= 60 {
                            curveStat(L10n.text("Idle Tail"), Format.shortDuration(minutes: max(1, Int(idleTail / 60))))
                        }
                        if let lossPct, lossPct >= 1 {
                            curveStat(L10n.text("Estimated Loss"), Format.percent(lossPct))
                        }
                        if let displayedCost {
                            curveStat(L10n.text("Tariff Cost"),
                                      Format.currency(displayedCost, symbol: session?.currencySymbol ?? preferences.currencySymbol))
                        }
                    }
                }
                if let tariffSplit, tariffSplit.nightEnergyKwh > 0 {
                    HStack(spacing: 12) {
                        curveStat(L10n.text("Day Energy"), Format.energyKwh(tariffSplit.dayEnergyKwh))
                        curveStat(L10n.text("Night Energy"), Format.energyKwh(tariffSplit.nightEnergyKwh))
                        curveStat(L10n.text("Split Cost"),
                                  Format.currency(tariffSplit.cost, symbol: session?.currencySymbol ?? preferences.currencySymbol))
                    }
                }
                Toggle(isOn: $overlayPreviousSession) {
                    Text(L10n.text("Overlay previous session")).font(.system(size: 9.5))
                }
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .disabled(selectedSession.flatMap { session in
                    chargingSessions.firstIndex(where: { $0.id == session.id }).map { $0 + 1 >= chargingSessions.count }
                } ?? true)
                if overlayPreviousSession, !previousSessionCurve.isEmpty {
                    previousSessionOverlayChart
                }
                Text(L10n.text("Curves are drawn from locally recorded polls of vehicle telemetry, so resolution follows how often the vehicle reported while plugged in."))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                dataConfidenceNote(for: curve.map(\.timestamp))
            }
        }
    }

    var previousSessionOverlayChart: some View {
        // Both curves re-based to minutes-from-start so two sessions of different clock times
        // line up for shape comparison.
        func elapsed(_ points: [HistoryInsights.ChargingCurvePoint]) -> [(minutes: Double, soc: Double)] {
            guard let start = points.first?.timestamp else { return [] }
            return points.map { ($0.timestamp.timeIntervalSince(start) / 60, $0.soc) }
        }
        let current = elapsed(selectedSessionCurve)
        let previous = elapsed(previousSessionCurve)
        return Chart {
            ForEach(Array(previous.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value(L10n.text("Minutes"), point.minutes),
                         y: .value(L10n.text("Charge level"), point.soc),
                         series: .value(L10n.text("Session"), L10n.text("Previous")))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            }
            ForEach(Array(current.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value(L10n.text("Minutes"), point.minutes),
                         y: .value(L10n.text("Charge level"), point.soc),
                         series: .value(L10n.text("Session"), L10n.text("This session")))
                .foregroundStyle(HisingenTheme.chartPositive)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxisLabel(L10n.text("Minutes"))
        .chartYAxisLabel("%")
        .frame(height: chartHeight * 0.62)
        .accessibilityLabel(L10n.text("Charge level of this session versus the previous session"))
    }

    func curveStatsRow(session: HistoricalChargingSession?, socGain: Double,
                               durationMinutes: Int?, peak: Double?) -> some View {
        HStack(spacing: 12) {
            if let session, session.energyDeliveredKwh > 0 {
                curveStat(L10n.text("Energy"), Format.energyKwh(session.energyDeliveredKwh))
            }
            if socGain > 0.05 {
                curveStat(L10n.text("Added"), Format.signedPercent(socGain))
            }
            if let minutes = durationMinutes, minutes > 0 {
                curveStat(L10n.text("Duration"), Format.shortDuration(minutes: minutes))
            }
            if let peak, peak > 0 {
                curveStat(L10n.text("Peak"), Format.powerKw(peak))
            }
        }
    }

    func tariffSplitForSelectedSession() -> HistoryInsights.TariffCost? {
        guard let session = selectedSession, session.nightTariffEnabled || preferences.nightTariffEnabled,
              !selectedSessionSamples.isEmpty else { return nil }
        let dayRate = session.tariffPricePerKwh ?? preferences.electricityPricePerKwh
        let nightRate = session.nightTariffPricePerKwh ?? preferences.nightElectricityPricePerKwh
        let startHour = session.nightTariffStartHour ?? preferences.nightTariffStartHour
        let endHour = session.nightTariffEndHour ?? preferences.nightTariffEndHour
        return HistoryInsights.tariffAwareCost(from: selectedSessionSamples, dayRatePerKwh: dayRate,
                                               nightRatePerKwh: nightRate, nightStartHour: startHour,
                                               nightEndHour: endHour)
    }

    func chargingTypeBadgeColor(_ type: ChargingType) -> Color? {
        switch type {
        case .ac: return HisingenTheme.chartInfo
        case .dc: return HisingenTheme.chartAttention
        case .wireless: return .purple
        case .none: return .gray
        case .unknown: return nil
        }
    }

    // MARK: - Charging sessions list

    var chargingSessionsCard: some View {
        let anomalies = snapshot.anomalousSessionIDs
        let searching = !sessionSearchText.trimmingCharacters(in: .whitespaces).isEmpty
        let rows = searching ? filteredSessionsForPicker : Array(chargingSessions.prefix(500))
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "bolt.fill", title: L10n.text("Charging Sessions"), color: .green)
                    Spacer()
                    Text(L10n.format("%d shown", rows.count))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if chargingSessions.count > 8 {
                    searchField(L10n.text("Search sessions by date, place or energy"), text: $sessionSearchText,
                                count: filteredSessionsForPicker.count, total: chargingSessions.count)
                }
                ForEach(rows) { session in
                    Button {
                        selectedSessionID = (selectedSessionID == session.id) ? nil : session.id
                    } label: {
                        chargingSessionRow(session, flagged: anomalies.contains(session.id))
                    }
                    .buttonStyle(.plain)
                    if session.id != rows.last?.id { Divider().opacity(0.2) }
                }
                if !searching, chargingSessions.count > rows.count {
                    Text(L10n.format("Showing the %d most recent sessions.", rows.count))
                        .font(.system(size: 8.5)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    func chargingSessionRow(_ session: HistoricalChargingSession, flagged: Bool) -> some View {
        let cost = session.estimatedCost
            ?? session.tariffPricePerKwh.map { $0 * session.energyDeliveredKwh }
        let added = (session.endSoc ?? session.startSoc) - session.startSoc
        return HStack(spacing: 8) {
            Image(systemName: selectedSessionID == session.id ? "chart.dots.scatter" : "bolt.circle")
                .font(.system(size: 12))
                .foregroundStyle(selectedSessionID == session.id ? HisingenTheme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(Format.dateTimeFormatter.string(from: session.startedAt))
                        .font(.system(size: 10.5, weight: .semibold))
                    if flagged {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8)).foregroundStyle(HisingenTheme.semanticWarning)
                    }
                    if session.endedAt == nil {
                        Text(L10n.text("Active")).font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.green.opacity(0.15), in: Capsule())
                    }
                }
                HStack(spacing: 5) {
                    if let name = session.locationName, !name.isEmpty {
                        Text(name).lineLimit(1)
                        Text("·")
                    }
                    if added > 0.5 { Text(Format.signedPercent(added)) ; Text("·") }
                    Text(Format.energyKwh(session.energyDeliveredKwh))
                    if session.peakPowerKw > 0 { Text("· " + Format.powerKw(session.peakPowerKw)) }
                }
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let cost {
                Text(Format.currency(cost, symbol: session.currencySymbol ?? preferences.currencySymbol))
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chargingSessionAccessibilityLabel(session, flagged: flagged, cost: cost, added: added))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(selectedSessionID == session.id
                           ? L10n.text("Selected. Activate to close the charging curve.")
                           : L10n.text("Activate to show the charging curve."))
    }

    func chargingSessionAccessibilityLabel(_ session: HistoricalChargingSession, flagged: Bool,
                                                   cost: Double?, added: Double) -> String {
        var parts = [Format.dateTimeFormatter.string(from: session.startedAt)]
        if let name = session.locationName, !name.isEmpty { parts.append(name) }
        if session.endedAt == nil { parts.append(L10n.text("Active")) }
        if added > 0.5 { parts.append(Format.signedPercent(added)) }
        parts.append(Format.energyKwh(session.energyDeliveredKwh))
        if session.peakPowerKw > 0 { parts.append(Format.powerKw(session.peakPowerKw)) }
        if let cost { parts.append(Format.currency(cost, symbol: session.currencySymbol ?? preferences.currencySymbol)) }
        if flagged { parts.append(L10n.text("Low peak power for this location")) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Monthly charging energy & cost

    var monthlyChargingCard: AnyView {
        let monthly = HistoryInsights.monthlyChargingEnergy(
            from: chargingSessions,
            fallbackPricePerKwh: preferences.electricityPricePerKwh,
            fallbackCurrency: preferences.currencySymbol
        )
        guard monthly.count >= 2 else { return AnyView(EmptyView()) }
        let currency = monthly.compactMap(\.currency).first ?? preferences.currencySymbol
        let mixed = Set(monthly.compactMap(\.currency)).count > 1
        let hasCost = monthly.contains { $0.cost != nil }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "calendar.badge.clock", title: L10n.text("Charging by Month"), color: .green)
                Chart(monthly) { bucket in
                    BarMark(
                        x: .value(L10n.text("Month"), bucket.month, unit: .month),
                        y: .value(L10n.text("Energy"), bucket.energyKwh)
                    )
                    .foregroundStyle(HisingenTheme.chartPositive.gradient)
                    .cornerRadius(2)
                }
                .chartYAxisLabel("kWh")
                .frame(height: chartHeight * 0.8)
                .accessibilityLabel(L10n.text("Charging energy per month chart"))
                if !mixed && hasCost {
                    Chart(monthly) { bucket in
                        if let cost = bucket.cost {
                            LineMark(
                                x: .value(L10n.text("Month"), bucket.month, unit: .month),
                                y: .value(L10n.text("Cost"), cost)
                            )
                            .foregroundStyle(HisingenTheme.chartAttention)
                            .lineStyle(StrokeStyle(lineWidth: 1.6))
                            .interpolationMethod(.monotone)
                            PointMark(
                                x: .value(L10n.text("Month"), bucket.month, unit: .month),
                                y: .value(L10n.text("Cost"), cost)
                            )
                            .symbolSize(14)
                            .foregroundStyle(HisingenTheme.chartAttention)
                        }
                    }
                    .chartYAxisLabel(currency)
                    .frame(height: chartHeight * 0.6)
                    .accessibilityLabel(L10n.text("Charging cost per month chart"))
                }
                dataConfidenceNote(for: monthly.map(\.month))
            }
        })
    }

    // MARK: - Location breakdown

    var locationBreakdownCard: AnyView {
        let stats = HistoryInsights.locationStats(
            from: chargingSessions,
            fallbackPricePerKwh: preferences.electricityPricePerKwh,
            fallbackCurrency: preferences.currencySymbol,
            unknownLabel: L10n.text("Unknown location")
        )
        guard stats.count >= 2 else { return AnyView(EmptyView()) }
        let totalEnergy = max(0.001, stats.reduce(0) { $0 + $1.energyKwh })
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "mappin.and.ellipse", title: L10n.text("Charging by Location"), color: .teal)
                ForEach(stats.prefix(6)) { stat in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(stat.name).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text(L10n.format("%d sessions", stat.sessionCount))
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(HisingenTheme.chartPositive.opacity(0.3))
                                .frame(width: max(2, geo.size.width * stat.energyKwh / totalEnergy), height: 4)
                        }
                        .frame(height: 4)
                        HStack(spacing: 5) {
                            Text(Format.energyKwh(stat.energyKwh))
                            if stat.averagePeakKw > 0 { Text("· " + Format.powerKw(stat.averagePeakKw) + " " + L10n.text("avg peak")) }
                            if let cost = stat.cost, let currency = stat.currency {
                                Text("· " + Format.currency(cost, symbol: currency))
                            }
                        }
                        .font(.system(size: 8.5)).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        })
    }

    var chargingHistoryCard: some View {
        let energy = chargingSessions.reduce(0) { $0 + $1.energyDeliveredKwh }
        let averagePeak = chargingSessions.isEmpty ? 0 : chargingSessions.reduce(0) { $0 + $1.peakPowerKw } / Double(chargingSessions.count)
        let p90Peak = Statistics.percentile(chargingSessions.map(\.peakPowerKw).filter { $0 > 0 }, 90)
        let perWeek = HistoryInsights.sessionsPerWeek(from: chargingSessions)
        let byTimeOfDay = HistoryInsights.energyByTimeOfDay(from: chargingSessions)
        let dominantTimeOfDay = byTimeOfDay.max { $0.value < $1.value }
        let cost = aggregateChargingCost()
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "bolt.badge.clock.fill", title: L10n.text("Charging Trends"), color: .green)
                KVRow(L10n.text("Sessions"), Format.count(chargingSessions.count), symbol: "number")
                if let perWeek {
                    KVRow(L10n.text("Sessions Per Week"), Format.number(perWeek, decimals: 1), symbol: "calendar.badge.clock")
                }
                KVRow(L10n.text("Estimated Energy Added"), Format.energyKwh(energy), symbol: "bolt.fill", info: L10n.text("Estimated from stored vehicle telemetry unless a future metered wallbox source is explicitly identified."))
                if averagePeak > 0 {
                    KVRow(L10n.text("Average Observed Peak"), Format.powerKw(averagePeak), symbol: "waveform.path.ecg")
                }
                if let p90Peak, p90Peak > 0 {
                    KVRow(L10n.text("Typical Fast Peak (p90)"), Format.powerKw(p90Peak), symbol: "chart.bar.xaxis",
                          info: L10n.text("90th percentile of session peak power — less skewed by one outlier fast-charge than a plain average."))
                }
                if let dominantTimeOfDay, dominantTimeOfDay.value > 0 {
                    KVRow(L10n.text("Mostly Charges"), L10n.text(dominantTimeOfDay.key.rawValue), symbol: "clock.badge")
                }
                if let cost {
                    KVRow(L10n.text("Estimated Cost"), Format.currency(cost.amount, symbol: cost.currency), symbol: "creditcard",
                          info: L10n.text("Uses each session's saved tariff instead of recalculating old charges with today's settings."))
                } else {
                    KVRow(L10n.text("Estimated Cost"), L10n.text("Mixed currencies"), symbol: "creditcard",
                          info: L10n.text("Costs in different currencies are kept separate and are not added together."))
                }
            }
        }
    }
}
