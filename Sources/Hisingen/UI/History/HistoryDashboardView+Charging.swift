import Charts
import SwiftUI

// `HistoryDashboardView` – charging cards: the selected-session curve, the sessions list,
// charging-by-month, the per-location breakdown, and the aggregate trends card.

enum ChargingSessionFilter: Hashable, Sendable {
    case place(String)
    case month(Date)
    case timeOfDay(HistoryInsights.TimeOfDay)
    case peakPower

    var title: String {
        switch self {
        case .place(let name): return name
        case .month(let month): return month.formatted(.dateTime.month(.wide).year().locale(L10n.displayLocale))
        case .timeOfDay(let bucket): return L10n.text(bucket.rawValue)
        case .peakPower: return L10n.text("Peak Power")
        }
    }

    func contains(_ session: HistoricalChargingSession, unknownLocation: String) -> Bool {
        switch self {
        case .place(let place):
            let name = session.locationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (name.isEmpty ? unknownLocation : name) == place
        case .month(let month):
            return Calendar.current.isDate(session.startedAt, equalTo: month, toGranularity: .month)
        case .timeOfDay(let bucket):
            return HistoryInsights.timeOfDay(for: session.startedAt) == bucket
        case .peakPower:
            return session.peakPowerKw > 0
        }
    }
}

extension HistoryDashboardView {
    // MARK: - Charging curve

    @ViewBuilder
    var sessionDetail: some View {
        if let selectedSession {
            if !selectedSessionCurve.isEmpty, loadedSessionCurveID == selectedSession.id {
                chargingCurveCard
            } else {
                HistoryCardSurface {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            HistorySectionHeading(symbol: "chart.dots.scatter", title: L10n.text("Charging Curve"),
                                       color: HisingenTheme.semanticGood)
                            Spacer()
                            editSessionButton
                            closeSessionButton
                        }
                        Text(Format.dateTimeFormatter.string(from: selectedSession.startedAt))
                            .hisType(.caption, weight: .semibold)
                        if loadedSessionCurveID == selectedSession.id {
                            KVRow(L10n.text("Battery-side energy"), Format.energyKwh(selectedSession.energyDeliveredKwh))
                            if let wallbox = selectedSession.wallbox {
                                KVRow(L10n.text("Energy delivered by charger"), Format.energyKwh(wallbox.energyKwh))
                            }
                            Text(L10n.text("No charging samples were recorded for this session."))
                                .hisType(.caption).foregroundStyle(HisingenTheme.inkMuted)
                        } else {
                            ProgressView(L10n.text("Loading charging samples…"))
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var editSessionButton: some View {
        if let selectedSession, selectedSession.endedAt != nil {
            Button { beginEditingChargingSession(selectedSession) } label: {
                Image(systemName: "pencil").hisType(.label)
            }
            .buttonStyle(.pressable)
            .help(L10n.text("Edit"))
            .accessibilityLabel(L10n.text("Edit"))
        }
    }

    private var closeSessionButton: some View {
        Button {
            selectedSessionID = nil
        } label: {
            Image(systemName: "xmark").hisType(.label)
        }
        .buttonStyle(.pressable)
        .help(L10n.text("Close the charging curve"))
        .accessibilityLabel(L10n.text("Close charging curve"))
    }

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
            ? ChargingSessionLedger.estimatedChargingLossPct(
                from: samples,
                packCapacityKwh: history.usableCapacityKwh(vin: state.identity.vin, state: state))
            : nil
        let ratePolicy = preferences.electricityRatePolicy
        let estimatedCost = session.flatMap { stored -> Double? in
            if ratePolicy.isAutomatic, stored.spotEstimatedCost != nil {
                return stored.resolvedCost(policy: ratePolicy, fallbackPricePerKwh: preferences.electricityPricePerKwh).amount
            }
            return stored.estimatedCost
                ?? stored.tariffPricePerKwh.map { $0 * stored.energyDeliveredKwh }
                ?? (stored.summaryVersion < 2 ? preferences.electricityPricePerKwh * stored.energyDeliveredKwh : nil)
        }
        let costFigure = session.flatMap { sessionCostFigure($0, estimate: estimatedCost) }
        let cheapest = session.flatMap { cheapestOption(for: $0) }
        let pluggedMinutes: Int? = session.flatMap { stored -> Int? in
            guard let from = stored.wallbox?.startedAt, let to = stored.wallbox?.endedAt else { return nil }
            let minutes = Int(to.timeIntervalSince(from) / 60)
            return minutes > (durationMinutes ?? 0) + 10 ? minutes : nil
        }
        let tariffSplit = tariffSplitForSelectedSession()
        let isAnomalous = session.map { snapshot.anomalousSessionIDs.contains($0.id) } ?? false
        let curveGapCount = zip(curve, curve.dropFirst()).filter {
            $1.timestamp.timeIntervalSince($0.timestamp) > HistoryInsights.chargingCurveGapThreshold
        }.count
        return HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HistorySectionHeading(symbol: "chart.dots.scatter", title: L10n.text("Charging Curve"), color: HisingenTheme.semanticGood)
                    if selectedSession?.endedAt == nil {
                        HStack(spacing: 3) {
                            Circle().fill(HisingenTheme.chartPositive)
                                .frame(width: 5, height: 5)
                                .opacity(curveLivePulse ? 1.0 : 0.45)
                                .animation(Motion.resolve(Motion.livePulse), value: curveLivePulse)
                            Text(L10n.text("Live")).hisType(.nano, weight: .bold, design: .rounded)
                            .monospacedDigit()
                        }
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(HisingenTheme.semanticGood.opacity(0.15), in: RoundedRectangle(cornerRadius: 0))
                        .accessibilityLabel(L10n.text("Session in progress"))
                        .onAppear {
                            curveLivePulse = false
                            withAnimation(Motion.resolve(Motion.livePulse)) { curveLivePulse = true }
                        }
                    }
                    if let badgeColor = chargingTypeBadgeColor(chargingType) {
                        Text(chargingType.displayName)
                            .hisType(.nano, weight: .bold, design: .rounded)
                            .monospacedDigit()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(badgeColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 0))
                            .foregroundStyle(badgeColor)
                    }
                    Spacer()
                    editSessionButton
                    closeSessionButton
                }
                if let session {
                    HStack(spacing: 8) {
                        Label(session.place.displayName,
                              systemImage: session.place == .home ? "house" : "bolt.car")
                        if let name = session.locationName, !name.isEmpty {
                            Label(name, systemImage: "mappin.and.ellipse")
                        }
                    }
                    .hisType(.micro, weight: .medium)
                    .foregroundStyle(.secondary)
                }
                if isAnomalous {
                    footnote("exclamationmark.triangle.fill",
                             L10n.text("Peak power for this session was far below what this vehicle usually reaches here. Possibly a failing cable or a derated charger."))
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
                    .hisType(.micro, weight: .medium).foregroundStyle(.secondary)
                }
                curveStatsRow(session: session, socGain: socGain, durationMinutes: durationMinutes, peak: peak,
                              cost: costFigure)
                if tenToEighty != nil || idleTail != nil || lossPct != nil || pluggedMinutes != nil {
                    HStack(spacing: 12) {
                        if let pluggedMinutes {
                            curveStat(L10n.text("Plugged In"), Format.shortDuration(minutes: pluggedMinutes))
                        }
                        if let tenToEighty {
                            curveStat("10→80%", Format.shortDuration(minutes: max(1, Int(tenToEighty / 60))))
                        }
                        if let idleTail, idleTail >= 60 {
                            curveStat(L10n.text("Idle Tail"), Format.shortDuration(minutes: max(1, Int(idleTail / 60))))
                        }
                        if let lossPct, lossPct >= 1 {
                            curveStat(L10n.text("Estimated Loss"), Format.percent(lossPct))
                        }
                    }
                }
                SessionCurveCharts(curve: curve, targetSoc: session?.targetSoc,
                                   averagePowerKw: session?.averagePowerKw,
                                   showsTenToEighty: tenToEighty != nil,
                                   chargerPower: selectedSessionChargerPower.compactMap { record in
                                       record.value.map { (record.timestamp, $0) }
                                   },
                                   prices: loadedSessionPricesID == session?.id ? selectedSessionPrices : nil,
                                   cheapestSlots: cheapest?.slots ?? [],
                                   currencySymbol: session?.wallbox?.currency ?? session?.currencySymbol ?? preferences.currencySymbol,
                                   chartHeight: chartHeight, animationKey: sessionCurveKey)
                if let session, session.endedAt != nil, loadedSessionPricesID == session.id, selectedSessionPrices == nil {
                    Text(homeCharging?.tibberHome == nil
                         ? L10n.text("No price covers this session. Connect Tibber under Electricity to price it from Tibber's prices.")
                         : L10n.text("No price covers this session. Tibber keeps about a month of prices, and no market prices could be read for these days."))
                        .hisType(.micro).foregroundStyle(.secondary)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let session { wallboxRows(session, cheapest: cheapest) }
                if let tariffSplit, tariffSplit.nightEnergyKwh > 0 {
                    HStack(spacing: 12) {
                        curveStat(L10n.text("Day Energy"), Format.energyKwh(tariffSplit.dayEnergyKwh))
                        curveStat(L10n.text("Night Energy"), Format.energyKwh(tariffSplit.nightEnergyKwh))
                        curveStat(L10n.text("Split Cost"),
                                  Format.currency(tariffSplit.cost, symbol: session?.currencySymbol ?? preferences.currencySymbol))
                    }
                }
                Toggle(isOn: $overlayPreviousSession) {
                    Text(L10n.text("Overlay previous session")).hisType(.micro)
                }
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .disabled(selectedSession.flatMap { session in
                    chargingSessions.firstIndex(where: { $0.id == session.id }).map { $0 + 1 >= chargingSessions.count }
                } ?? true)
                if overlayPreviousSession, !previousSessionCurve.isEmpty {
                    previousSessionOverlayChart
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Text(L10n.text("Curves are drawn from locally recorded polls of vehicle telemetry, so resolution follows how often the vehicle reported while plugged in."))
                    .hisType(.micro).foregroundStyle(.secondary)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
                if let session { sessionNoteField(session) }
            }
            // The overlay chart lands one async hop after the toggle flips, so the key
            // covers both the toggle and the loaded curve.
            .hisAnimation(Motion.layout, value: previousOverlayKey)
        }
    }

    /// Identity for the previous-session overlay animation: the toggle plus the loaded curve.
    var previousOverlayKey: String {
        "\(overlayPreviousSession)_\(previousSessionCurve.count)"
    }

    /// This session against the previous one, both re-based to minutes-from-start so two sessions
    /// of different clock times line up for shape comparison. Charge level always; power too when
    /// both sessions recorded it, since a charger that is derating shows up in the power shape first.
    var previousSessionOverlayChart: some View {
        let hasPower = selectedSessionCurve.contains { ($0.powerKw ?? 0) > 0 }
            && previousSessionCurve.contains { ($0.powerKw ?? 0) > 0 }
        return VStack(alignment: .leading, spacing: 6) {
            sessionOverlayChart(title: L10n.text("Charge level"), unit: "%", fixedDomain: 0...100,
                                value: { $0.soc })
            if hasPower {
                sessionOverlayChart(title: L10n.text("Power"), unit: "kW", fixedDomain: nil,
                                    value: { $0.powerKw })
            }
            HStack(spacing: 12) {
                HistoryChartLegendItem(color: HisingenTheme.ink, label: L10n.text("This session"))
                HistoryChartLegendItem(color: HisingenTheme.inkMuted, label: L10n.text("Previous"), dashed: true)
                Spacer()
            }
        }
    }

    private func sessionOverlayChart(title: String, unit: String, fixedDomain: ClosedRange<Double>?,
                                     value: @escaping (HistoryInsights.ChargingCurvePoint) -> Double?) -> some View {
        func elapsed(_ points: [HistoryInsights.ChargingCurvePoint]) -> [(minutes: Double, value: Double)] {
            guard let start = points.first?.timestamp else { return [] }
            return points.compactMap { point in
                value(point).map { (point.timestamp.timeIntervalSince(start) / 60, $0) }
            }
        }
        let current = elapsed(selectedSessionCurve)
        let previous = elapsed(previousSessionCurve)
        let top = (current + previous).map(\.value).max() ?? 1
        let domain = fixedDomain ?? 0...max(top * 1.15, 1)
        return Chart {
            ForEach(Array(previous.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value(L10n.text("Minutes"), point.minutes),
                         y: .value(title, point.value),
                         series: .value(L10n.text("Session"), L10n.text("Previous")))
                .foregroundStyle(HisingenTheme.inkMuted)
                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                .interpolationMethod(.stepEnd)
            }
            ForEach(Array(current.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value(L10n.text("Minutes"), point.minutes),
                         y: .value(title, point.value),
                         series: .value(L10n.text("Session"), L10n.text("This session")))
                .foregroundStyle(HisingenTheme.ink)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .interpolationMethod(.stepEnd)
            }
        }
        .chartYScale(domain: domain)
        .chartXAxisLabel(L10n.text("Minutes"))
        .historyYAxis(unit)
        .frame(height: chartHeight * 0.62)
        .accessibilityLabel("\(title): \(L10n.text("This session")), \(L10n.text("Previous"))")
    }

    /// The cost a session card leads with, its label, and how it was reached.
    struct SessionCostFigure {
        var label: String
        var value: String
        var note: String?
        /// The total over the energy it paid for, e.g. "2.07 kr/kWh".
        var average: String?
    }

    /// The same energy drawn in the cheapest slots of the time the cable was in.
    struct CheapestOption {
        var cost: Double
        var saving: Double
        var slots: [HomePricePoint]
        var rateKw: Double
    }

    /// Only for a session priced slot by slot from Tibber: against an estimate or a spot basis the
    /// two figures would not be on the same footing.
    func cheapestOption(for session: HistoricalChargingSession) -> CheapestOption? {
        guard let wallbox = session.wallbox, let paid = wallbox.cost, wallbox.energyKwh > 0,
              wallbox.costMethod == HomeSessionCost.Method.intervalTibber.rawValue,
              loadedSessionPricesID == session.id, let series = selectedSessionPrices,
              series.basis == .tibberWithGridFee else { return nil }
        let rate = session.peakPowerKw > 0 ? session.peakPowerKw : preferences.electricityChargerPowerKw
        guard let best = series.cheapest(energyKwh: wallbox.energyKwh, rateKw: rate) else { return nil }
        return CheapestOption(cost: best.cost, saving: paid - best.cost, slots: best.slots, rateKw: rate)
    }

    /// The charger's own energy priced at Tibber's rate with the grid fee when the charger measured
    /// the session; otherwise the estimate from the battery-side energy and the rate settings.
    func sessionCostFigure(_ session: HistoricalChargingSession, estimate: Double?) -> SessionCostFigure? {
        if let wallbox = session.wallbox {
            let symbol = wallbox.currency ?? session.currencySymbol ?? preferences.currencySymbol
            let note = wallbox.costAssumptions.isEmpty ? nil : wallbox.costAssumptions.joined(separator: ". ") + "."
            if let cost = wallbox.cost {
                return SessionCostFigure(
                    label: L10n.text("Total Price"), value: Format.currency(cost, symbol: symbol), note: note,
                    average: wallbox.energyKwh > 0
                        ? Format.currency(cost / wallbox.energyKwh, symbol: "\(symbol)/kWh") : nil)
            }
            if let partial = wallbox.partialCost {
                return SessionCostFigure(label: L10n.text("Priced So Far"), value: Format.currency(partial, symbol: symbol), note: note)
            }
        }
        guard let estimate else { return nil }
        return SessionCostFigure(label: L10n.text("Estimated Cost"),
                                 value: Format.currency(estimate, symbol: session.currencySymbol ?? preferences.currencySymbol),
                                 note: L10n.text("No charger measured this session, so the battery-side energy is priced with your rate settings."))
    }

    func curveStatsRow(session: HistoricalChargingSession?, socGain: Double,
                               durationMinutes: Int?, peak: Double?, cost: SessionCostFigure?) -> some View {
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
            if let cost {
                Spacer(minLength: 12)
                curveStat(cost.label, cost.value)
                    .help(cost.note ?? "")
                if let average = cost.average {
                    curveStat(L10n.text("Average Price"), average)
                }
            }
        }
    }

    func tariffSplitForSelectedSession() -> ChargingSessionLedger.TariffCost? {
        guard let session = selectedSession, session.nightTariffEnabled || preferences.nightTariffEnabled,
              !selectedSessionSamples.isEmpty else { return nil }
        let dayRate = session.tariffPricePerKwh ?? preferences.electricityPricePerKwh
        let nightRate = session.nightTariffPricePerKwh ?? preferences.nightElectricityPricePerKwh
        let startHour = session.nightTariffStartHour ?? preferences.nightTariffStartHour
        let endHour = session.nightTariffEndHour ?? preferences.nightTariffEndHour
        return ChargingSessionLedger.tariffAwareCost(from: selectedSessionSamples, dayRatePerKwh: dayRate,
                                                     nightRatePerKwh: nightRate, nightStartHour: startHour,
                                                     nightEndHour: endHour)
    }

    func chargingTypeBadgeColor(_ type: ChargingType) -> Color? {
        switch type {
        case .ac: return HisingenTheme.chartInfo
        case .dc: return HisingenTheme.chartAttention
        case .wireless: return HisingenTheme.chartHealth
        case .none: return HisingenTheme.inkMuted
        case .unknown: return nil
        }
    }

    // MARK: - Charging sessions list

    var chargingSessionsCard: some View {
        let anomalies = snapshot.anomalousSessionIDs
        let matches = filteredSessionsForPicker
        return HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HistorySectionHeading(symbol: "bolt", title: L10n.text("Charging Sessions"), color: HisingenTheme.semanticGood)
                    Spacer()
                    Text(L10n.format("%d shown", matches.count))
                        .hisType(.micro).foregroundStyle(.secondary)
                    Button(L10n.text("Add Session")) { beginAddingChargingSession() }
                        .buttonStyle(.hisSecondary)
                        .controlSize(.small)
                        .help(L10n.text("Log a public charge from a receipt, or add a missing session."))
                }
                if let sessionFilter {
                    HStack(spacing: 6) {
                        Text(sessionFilter.title)
                            .hisType(.caption)
                        Spacer()
                        Button(L10n.text("Clear Filter")) { self.sessionFilter = nil }
                            .buttonStyle(.hisSecondary)
                            .controlSize(.small)
                    }
                }
                if chargingSessions.count > 8 || !sessionSearchText.isEmpty {
                    searchField(L10n.text("Search sessions by date, place or energy"), text: $sessionSearchText,
                                count: filteredSessionsForPicker.count, total: chargingSessions.count)
                }
                PaginatedSection(items: matches, pageSize: preferences.historyPageSize(for: .historyChargingSessions),
                                 resetKeys: [sessionSearchText, periodLoadKey, String(describing: sessionFilter)],
                                 emptyMessage: L10n.text("No charging sessions match this search.")) { rows, footer in
                    ForEach(rows) { session in
                        Button {
                            if selectedSessionID == session.id {
                                selectedSessionID = nil
                            } else {
                                selectedSessionID = session.id
                                if draws(.historyChargingCurve) { requestHistoryJump("charging-curve") }
                            }
                        } label: {
                            chargingSessionRow(session, flagged: anomalies.contains(session.id))
                        }
                        .buttonStyle(.pressable)
                        .contextMenu {
                            if session.endedAt != nil {
                                Button(L10n.text("Edit")) { beginEditingChargingSession(session) }
                            }
                        }
                        if session.id != rows.last?.id { Divider().opacity(HisingenTheme.dividerOpacity) }
                    }
                    footer
                }
                if embedsChargingCurve, selectedSession != nil {
                    PanelRule()
                    sessionDetail
                        .environment(\.historyCardEmbedded, true)
                        .id("charging-curve")
                }
            }
        }
        .task(id: chargingSessions.count) {
            await backfillSpotCosts()
        }
    }

    private func showSessions(matching filter: ChargingSessionFilter) {
        sessionFilter = filter
        sessionSearchText = ""
        requestHistoryJump("charging-sessions")
    }

    /// Prices uncosted sessions once spot-price coverage reaches them. Historical day files
    /// are fetched lazily, bounded to the seven most recent uncovered days so a long history
    /// cannot turn one card appearance into an unbounded fetch storm. The uncovered scan and
    /// the per-session pricing/UPDATE pass run off the main actor, like the other loads.
    private func backfillSpotCosts() async {
        let pricedSessions = await history.backfillSpotEstimatedCosts(
            vin: state.identity.vin, zone: preferences.electricityPriceZone,
            contract: preferences.electricityPriceContract)

        // Back on the main actor only for the reload decision.
        guard pricedSessions > 0, !Task.isCancelled else { return }
        await loadDashboardData()
    }

    static let stockholmCalendar = ElectricityPriceService.stockholmCalendar

    func chargingSessionRow(_ session: HistoricalChargingSession, flagged: Bool) -> some View {
        let ratePolicy = preferences.electricityRatePolicy
        // The charger's Tibber-priced total wins over the battery-side estimate when there is one.
        let cost: Double? = session.wallbox?.cost ?? (ratePolicy.isAutomatic && session.spotEstimatedCost != nil
            ? session.resolvedCost(policy: ratePolicy, fallbackPricePerKwh: preferences.electricityPricePerKwh).amount
            : session.estimatedCost ?? session.tariffPricePerKwh.map { $0 * session.energyDeliveredKwh })
        let added = (session.endSoc ?? session.startSoc) - session.startSoc
        return HStack(spacing: 8) {
            Image(systemName: selectedSessionID == session.id ? "chart.dots.scatter" : "bolt.circle")
                .hisType(.body)
                .foregroundStyle(selectedSessionID == session.id ? HisingenTheme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(Format.dateTimeFormatter.string(from: session.startedAt))
                        .hisType(.caption, weight: .semibold)
                    if flagged {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .hisType(.nano).foregroundStyle(HisingenTheme.semanticWarning)
                    }
                    if session.endedAt == nil {
                        Text(L10n.text("Active")).hisType(.nano, weight: .bold)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(HisingenTheme.semanticGood.opacity(0.15), in: RoundedRectangle(cornerRadius: 0))
                    }
                }
                HStack(spacing: 5) {
                    if let name = session.locationName, !name.isEmpty {
                        Text(name).lineLimit(1)
                        .minimumScaleFactor(0.9)
                        Text("·")
                    }
                    if added > 0.5 {
                        Text(Format.signedPercent(added))
                        Text("·")
                    }
                    Text(Format.energyKwh(session.energyDeliveredKwh))
                    if session.peakPowerKw > 0 { Text("· " + Format.powerKw(session.peakPowerKw)) }
                }
                .hisType(.micro).foregroundStyle(.secondary).lineLimit(1)
                .minimumScaleFactor(0.9)
                if let note = sessionNotes[session.id] {
                    Text(note).hisType(.micro).foregroundStyle(HisingenTheme.inkMuted).lineLimit(1)
                }
            }
            Spacer()
            if let cost {
                Text(Format.currency(cost, symbol: session.currencySymbol ?? preferences.currencySymbol))
                    .hisType(.caption, weight: .bold, design: .rounded)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chargingSessionAccessibilityLabel(session, flagged: flagged, cost: cost, added: added))
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(selectedSessionID == session.id ? L10n.text("Selected") : "")
        .accessibilityHint(draws(.historyChargingCurve) && selectedSessionID != session.id
                           ? L10n.text("Activate to show the charging curve.") : "")
        .hisAnimation(Motion.selection, value: selectedSessionID)
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
            fallbackCurrency: preferences.currencySymbol,
            ratePolicy: preferences.electricityRatePolicy
        )
        guard monthly.count >= 2 else {
            return AnyView(HistoryCardSurface {
                HisingenEmptyState(
                    symbol: "calendar.badge.clock",
                    title: L10n.text("Monthly charging comparison needs more data"),
                    message: L10n.text("Record charging sessions in at least two months to compare them.")
                )
            })
        }
        let currency = monthly.compactMap(\.currency).first ?? preferences.currencySymbol
        let mixed = Set(monthly.compactMap(\.currency)).count > 1
        let hasCost = monthly.contains { $0.cost != nil }
        return AnyView(HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HistorySectionHeading(symbol: "calendar.badge.clock", title: L10n.text("Charging by Month"), color: HisingenTheme.semanticGood)
                    Spacer()
                    if draws(.historyChargingSessions) {
                        Menu(L10n.text("View Sessions")) {
                            ForEach(monthly.reversed()) { bucket in
                                let filter = ChargingSessionFilter.month(bucket.month)
                                Button(filter.title) { showSessions(matching: filter) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                let currentMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start
                let hasPartialMonth = monthly.contains { $0.month == currentMonth }
                let monthDates = monthly.map(\.month)
                Chart(monthly) { bucket in
                    BarMark(
                        x: .value(L10n.text("Month"), bucket.month, unit: .month),
                        y: .value(L10n.text("Energy"), bucket.energyKwh)
                    )
                    // The month still running is lighter: it holds days, not a month, and a
                    // full-height neighbour would read as a higher month than it is.
                    .foregroundStyle(HistoryChartColor.chargeLevel.opacity(bucket.month == currentMonth ? 0.5 : 1))
                    .annotation(position: .top, spacing: 2) {
                        if monthly.count <= 8 {
                            Text(Format.number(bucket.energyKwh, decimals: 0))
                                .hisType(.micro).monospacedDigit().foregroundStyle(HisingenTheme.inkMuted)
                        }
                    }
                }
                .historyTimeAxis(spanning: monthDates, monthly: true)
                .historyYAxis("kWh")
                .frame(height: chartHeight * 0.8)
                .accessibilityLabel(L10n.text("Charging energy per month chart"))
                .accessibilityValue(chartAccessibilityValue(points: monthly.map { $0.energyKwh }))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Charging by Month"), yLabel: "kWh",
                    points: monthly.map { ($0.month, $0.energyKwh) },
                    valueFormat: { String(format: "%.0f", locale: L10n.displayLocale, $0) }))
                .hisAnimation(Motion.progress, value: periodDataKey)
                if hasPartialMonth {
                    HistoryChartLegendItem(color: HistoryChartColor.chargeLevel.opacity(0.5),
                                           label: L10n.text("Month in progress"), band: true)
                }
                if !mixed && hasCost {
                    Chart(monthly) { bucket in
                        if let cost = bucket.cost {
                            LineMark(
                                x: .value(L10n.text("Month"), bucket.month, unit: .month),
                                y: .value(L10n.text("Cost"), cost)
                            )
                            .foregroundStyle(HistoryChartColor.power)
                            .lineStyle(StrokeStyle(lineWidth: 1.6))
                            .interpolationMethod(.monotone)
                            PointMark(
                                x: .value(L10n.text("Month"), bucket.month, unit: .month),
                                y: .value(L10n.text("Cost"), cost)
                            )
                            .symbolSize(14)
                            .foregroundStyle(HistoryChartColor.power)
                        }
                    }
                    .historyTimeAxis(spanning: monthDates, monthly: true)
                    .historyYAxis(currency)
                    .frame(height: chartHeight * 0.6)
                    .accessibilityLabel(L10n.text("Charging cost per month chart"))
                    .accessibilityValue(chartAccessibilityValue(points: monthly.compactMap { $0.cost }))
                    .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                        title: L10n.text("Cost"), yLabel: currency,
                        points: monthly.compactMap { bucket in bucket.cost.map { (bucket.month, $0) } }))
                    .hisAnimation(Motion.progress, value: periodDataKey)
                    // The figure that says whether charging got cheaper: price per kWh, which the
                    // two charts above hide behind how much was charged.
                    if let latest = monthly.last(where: { $0.cost != nil && $0.energyKwh > 0 }), let cost = latest.cost {
                        curveStat(L10n.text("Per kWh"),
                                  Format.currency(cost / latest.energyKwh, symbol: currency, decimals: 3))
                    }
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
            ratePolicy: preferences.electricityRatePolicy,
            unknownLabel: L10n.text("Unknown location")
        )
        guard stats.count >= 2 else {
            return AnyView(HistoryCardSurface {
                HisingenEmptyState(
                    symbol: "mappin.and.ellipse",
                    title: L10n.text("Location comparison needs more places"),
                    message: L10n.text("Record charging sessions at two named locations to compare them.")
                )
            })
        }
        let totalEnergy = max(0.001, stats.reduce(0) { $0 + $1.energyKwh })
        return AnyView(HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HistorySectionHeading(symbol: "mappin.and.ellipse", title: L10n.text("Charging by Location"), color: HisingenTheme.chartPositive)
                ForEach(stats.prefix(6)) { stat in
                    if draws(.historyChargingSessions) {
                        Button { showSessions(matching: .place(stat.name)) } label: {
                            locationStat(stat, totalEnergy: totalEnergy)
                        }
                        .buttonStyle(.pressable)
                        .help(L10n.format("View charging sessions at %@", stat.name))
                        .accessibilityHint(L10n.format("View charging sessions at %@", stat.name))
                    } else {
                        locationStat(stat, totalEnergy: totalEnergy)
                    }
                }
                let costRows = HistoryInsights.locationCostRows(
                    from: chargingSessions,
                    fallbackPricePerKwh: preferences.electricityPricePerKwh,
                    fallbackCurrency: preferences.currencySymbol,
                    ratePolicy: preferences.electricityRatePolicy,
                    unknownLabel: L10n.text("Unknown location")
                )
                if !costRows.isEmpty {
                    Divider().opacity(HisingenTheme.dividerOpacity)
                    locationCostTable(Array(costRows.prefix(8)))
                }
            }
        })
    }

    private func locationStat(_ stat: HistoryInsights.LocationStat, totalEnergy: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(stat.name).hisType(.caption, weight: .semibold).lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer()
                Text(L10n.format("%d sessions", stat.sessionCount))
                    .hisType(.micro).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                Rectangle()
                    .fill(HisingenTheme.chartPositive.opacity(0.3))
                    .frame(width: min(geo.size.width, max(2, geo.size.width * stat.energyKwh / totalEnergy)), height: 4)
                    .hisAnimation(Motion.progress, value: stat.energyKwh)
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            HStack(spacing: 5) {
                Text(Format.energyKwh(stat.energyKwh))
                if stat.averagePeakKw > 0 {
                    Text("· " + Format.powerKw(stat.averagePeakKw) + " " + L10n.text("avg peak"))
                }
                if let cost = stat.cost, let currency = stat.currency {
                    Text("· " + Format.currency(cost, symbol: currency))
                }
            }
            .hisType(.nano).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// One row per place and currency. Costs in different currencies stay on separate rows;
    /// a per-kWh average is shown only where energy was recorded.
    private func locationCostTable(_ rows: [HistoryInsights.LocationCostRow]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow {
                    Text(L10n.text("Location"))
                    Text(L10n.text("Sessions")).gridColumnAlignment(.trailing)
                    Text(L10n.text("Energy")).gridColumnAlignment(.trailing)
                    Text(L10n.text("Cost")).gridColumnAlignment(.trailing)
                    Text(L10n.text("Per kWh")).gridColumnAlignment(.trailing)
                }
                .hisType(.nano, weight: .semibold).foregroundStyle(.secondary)
                ForEach(rows) { row in
                    GridRow {
                        Text(row.name).lineLimit(1).minimumScaleFactor(0.9)
                        Text(Format.count(row.sessionCount)).gridColumnAlignment(.trailing)
                        Text(Format.energyKwh(row.energyKwh)).gridColumnAlignment(.trailing)
                        Text(Format.currency(row.totalCost, symbol: row.currency)).gridColumnAlignment(.trailing)
                        Text(row.averageCostPerKwh.map { Format.currency($0, symbol: row.currency, decimals: 3) } ?? "–")
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .hisType(.micro).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }

    var chargingHistoryCard: some View {
        let energy = chargingSessions.reduce(0) { $0 + $1.energyDeliveredKwh }
        let averagePeak = chargingSessions.isEmpty ? 0 : chargingSessions.reduce(0) { $0 + $1.peakPowerKw } / Double(chargingSessions.count)
        let p90Peak = Statistics.percentile(chargingSessions.map(\.peakPowerKw).filter { $0 > 0 }, 90)
        let perWeek = HistoryInsights.sessionsPerWeek(from: chargingSessions)
        let byTimeOfDay = HistoryInsights.energyByTimeOfDay(from: chargingSessions)
        let dominantTimeOfDay = byTimeOfDay.max { $0.value < $1.value }
        let cost = aggregateChargingCost()
        return HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HistorySectionHeading(symbol: "bolt.badge.clock", title: L10n.text("Charging Trends"), color: HisingenTheme.semanticGood)
                if draws(.historyChargingSessions), !byTimeOfDay.isEmpty {
                    Menu(L10n.text("View Sessions")) {
                        ForEach(HistoryInsights.TimeOfDay.allCases.filter { byTimeOfDay[$0] != nil }, id: \.self) { bucket in
                            let filter = ChargingSessionFilter.timeOfDay(bucket)
                            Button(filter.title) { showSessions(matching: filter) }
                        }
                        if p90Peak != nil {
                            Button(L10n.text("By Peak Power")) { showSessions(matching: .peakPower) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                KVRow(L10n.text("Sessions"), Format.count(chargingSessions.count), symbol: "number")
                if let perWeek {
                    KVRow(L10n.text("Sessions Per Week"), Format.number(perWeek, decimals: 1), symbol: "calendar.badge.clock")
                }
                KVRow(L10n.text("Estimated Energy Added"), Format.energyKwh(energy), symbol: "bolt", info: L10n.text("Estimated from stored vehicle telemetry unless a future metered wallbox source is explicitly identified."))
                if averagePeak > 0 {
                    KVRow(L10n.text("Average Observed Peak"), Format.powerKw(averagePeak), symbol: "waveform.path.ecg")
                }
                if let p90Peak, p90Peak > 0 {
                    KVRow(L10n.text("Typical Fast Peak (p90)"), Format.powerKw(p90Peak), symbol: "chart.bar.xaxis",
                          info: L10n.text("90th percentile of session peak power: less skewed by one outlier fast-charge than a plain average."))
                }
                if let dominantTimeOfDay, dominantTimeOfDay.value > 0 {
                    KVRow(L10n.text("Mostly Charges"), L10n.text(dominantTimeOfDay.key.rawValue), symbol: "clock.badge")
                }
                if let cost {
                    KVRow(L10n.text("Estimated Cost"), Format.currency(cost.amount, symbol: cost.currency), symbol: "creditcard",
                          info: preferences.electricityRatePolicy.isAutomatic
                              ? L10n.format("Sessions the market prices cover use the %@. The other %d use the saved cost or your fixed rate.",
                                            preferences.electricityRatePolicy.basisDescription, cost.fallbackSessions)
                              : cost.fallbackSessions == 0
                              ? L10n.text("Uses each session's saved tariff instead of recalculating old charges with today's settings.")
                              : L10n.format("Uses each session's saved cost or tariff where one was recorded. %d of %d sessions had neither and fall back to your current electricity price.",
                                            cost.fallbackSessions, chargingSessions.count))
                } else {
                    KVRow(L10n.text("Estimated Cost"), L10n.text("Mixed currencies"), symbol: "creditcard",
                          info: L10n.text("Costs in different currencies are kept separate and are not added together."))
                }
                if let split = chargingCostSplit(), !chargingSessions.isEmpty {
                    KVRow(L10n.text("Home Charging"),
                          Format.currency(split.home.amount, symbol: split.currency),
                          symbol: "house",
                          info: L10n.text("Includes every session recorded automatically until its place is changed."))
                    KVRow(L10n.text("Public Charging"),
                          Format.currency(split.publicCharging.amount, symbol: split.currency),
                          symbol: "bolt.car")
                }
                spotSavingsRow
                if let houseLoad { HouseLoadRows(share: houseLoad) }
                sessionTrendSection
                timeOfDaySection(byTimeOfDay)
            }
            .task(id: houseLoadKey) { await loadHouseLoad() }
        }
    }

    /// Changes when the period or the sessions inside it do, which is when the share is worth reading again.
    private var houseLoadKey: String {
        "\(state.identity.vin)_\(periodDataKey)_\(chargingSessions.count)_\(homeCharging?.tibberHome?.id ?? "")_\(homeCharging?.houseMeter.meter?.id ?? "")"
    }

    private func loadHouseLoad() async {
        guard let homeCharging, homeCharging.hasHouseMeterSource,
              chargingSessions.contains(where: { $0.wallbox != nil }) else {
            houseLoad = nil
            return
        }
        let now = Date()
        let range = activeRange
        let from = range?.lowerBound ?? now.addingTimeInterval(-62 * 86_400)
        let to = min(range?.upperBound ?? now, now)
        let share = await homeCharging.houseLoadShare(from: from, to: to, sessions: chargingSessions)
        guard !Task.isCancelled else { return }
        houseLoad = share
    }
}
