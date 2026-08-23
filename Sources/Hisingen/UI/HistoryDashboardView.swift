import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct HistoryDashboardView: View {
    let state: VehicleState
    let database: VehicleDatabase

    @Environment(\.preferencesStore) private var preferences
    @State private var period: HistoryPeriod = .month
    @State private var selectedSessionID: String?
    @State private var sessionSearchText: String = ""

    private enum HistoryPeriod: String, CaseIterable, Identifiable {
        case week = "7 Days"
        case month = "30 Days"
        case all = "All"
        case custom = "Custom…"
        var id: String { rawValue }
        var days: Int? { self == .week ? 7 : (self == .month ? 30 : nil) }
    }

    @State private var fuelLitersText: String = ""
    @State private var fuelPriceText: String = ""
    @State private var fuelOdometerText: String = ""
    @State private var showFuelSheet = false
    @State private var customRangeStart: Date = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
    @State private var customRangeEnd: Date = Date()
    @State private var showCustomRangeEditor = false

    private var cutoff: Date? {
        if period == .custom {
            return customRangeStart
        }
        return period.days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
    }

    private var trips: [TripHistoryEntry] {
        database.derivedTrips(for: state.vin, limit: 1_000).filter { trip in
            cutoff.map { trip.endedAt >= $0 } ?? true
        }
    }

    private var chargingSessions: [HistoricalChargingSession] {
        database.recentChargingSessions(for: state.vin, limit: 1_000).filter { session in
            cutoff.map { session.startedAt >= $0 } ?? true
        }
    }

    private var commands: [RemoteCommandAuditRecord] {
        database.recentCommandAudits(for: state.vin, limit: 250).filter { command in
            cutoff.map { command.executedAt >= $0 } ?? true
        }
    }

    /// Battery-health milestones deliberately ignore the period picker: state of health moves
    /// over months, so a "7 days" window would usually show a single point and read as broken.
    private var batteryHealthRecords: [BatteryHealthRecord] {
        database.batteryHealthHistory(for: state.vin, limit: 200)
    }

    private var airQualityRecords: [AirQualityRecord] {
        database.recentAirQuality(for: state.vin, limit: 500).filter { record in
            cutoff.map { record.timestamp >= $0 } ?? true
        }
    }

    private var telemetryRecords: [HistoricalTelemetryRecord] {
        database.recentTelemetry(for: state.vin, limit: 2_000).filter { record in
            cutoff.map { record.timestamp >= $0 } ?? true
        }
    }

    private var efficiencyPoints: [HistoryInsights.EfficiencyPoint] {
        guard state.powertrain.hasElectricRange else { return [] }
        return HistoryInsights.efficiencyTrend(from: telemetryRecords)
    }

    private var odometerPoints: [HistoryInsights.OdometerPoint] {
        HistoryInsights.odometerTrend(from: telemetryRecords)
    }

    private var selectedSession: HistoricalChargingSession? {
        let sessions = chargingSessions
        guard !sessions.isEmpty else { return nil }
        return sessions.first(where: { $0.id == selectedSessionID }) ?? sessions.first
    }

    private var selectedSessionCurve: [HistoryInsights.ChargingCurvePoint] {
        guard let session = selectedSession else { return [] }
        return HistoryInsights.chargingCurve(from: database.chargingSamples(for: session.id))
    }

    private var selectedSessionSamples: [HistoricalChargingSample] {
        guard let session = selectedSession else { return [] }
        return database.chargingSamples(for: session.id)
    }

    private var filteredSessionsForPicker: [HistoricalChargingSession] {
        let trimmed = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(chargingSessions.prefix(500)) }
        return chargingSessions.filter { sessionLabel($0).localizedCaseInsensitiveContains(trimmed) }
    }

    /// Odometer/telemetry history ignoring the period picker — mirrors `batteryHealthRecords`:
    /// monthly mileage and the km/day rate are only meaningful over a long span, so a "7 days"
    /// window would usually collapse them to noise or nothing at all.
    private var allTimeTelemetryRecords: [HistoricalTelemetryRecord] {
        database.recentTelemetry(for: state.vin, limit: 2_000)
    }

    private var fuelEntries: [VehicleDatabase.FuelEntry] {
        state.powertrain.hasCombustionEngine ? database.recentFuelEntries(for: state.vin, limit: 50) : []
    }

    private var cabinClimateRecords: [VehicleDatabase.CabinClimateRecord] {
        database.recentCabinClimate(for: state.vin, limit: 200)
    }

    private var allTimeOdometerPoints: [HistoryInsights.OdometerPoint] {
        HistoryInsights.odometerTrend(from: allTimeTelemetryRecords)
    }

    private var commandStatistics: HistoryInsights.CommandStatistics {
        HistoryInsights.commandStatistics(from: commands)
    }

    private struct MonthComparison {
        let distanceKm: Double
        let energyKwh: Double
        let averageConsumption: Double?
    }

    private struct SmoothedPoint: Identifiable {
        let id: Int64
        let timestamp: Date
        let value: Double
    }

    /// Current-vs-previous calendar month, independent of the period picker (which the user
    /// might have set to "7 Days") so this comparison always has something to compare.
    private func monthComparison(monthsAgo: Int, calendar: Calendar = .current) -> MonthComparison {
        guard let monthStart = calendar.date(byAdding: .month, value: -monthsAgo, to: HistoryInsights.monthBucket(Date(), calendar: calendar)),
              let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
            return MonthComparison(distanceKm: 0, energyKwh: 0, averageConsumption: nil)
        }
        let monthTrips = database.derivedTrips(for: state.vin, limit: 2_000).filter {
            $0.endedAt >= monthStart && $0.endedAt < monthEnd
        }
        let monthSessions = database.recentChargingSessions(for: state.vin, limit: 2_000).filter {
            $0.startedAt >= monthStart && $0.startedAt < monthEnd
        }
        let consumptionValues = monthTrips.compactMap { trip -> Double? in
            guard let value = trip.averageConsumption, HistoryInsights.efficiencyBounds.contains(value) else { return nil }
            return value
        }
        return MonthComparison(
            distanceKm: monthTrips.reduce(0) { $0 + $1.distanceKm },
            energyKwh: monthSessions.reduce(0) { $0 + $1.energyDeliveredKwh },
            averageConsumption: consumptionValues.isEmpty ? nil : consumptionValues.reduce(0, +) / Double(consumptionValues.count)
        )
    }

    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            periodPicker
            overviewCard
            monthComparisonCard
            if selectedSession != nil && !selectedSessionCurve.isEmpty { chargingCurveCard }
            if !trips.isEmpty {
                distanceChartCard
                tripListCard
            }
            if !chargingSessions.isEmpty { chargingHistoryCard }
            if !fuelEntries.isEmpty { recentFillsCard }
            if efficiencyPoints.count >= 3 { efficiencyChartCard }
            if odometerPoints.count >= 3 { odometerChartCard }
            if !batteryHealthRecords.isEmpty { batteryHealthCard }
            if airQualityRecords.count >= 2 { airQualityCard }
            if cabinClimateRecords.count >= 2 { cabinClimateCard }
            if !commands.isEmpty { automationHistoryCard }
            if trips.isEmpty && chargingSessions.isEmpty && commands.isEmpty
                && batteryHealthRecords.isEmpty && airQualityRecords.count < 2 { emptyCard }
        }
        .sheet(isPresented: $showFuelSheet) { fuelEntrySheet }
    }

    private var periodPicker: some View {
        Picker(L10n.text("History Period"), selection: $period) {
            ForEach(HistoryPeriod.allCases) { item in
                Text(L10n.text(item.rawValue)).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(L10n.text("History Period"))
        .popover(isPresented: $showCustomRangeEditor, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Custom Range")).font(.system(size: 12, weight: .semibold))
                DatePicker(L10n.text("From"), selection: $customRangeStart,
                           in: ...customRangeEnd, displayedComponents: .date)
                    .font(.system(size: 11))
                DatePicker(L10n.text("To"), selection: $customRangeEnd,
                           in: customRangeStart...Date(), displayedComponents: .date)
                    .font(.system(size: 11))
                Text(period == .custom ? "" : L10n.text("Choose “Custom…” to apply."))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(width: 260)
        }
        .onChange(of: period) { _, newValue in
            if newValue == .custom { showCustomRangeEditor = true }
        }
    }

    private var overviewCard: some View {
        let totalDistance = trips.reduce(0) { $0 + $1.distanceKm }
        let drivingTime = trips.reduce(0) { $0 + $1.duration }
        let energy = chargingSessions.reduce(0) { $0 + $1.energyDeliveredKwh }
        let estimatedCost = energy * preferences.electricityPricePerKwh
        // Predicted service date from the observed km/day rate and the vehicle's own
        // remaining-distance/time countdowns.
        let serviceProjection = HistoryInsights.projectService(
            currentOdometerKm: state.odometerKm.map(Double.init),
            distanceToServiceKm: state.distanceToServiceKm,
            daysToService: state.daysToService,
            odometerPoints: odometerPoints
        )
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "chart.xyaxis.line", title: L10n.text("History Overview"), color: .indigo)
                    Spacer()
                    if state.powertrain.hasCombustionEngine {
                        Button {
                            showFuelSheet = true
                        } label: {
                            Label(L10n.text("Add Fuel"), systemImage: "drop.fill")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.text("Log a fill-up so fuel spend is included in cost estimates"))
                    }
                    exportMenu
                }
                HStack(spacing: 8) {
                    metric(L10n.text("Distance"), Format.distance(km: totalDistance, decimals: 1, unit: preferences.distanceUnit), "road.lanes")
                    metric(L10n.text("Trips"), "\(trips.count)", "car.side")
                    metric(L10n.text("Driving"), Format.shortDuration(minutes: Int(drivingTime / 60)), "clock")
                }
                HStack(spacing: 8) {
                    metric(L10n.text("Charge Sessions"), "\(chargingSessions.count)", "bolt.fill")
                    metric(L10n.text("Estimated Energy"), String(format: "%.1f kWh", energy), "bolt.circle")
                    metric(L10n.text("Estimated Cost"), String(format: "%.2f %@", estimatedCost, preferences.currencySymbol), "creditcard")
                }
                if let serviceProjection {
                    HStack(spacing: 5) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 10))
                            .foregroundStyle(HisingenTheme.accent)
                        Text(L10n.format("Next service projected around %@",
                                         Format.dateFormatter.string(from: serviceProjection.projectedDate ?? Date())))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                        if let odo = serviceProjection.projectedOdometerKm {
                            Text("· " + Format.distance(km: Int(odo.rounded()), unit: preferences.distanceUnit))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                }
                // Lifetime figure — deliberately ignores the period filter so it answers
                // "what has ownership cost me so far" rather than "this month".
                let fuelSpend = database.lifetimeFuelCost(for: state.vin)
                let lifetimeCostPerKm = HistoryInsights.costPerKm(
                    totalEnergyKwh: database.lifetimeChargingEnergyKwh(for: state.vin),
                    pricePerKwh: preferences.electricityPricePerKwh,
                    odometerPoints: allTimeOdometerPoints,
                    fuelCost: fuelSpend
                )
                if let costPerKm = lifetimeCostPerKm, preferences.electricityPricePerKwh > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 10))
                            .foregroundStyle(HisingenTheme.accent)
                        Text(L10n.format("Lifetime charging cost ≈ %@ per %@",
                                         String(format: "%.3f %@", costPerKm * (preferences.distanceUnit == .kilometers ? 1 : 1.609344), preferences.currencySymbol),
                                         preferences.distanceUnit == .kilometers ? "km" : "mi"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                        Text(L10n.text("(estimated)"))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            Button(L10n.text("Trips")) { exportCSV(database.exportTripsCSV(for: state.vin),
                                                    name: "Trips") }
                .disabled(trips.isEmpty)
            Button(L10n.text("Charging Sessions")) {
                exportCSV(database.exportChargingSessionsCSV(for: state.vin), name: "Charging-Sessions")
            }
            .disabled(chargingSessions.isEmpty)
            Button(L10n.text("Battery Health")) {
                exportCSV(database.exportBatteryHealthCSV(for: state.vin), name: "Battery-Health")
            }
            .disabled(batteryHealthRecords.isEmpty)
            Button(L10n.text("Air Quality")) {
                exportCSV(database.exportAirQualityCSV(for: state.vin), name: "Air-Quality")
            }
            .disabled(airQualityRecords.isEmpty)
            Button(L10n.text("Telemetry")) {
                exportCSV(database.exportTelemetryCSV(for: state.vin), name: "Telemetry")
            }
            .disabled(telemetryRecords.isEmpty)
            Button(L10n.text("Session Samples")) {
                guard let session = selectedSession else { return }
                exportCSV(database.exportChargingSamplesCSV(sessionID: session.id),
                          name: "Charging-Samples")
            }
            .disabled(selectedSession == nil || selectedSessionCurve.isEmpty)
        } label: {
            Label(L10n.text("Export"), systemImage: "square.and.arrow.up")
                .font(.system(size: 10, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L10n.text("Export history data"))
    }

    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(HisingenTheme.accent)
            Text(value).font(.system(size: 12, weight: .bold, design: .rounded)).lineLimit(1)
            Text(title).font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    private var monthComparisonCard: some View {
        let thisMonth = monthComparison(monthsAgo: 0)
        let lastMonth = monthComparison(monthsAgo: 1)
        guard thisMonth.distanceKm > 0 || thisMonth.energyKwh > 0 || lastMonth.distanceKm > 0 || lastMonth.energyKwh > 0 else {
            return AnyView(EmptyView())
        }
        func delta(_ current: Double, _ previous: Double) -> String? {
            guard previous > 0 else { return nil }
            let pct = (current - previous) / previous * 100
            return String(format: "%@%.0f%%", pct >= 0 ? "+" : "", pct)
        }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "calendar", title: L10n.text("This Month vs Last"), color: .cyan)
                HStack(spacing: 8) {
                    comparisonMetric(L10n.text("Distance"),
                                     Format.distance(km: thisMonth.distanceKm, decimals: 0, unit: preferences.distanceUnit),
                                     delta(thisMonth.distanceKm, lastMonth.distanceKm))
                    comparisonMetric(L10n.text("Energy"),
                                     String(format: "%.1f kWh", thisMonth.energyKwh),
                                     delta(thisMonth.energyKwh, lastMonth.energyKwh))
                    if let thisConsumption = thisMonth.averageConsumption {
                        comparisonMetric(L10n.text("Consumption"),
                                         preferences.energyConsumptionUnit.format(kwhPer100Km: thisConsumption),
                                         lastMonth.averageConsumption.flatMap { delta(thisConsumption, $0) })
                    }
                }
            }
        })
    }

    private func comparisonMetric(_ title: String, _ value: String, _ delta: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 12, weight: .bold, design: .rounded)).lineLimit(1)
            HStack(spacing: 4) {
                Text(title).font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1)
                if let delta {
                    Text(delta).font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(delta.hasPrefix("+") ? HisingenTheme.semanticWarning : HisingenTheme.semanticGood)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - Charging Curve

    private var chargingCurveCard: some View {
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
        let tariffCost: HistoryInsights.TariffCost? = preferences.nightTariffEnabled
            ? HistoryInsights.tariffAwareCost(from: samples, dayRatePerKwh: preferences.electricityPricePerKwh,
                                              nightRatePerKwh: preferences.nightElectricityPricePerKwh,
                                              nightStartHour: preferences.nightTariffStartHour,
                                              nightEndHour: preferences.nightTariffEndHour)
            : nil
        // A shorter gap threshold than the daily-cadence charts: a session spans hours, so a
        // hole of a couple of hours mid-session (app closed, car briefly unplugged) is exactly
        // the kind of gap that shouldn't be smoothed over with an interpolated line.
        let curveSegmentByID = gapSegmentIndex(of: curve, maxGap: HistoryInsights.chargingCurveGapThreshold, timestamp: \.timestamp)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "chart.dots.scatter", title: L10n.text("Charging Curve"), color: .green)
                    if selectedSession?.endedAt == nil {
                        // Live session: the curve keeps growing as polls arrive.
                        HStack(spacing: 3) {
                            Circle().fill(HisingenTheme.chartPositive).frame(width: 5, height: 5)
                            Text(L10n.text("Live"))
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
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
                    Picker(L10n.text("Session"), selection: Binding(
                        get: { selectedSession?.id },
                        set: { selectedSessionID = $0 }
                    )) {
                        ForEach(filteredSessionsForPicker) { item in
                            Text(sessionLabel(item)).tag(item.id as String?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
                if chargingSessions.count > 8 {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.tertiary)
                        TextField(L10n.text("Search sessions by date or energy"), text: $sessionSearchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 9.5))
                        if !sessionSearchText.isEmpty {
                            Text("\(filteredSessionsForPicker.count)/\(chargingSessions.count)")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(5)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 5))
                }
                Chart(curve) { point in
                    AreaMark(
                        x: .value(L10n.text("Time"), point.timestamp),
                        y: .value(L10n.text("Charge level"), point.soc)
                    )
                    .foregroundStyle(.linearGradient(colors: [HisingenTheme.chartPositive.opacity(0.28), HisingenTheme.chartPositive.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                    LineMark(
                        x: .value(L10n.text("Time"), point.timestamp),
                        y: .value(L10n.text("Charge level"), point.soc),
                        series: .value(L10n.text("Segment"), curveSegmentByID[point.id] ?? 0)
                    )
                    .foregroundStyle(HisingenTheme.chartPositive)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("%")
                .frame(height: 105)
                .accessibilityLabel(L10n.text("Charging curve charge-level chart"))
                if let peak, peak > 0 {
                    Chart(curve.filter { $0.powerKw != nil }) { point in
                        AreaMark(
                            x: .value(L10n.text("Time"), point.timestamp),
                            y: .value(L10n.text("Power"), point.powerKw ?? 0)
                        )
                        .foregroundStyle(.linearGradient(colors: [HisingenTheme.chartAttention.opacity(0.25), HisingenTheme.chartAttention.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                        LineMark(
                            x: .value(L10n.text("Time"), point.timestamp),
                            y: .value(L10n.text("Power"), point.powerKw ?? 0),
                            series: .value(L10n.text("Segment"), curveSegmentByID[point.id] ?? 0)
                        )
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                        .interpolationMethod(.catmullRom)
                    }
                    .chartYAxisLabel("kW")
                    .frame(height: 80)
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
                            .interpolationMethod(.catmullRom)
                        }
                        if let current = point.currentAmps {
                            LineMark(
                                x: .value(L10n.text("Time"), point.timestamp),
                                y: .value(L10n.text("Current"), current),
                                series: .value(L10n.text("Segment"), "current-\(curveSegmentByID[point.id] ?? 0)")
                            )
                            .foregroundStyle(by: .value(L10n.text("Series"), L10n.text("Current (A)")))
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartForegroundStyleScale([
                        L10n.text("Voltage (V)"): Color.purple,
                        L10n.text("Current (A)"): Color.yellow
                    ])
                    .frame(height: 70)
                    .accessibilityLabel(L10n.text("Charging curve voltage and current chart"))
                }
                HStack(spacing: 12) {
                    if let session, session.energyDeliveredKwh > 0 {
                        curveStat(L10n.text("Energy"), String(format: "%.1f kWh", session.energyDeliveredKwh))
                    }
                    if socGain > 0.05 {
                        curveStat(L10n.text("Added"), String(format: "+%.0f%%", socGain))
                    }
                    if let minutes = durationMinutes, minutes > 0 {
                        curveStat(L10n.text("Duration"), Format.shortDuration(minutes: minutes))
                    }
                    if let peak, peak > 0 {
                        curveStat(L10n.text("Peak"), String(format: "%.1f kW", peak))
                    }
                }
                if tenToEighty != nil || idleTail != nil || lossPct != nil || tariffCost != nil {
                    HStack(spacing: 12) {
                        if let tenToEighty {
                            curveStat("10→80%", Format.shortDuration(minutes: max(1, Int(tenToEighty / 60))))
                        }
                        if let idleTail, idleTail >= 60 {
                            curveStat(L10n.text("Idle Tail"), Format.shortDuration(minutes: max(1, Int(idleTail / 60))))
                        }
                        if let lossPct, lossPct >= 1 {
                            curveStat(L10n.text("Estimated Loss"), String(format: "%.0f%%", lossPct))
                        }
                        if let tariffCost {
                            curveStat(L10n.text("Tariff Cost"), String(format: "%.2f %@", tariffCost.cost, preferences.currencySymbol))
                        }
                    }
                }
                Text(L10n.text("Curves are drawn from locally recorded polls of vehicle telemetry, so resolution follows how often the vehicle reported while plugged in."))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                dataConfidenceNote(for: curve.map(\.timestamp))
            }
        }
    }

    private func sessionLabel(_ session: HistoricalChargingSession) -> String {
        var label = Format.dateTimeFormatter.string(from: session.startedAt)
        if session.energyDeliveredKwh > 0 {
            label += String(format: " · %.1f kWh", session.energyDeliveredKwh)
        }
        if session.endedAt == nil {
            label += " · " + L10n.text("Active")
        }
        return label
    }

    /// `nil` suppresses the badge entirely — an `.unknown` type has nothing useful to show.
    private func chargingTypeBadgeColor(_ type: ChargingType) -> Color? {
        switch type {
        case .ac: return .blue
        case .dc: return .orange
        case .wireless: return .purple
        case .none: return .gray
        case .unknown: return nil
        }
    }

    private func curveStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 11, weight: .bold, design: .rounded)).lineLimit(1)
            Text(title).font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: - Trips

    private var distanceChartCard: some View {
        let longest = HistoryInsights.longestTrip(from: trips)
        let correlation = HistoryInsights.temperatureConsumptionCorrelation(from: trips)
        let weekly = HistoryInsights.weeklyDistance(from: trips)
        let bestDay = HistoryInsights.dailyDistance(from: trips).max { $0.distanceKm < $1.distanceKm }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "chart.bar.fill", title: L10n.text("Distance Over Time"), color: .blue)
                Chart(trips) { trip in
                    BarMark(
                        x: .value(L10n.text("Date"), trip.endedAt, unit: .day),
                        y: .value(L10n.text("Distance"), preferences.distanceUnit.convert(km: trip.distanceKm))
                    )
                    .foregroundStyle(HisingenTheme.accent.gradient)
                    .cornerRadius(2)
                }
                .chartYAxisLabel(preferences.distanceUnit.suffix)
                .frame(height: 125)
                .accessibilityLabel(L10n.text("Trip distance history chart"))
                // Only once there's enough span for a weekly view to say something a daily bar
                // chart doesn't already show — under 3 weeks it would just repeat the same bars.
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
                    .frame(height: 70)
                    .accessibilityLabel(L10n.text("Weekly distance chart"))
                }
                if let longest {
                    HStack(spacing: 12) {
                        curveStat(L10n.text("Longest Trip"), Format.distance(km: longest.distanceKm, decimals: 1, unit: preferences.distanceUnit))
                        if let speed = HistoryInsights.averageSpeedKmh(longest) {
                            curveStat(L10n.text("Longest Trip Avg Speed"), String(format: "%.0f km/h", speed))
                        }
                        if let bestDay {
                            curveStat(L10n.text("Best Day"), Format.distance(km: bestDay.distanceKm, decimals: 1, unit: preferences.distanceUnit))
                        }
                    }
                }
                if let correlation, correlation < -0.2 {
                    Text(L10n.text("Colder trips consume more: consumption rises as ambient temperature drops."))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                dataConfidenceNote(for: trips.map(\.endedAt))
            }
        }
    }

    private var tripListCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: L10n.text("Detected Trips"), color: .teal)
                ForEach(trips.prefix(20)) { trip in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Format.dateTimeFormatter.string(from: trip.endedAt))
                                .font(.system(size: 10.5, weight: .semibold))
                            HStack(spacing: 5) {
                                Text(Format.shortDuration(minutes: max(1, Int(trip.duration / 60))))
                                if let speed = HistoryInsights.averageSpeedKmh(trip) {
                                    Text("· " + String(format: "%.0f km/h", speed))
                                }
                                if let temperature = trip.ambientTemperatureCelsius {
                                    Text("· " + Format.temperature(celsius: temperature, unit: preferences.temperatureUnit))
                                }
                                // Only an electric powertrain's stored figure is
                                // kWh/100 km; a combustion vehicle's telemetry row carries
                                // L/100 km, which must not be formatted as energy.
                                if let consumption = trip.averageConsumption,
                                   state.powertrain.hasElectricRange,
                                   HistoryInsights.efficiencyBounds.contains(consumption) {
                                    Text("· " + Format.energyConsumption(
                                        kwhPer100Km: consumption,
                                        unit: preferences.energyConsumptionUnit))
                                }
                            }
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Format.distance(km: trip.distanceKm, decimals: 1, unit: preferences.distanceUnit))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                        if let lat = trip.endLatitude, let lon = trip.endLongitude {
                            Button { openMap(latitude: lat, longitude: lon) } label: {
                                Image(systemName: "map")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.text("Open trip endpoint in Apple Maps"))
                        }
                    }
                    if trip.id != trips.prefix(20).last?.id { Divider().opacity(0.25) }
                }
                Text(L10n.text("Trips are inferred from consecutive odometer or trip-meter changes. They are not a provider trip log and may combine journeys when telemetry is sparse."))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Charging Summary

    /// Sums each session's tariff-aware (day/night-split) cost when a night tariff is
    /// configured, falling back per-session to the flat rate for any session whose samples
    /// can't support the split (too few samples, or recorded before per-sample power existed) —
    /// so the aggregate is never silently short of a session's contribution.
    private func aggregateChargingCost() -> Double {
        guard preferences.nightTariffEnabled else {
            return chargingSessions.reduce(0) { $0 + $1.energyDeliveredKwh * preferences.electricityPricePerKwh }
        }
        return chargingSessions.reduce(0.0) { total, session in
            let samples = database.chargingSamples(for: session.id)
            if let tariff = HistoryInsights.tariffAwareCost(
                from: samples, dayRatePerKwh: preferences.electricityPricePerKwh,
                nightRatePerKwh: preferences.nightElectricityPricePerKwh,
                nightStartHour: preferences.nightTariffStartHour, nightEndHour: preferences.nightTariffEndHour) {
                return total + tariff.cost
            }
            return total + session.energyDeliveredKwh * preferences.electricityPricePerKwh
        }
    }

    private var chargingHistoryCard: some View {
        let energy = chargingSessions.reduce(0) { $0 + $1.energyDeliveredKwh }
        let averagePeak = chargingSessions.isEmpty ? 0 : chargingSessions.reduce(0) { $0 + $1.peakPowerKw } / Double(chargingSessions.count)
        // The 90th-percentile peak is a more honest "typical fast peak" than the plain average:
        // one outlier DC session in an otherwise all-AC history would drag the average up
        // without actually being representative of what a normal session looks like.
        let p90Peak = Statistics.percentile(chargingSessions.map(\.peakPowerKw).filter { $0 > 0 }, 90)
        let perWeek = HistoryInsights.sessionsPerWeek(from: chargingSessions)
        let byTimeOfDay = HistoryInsights.energyByTimeOfDay(from: chargingSessions)
        let dominantTimeOfDay = byTimeOfDay.max { $0.value < $1.value }
        let cost = aggregateChargingCost()
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "bolt.badge.clock.fill", title: L10n.text("Charging Trends"), color: .green)
                KVRow(L10n.text("Sessions"), "\(chargingSessions.count)", symbol: "number")
                if let perWeek {
                    KVRow(L10n.text("Sessions Per Week"), String(format: "%.1f", perWeek), symbol: "calendar.badge.clock")
                }
                KVRow(L10n.text("Estimated Energy Added"), String(format: "%.1f kWh", energy), symbol: "bolt.fill", info: L10n.text("Estimated from stored vehicle telemetry unless a future metered wallbox source is explicitly identified."))
                if averagePeak > 0 {
                    KVRow(L10n.text("Average Observed Peak"), String(format: "%.1f kW", averagePeak), symbol: "waveform.path.ecg")
                }
                if let p90Peak, p90Peak > 0 {
                    KVRow(L10n.text("Typical Fast Peak (p90)"), String(format: "%.1f kW", p90Peak), symbol: "chart.bar.xaxis",
                          info: L10n.text("90th percentile of session peak power — less skewed by one outlier fast-charge than a plain average."))
                }
                if let dominantTimeOfDay, dominantTimeOfDay.value > 0 {
                    KVRow(L10n.text("Mostly Charges"), L10n.text(dominantTimeOfDay.key.rawValue), symbol: "clock.badge")
                }
                KVRow(L10n.text("Estimated Cost"), String(format: "%.2f %@", cost, preferences.currencySymbol), symbol: "creditcard",
                      info: preferences.nightTariffEnabled
                        ? L10n.text("Day/night tariff applied per session from its actual charging times, not a flat multiply.")
                        : nil)
            }
        }
    }

    // MARK: - Driving Trends

    private var efficiencyChartCard: some View {
        let average = HistoryInsights.averageEfficiency(of: efficiencyPoints)
        let median = Statistics.median(efficiencyPoints.map(\.kwhPer100Km))
        let segmentByID = gapSegmentIndex(of: efficiencyPoints, timestamp: \.timestamp)
        let seasonal = HistoryInsights.seasonalEfficiency(from: telemetryRecords)
        let slopePerDay = HistoryInsights.efficiencyTrendSlopePerDay(from: efficiencyPoints)
        // A 5-point trailing average smooths out the point-to-point noise a raw consumption
        // series always has (one short cold drive, one motorway cruise) so the underlying trend
        // reads clearly without needing to squint at the raw line.
        let smoothed: [SmoothedPoint] = efficiencyPoints.count >= 8
            ? zip(efficiencyPoints, Statistics.movingAverage(efficiencyPoints.map(\.kwhPer100Km), windowSize: 5))
                .map { point, value in SmoothedPoint(id: point.id, timestamp: point.timestamp, value: value) }
            : []
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "gauge.high", title: L10n.text("Consumption Trend"), color: .mint)
                    Spacer()
                    if let average {
                        Text(preferences.energyConsumptionUnit.format(kwhPer100Km: average))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Chart {
                    ForEach(efficiencyPoints) { point in
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
                    ForEach(smoothed) { point in
                        LineMark(
                            x: .value(L10n.text("Date"), point.timestamp),
                            y: .value(L10n.text("Smoothed"), point.value)
                        )
                        .foregroundStyle(HisingenTheme.chartInfo.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .interpolationMethod(.catmullRom)
                    }
                }
                .frame(height: 110)
                .accessibilityLabel(L10n.text("Energy consumption trend chart"))
                if let median, let average, abs(median - average) > 0.5 {
                    Text(L10n.format("Typical drive: %@ (average is pulled by outlier trips)",
                                     preferences.energyConsumptionUnit.format(kwhPer100Km: median)))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                if seasonal.coldAverage != nil || seasonal.warmAverage != nil {
                    HStack(spacing: 12) {
                        if let cold = seasonal.coldAverage {
                            curveStat(L10n.text("Cold (<5°C)"), preferences.energyConsumptionUnit.format(kwhPer100Km: cold))
                        }
                        if let mild = seasonal.mildAverage {
                            curveStat(L10n.text("Mild (5–15°C)"), preferences.energyConsumptionUnit.format(kwhPer100Km: mild))
                        }
                        if let warm = seasonal.warmAverage {
                            curveStat(L10n.text("Warm (>15°C)"), preferences.energyConsumptionUnit.format(kwhPer100Km: warm))
                        }
                    }
                }
                if let slopePerDay {
                    let monthlySlope = slopePerDay * 30
                    // Number pre-formatted with the plain (locale-invariant) `String(format:)`
                    // overload and passed as a `%@` string, not a numeric argument to
                    // `L10n.format` — matching `Format.swift`'s convention — so a comma-decimal
                    // system locale can't turn this into "Trending +0,42 kWh/100km per month".
                    let sign = monthlySlope >= 0 ? "+" : ""
                    let numberText = String(format: "%.2f", monthlySlope)
                    Text(L10n.format("Trending %@%@ kWh/100km per month", sign, numberText))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(monthlySlope > 0.5 ? HisingenTheme.semanticWarning : .secondary)
                }
                Text(L10n.text("Vehicle-reported consumption between charges. Short drives and climate use raise it; motorway cruising lowers it."))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                dataConfidenceNote(for: efficiencyPoints.map(\.timestamp))
            }
        }
    }

    /// Only surfaced when confidence is low, so a well-populated chart doesn't carry a
    /// permanent "trust me" caption nobody needs to read.
    private func dataConfidenceNote(for timestamps: [Date]) -> some View {
        let coverage = HistoryInsights.dataCoverage(timestamps: timestamps)
        return Group {
            if coverage.confidence == .low || coverage.confidence == .insufficient {
                Text(L10n.format("Limited data (%@ points) — treat this trend as indicative, not conclusive.", "\(coverage.sampleCount)"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(HisingenTheme.semanticWarning.opacity(0.85))
            }
        }
    }

    /// Maps each point's id to a segment index so a chart can pass it as a `series:` value —
    /// Swift Charts only breaks a `LineMark` at a gap when consecutive points belong to
    /// different series, not automatically from a large timestamp delta.
    private func gapSegmentIndex<T: Identifiable>(of points: [T], maxGap: TimeInterval = HistoryInsights.defaultChartGapThreshold,
                                                   timestamp: (T) -> Date) -> [T.ID: Int] {
        let runs = HistoryInsights.segments(of: points, maxGap: maxGap, timestamp: timestamp)
        var result: [T.ID: Int] = [:]
        for (index, run) in runs.enumerated() {
            for point in run { result[point.id] = index }
        }
        return result
    }

    private var odometerChartCard: some View {
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
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Chart(odometerPoints) { point in
                    LineMark(
                        x: .value(L10n.text("Date"), point.timestamp),
                        y: .value(L10n.text("Odometer"), convertDistance(point.odometerKm)),
                        series: .value(L10n.text("Segment"), segmentByID[point.id] ?? 0)
                    )
                    .foregroundStyle(HisingenTheme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)
                }
                .chartYAxisLabel(preferences.distanceUnit.suffix)
                .frame(height: 110)
                .accessibilityLabel(L10n.text("Odometer history chart"))
                if monthly.count >= 2 {
                    Chart(monthly) { bucket in
                        BarMark(
                            x: .value(L10n.text("Month"), bucket.month, unit: .month),
                            y: .value(L10n.text("Distance"), preferences.distanceUnit.convert(km: bucket.distanceKm))
                        )
                        .foregroundStyle(Color.indigo.opacity(0.6))
                        .cornerRadius(2)
                    }
                    .chartYAxisLabel(preferences.distanceUnit.suffix)
                    .frame(height: 80)
                    .accessibilityLabel(L10n.text("Monthly mileage chart"))
                }
                if let kmPerDay {
                    curveStat(L10n.text("Average Daily Distance"), Format.distance(km: kmPerDay, decimals: 1, unit: preferences.distanceUnit) + "/" + L10n.text("day"))
                }
                Text(L10n.text("Monthly totals and the daily average use all recorded odometer history, independent of the period selector above."))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                dataConfidenceNote(for: allTimeOdometerPoints.map(\.timestamp))
            }
        }
    }

    // MARK: - Battery Health

    private var batteryHealthCard: some View {
        let records = Array(batteryHealthRecords.reversed())
        let latest = batteryHealthRecords.first
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "heart.text.square", title: L10n.text("Battery Health Trend"), color: .pink)
                    Spacer()
                    if let latest {
                        Text(String(format: "%.1f%%", latest.stateOfHealthPct))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                if records.count >= 2 {
                    Chart(records) { record in
                        LineMark(
                            x: .value(L10n.text("Date"), record.timestamp),
                            y: .value(L10n.text("State of Health"), record.stateOfHealthPct)
                        )
                        .foregroundStyle(HisingenTheme.chartHealth)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value(L10n.text("Date"), record.timestamp),
                            y: .value(L10n.text("State of Health"), record.stateOfHealthPct)
                        )
                        .symbolSize(16)
                        .foregroundStyle(HisingenTheme.chartHealth.opacity(0.85))
                    }
                    .chartYScale(domain: sohDomain(records))
                    .chartYAxisLabel("%")
                    .frame(height: 115)
                    .accessibilityLabel(L10n.text("Battery health trend chart"))
                }
                if let latest {
                    KVRow(L10n.text("Degradation"),
                          String(format: "%.1f%%", latest.degradationPct), symbol: "arrow.down.right")
                    KVRow(L10n.text("Estimated Usable Capacity"),
                          String(format: "%.1f kWh", latest.effectiveUsableKwh), symbol: "battery.100")
                    KVRow(L10n.text("Recorded At Odometer"),
                          Format.distance(km: latest.odometerKm, decimals: 0, unit: preferences.distanceUnit),
                          symbol: "road.lanes")
                    if let slope = HistoryInsights.batteryHealthTrend(from: batteryHealthRecords).stateOfHealthPctPer10kKm,
                       batteryHealthRecords.count >= 3 {
                        KVRow(L10n.text("Trend"), String(format: "%.2f%% / 10,000 km", slope), symbol: "chart.line.downtrend.xyaxis",
                              info: L10n.text("Slope of a straight-line fit through the recorded milestones. A small sample or a recent measurement-method change can swing this significantly."))
                        if let projected = HistoryInsights.projectedStateOfHealth(from: batteryHealthRecords, atOdometerKm: latest.odometerKm + 10_000) {
                            KVRow(L10n.text("Projected in +10,000 km"), String(format: "%.1f%%", projected), symbol: "arrow.turn.right.up",
                                  info: L10n.text("A linear projection from the current trend, not a manufacturer estimate. Real degradation is rarely linear."))
                        }
                    }
                    KVRow(latest.measurementSource == "calculated-v2"
                          ? L10n.text("Calculated estimate")
                          : L10n.text("Legacy estimate"),
                          "\(batteryHealthRecords.count)",
                          symbol: "questionmark.circle",
                          info: L10n.text("This is a calculated trend from observed telemetry, not a battery-management-system measurement. Rows are only recorded when the estimate moves meaningfully."))
                }
                Text(L10n.text("Always shows all recorded history — the period selector above doesn't apply here, since state of health moves over months, not days."))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                dataConfidenceNote(for: batteryHealthRecords.map(\.timestamp))
            }
        }
    }

    private func sohDomain(_ records: [BatteryHealthRecord]) -> ClosedRange<Double> {
        let values = records.map(\.stateOfHealthPct)
        let minimum = (values.min() ?? 90) - 0.75
        return max(50, minimum)...100
    }

    // MARK: - Cabin Air Quality

    /// Trend view over locally recorded CleanZone samples. The provider APIs expose no
    /// air-quality history of their own; this is reconstructed from what Hisingen stored
    /// during normal refreshes (see `VehicleDatabase.recordAirQuality`).
    private var airQualityCard: some View {
        let chronological = airQualityRecords.sorted { $0.timestamp < $1.timestamp }
        let aqiPoints = chronological.compactMap { record -> (record: AirQualityRecord, aqi: Double)? in
            record.airQualityIndex.map { (record, $0) }
        }
        let pm25Points = chronological.compactMap { record -> (record: AirQualityRecord, pm25: Double)? in
            record.particulateMatter25.map { (record, $0) }
        }
        let latest = chronological.last
        let aqiSegmentByID = Dictionary(uniqueKeysWithValues:
            HistoryInsights.segments(of: aqiPoints, maxGap: HistoryInsights.defaultChartGapThreshold, timestamp: { $0.record.timestamp })
                .enumerated().flatMap { index, run in run.map { ($0.record.id, index) } })
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "wind", title: L10n.text("Cabin Air Quality Trend"), color: .teal)
                    Spacer()
                    if let latestAqi = latest?.airQualityIndex {
                        Text("\(latestAqi) AQI")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                if !aqiPoints.isEmpty {
                    Chart(aqiPoints, id: \.record.id) { item in
                        LineMark(
                            x: .value(L10n.text("Date"), item.record.timestamp),
                            y: .value(L10n.text("Air Quality Index"), item.aqi),
                            series: .value(L10n.text("Segment"), aqiSegmentByID[item.record.id] ?? 0)
                        )
                        .foregroundStyle(Color.teal)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                        RuleMark(y: .value(L10n.text("Moderate Threshold"), 50))
                            .foregroundStyle(.orange.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    .chartYAxisLabel(L10n.text("AQI"))
                    .frame(height: 105)
                    .accessibilityLabel(L10n.text("Air quality index trend chart"))
                }
                if pm25Points.count >= 2 {
                    Chart(pm25Points, id: \.record.id) { item in
                        AreaMark(
                            x: .value(L10n.text("Date"), item.record.timestamp),
                            y: .value(L10n.text("PM2.5"), item.pm25)
                        )
                        .foregroundStyle(.linearGradient(colors: [Color.teal.opacity(0.25), Color.teal.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    }
                    .chartYAxisLabel("µg/m³")
                    .frame(height: 80)
                    .accessibilityLabel(L10n.text("Cabin particulate matter trend chart"))
                }
                if let filter = latest?.filterRemainingPercent {
                    KVRow(L10n.text("HEPA Filter Life"), "\(filter)%", symbol: "allergens",
                          valueWarning: filter <= 20)
                }
                Text(L10n.text("Recorded from vehicle-reported CleanZone readings during normal refreshes. The provider keeps no history of its own, so coverage depends on how often Hisingen was running."))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                dataConfidenceNote(for: chronological.map(\.timestamp))
            }
        }
    }

    // MARK: - Automation

    private var automationHistoryCard: some View {
        let stats = commandStatistics
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "command", title: L10n.text("Automation & Commands"), color: .orange)
                    Spacer()
                    if let rate = stats.successRatePct {
                        Text(String(format: "%.0f%%", rate))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(rate >= 90 ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning)
                    }
                }
                if stats.totalCount > 0 {
                    HStack(spacing: 12) {
                        curveStat(L10n.text("Success Rate"), stats.successRatePct.map { String(format: "%.0f%%", $0) } ?? "—")
                        if let mostUsed = stats.mostUsedCommand {
                            curveStat(L10n.text("Most Used"), mostUsed.replacingOccurrences(of: "-", with: " ").capitalized)
                        }
                    }
                }
                ForEach(commands.prefix(12)) { record in
                    HStack {
                        Image(systemName: record.status == "failed" ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(record.status == "failed" ? HisingenTheme.semanticCritical : HisingenTheme.semanticGood)
                        Text(record.command.replacingOccurrences(of: "-", with: " ").capitalized)
                            .font(.system(size: 10.5, weight: .medium))
                        Spacer()
                        Text(record.executedAt, style: .relative)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .help(record.errorMessage ?? record.status.capitalized)
                }
                dataConfidenceNote(for: commands.map(\.executedAt))
            }
        }
    }

    private var emptyCard: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line").font(.system(size: 22)).foregroundStyle(.secondary)
                Text(L10n.text("No history recorded yet")).font(.system(size: 12, weight: .semibold))
                Text(L10n.text("Hisingen records meaningful odometer changes, charging sessions and remote-command outcomes locally as new telemetry arrives."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helpers

    private func convertDistance(_ km: Double) -> Double {
        preferences.distanceUnit == .kilometers ? km : km * 0.621371
    }

    private func exportCSV(_ contents: String, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Hisingen-\(name)-\(state.vin.suffix(6)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func openMap(latitude: Double, longitude: Double) {
        // User-initiated "Open in Apple Maps": the coordinates are the feature payload,
        // transmitted over HTTPS at explicit request (see Support/MapLinks).
        guard let url = MapLinks.appleMapsPin(latitude: latitude, longitude: longitude) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Fuel Entries (hybrid / combustion)

    private var fuelEntrySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Log Fuel Fill-Up")).font(.system(size: 13, weight: .semibold))
            LabeledField(title: L10n.text("Volume (litres)"), text: $fuelLitersText)
            LabeledField(title: L10n.text("Price per litre"), text: $fuelPriceText)
            LabeledField(title: L10n.text("Odometer (km), optional"), text: $fuelOdometerText)
            HStack {
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) { showFuelSheet = false }
                Button(L10n.text("Save")) {
                    guard let liters = Double(fuelLitersText.replacingOccurrences(of: ",", with: ".")),
                          liters > 0,
                          let price = Double(fuelPriceText.replacingOccurrences(of: ",", with: ".")) else { return }
                    let odo = Double(fuelOdometerText.replacingOccurrences(of: ",", with: "."))
                    _ = database.addFuelEntry(vin: state.vin, date: Date(), liters: liters,
                                              pricePerLiter: price, odometerKm: odo)
                    fuelLitersText = ""; fuelPriceText = ""; fuelOdometerText = ""
                    showFuelSheet = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Text(L10n.text("Fill-ups are stored locally and included in lifetime cost-per-distance estimates."))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 300)
    }

    private var recentFillsCard: AnyView {
        guard !fuelEntries.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "drop.fill", title: L10n.text("Fuel Fill-Ups"), color: .mint)
                ForEach(fuelEntries.prefix(8)) { entry in
                    HStack {
                        Text(Format.dateFormatter.string(from: entry.date))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f L · %.2f %@", entry.liters,
                                    entry.liters * entry.pricePerLiter, preferences.currencySymbol))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                        Button {
                            database.deleteFuelEntry(id: entry.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.text("Delete fill-up"))
                    }
                    if entry.id != fuelEntries.prefix(8).last?.id { Divider().opacity(0.25) }
                }
            }
        })
    }

    private struct LabeledField: View {
        let title: String
        @Binding var text: String
        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
    }

    /// Cabin temperature trend from digital-twin climate readings (Polestar 3/4-class
    /// platforms). Hidden entirely on vehicles that never report interior temperature.
    private var cabinClimateCard: AnyView {
        let chronological = cabinClimateRecords.sorted { $0.timestamp < $1.timestamp }
        guard let latest = chronological.last?.interiorCelsius else { return AnyView(EmptyView()) }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "thermometer.medium",
                               title: L10n.text("Cabin Temperature Trend"), color: .orange)
                    Spacer()
                    Text(Format.temperature(celsius: latest, unit: preferences.temperatureUnit))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Chart(chronological) { record in
                    LineMark(
                        x: .value(L10n.text("Date"), record.timestamp),
                        y: .value(L10n.text("Interior"), record.interiorCelsius ?? 0)
                    )
                    .foregroundStyle(HisingenTheme.chartAttention)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)
                    if let requested = record.requestedCelsius {
                        LineMark(
                            x: .value(L10n.text("Date"), record.timestamp),
                            y: .value(L10n.text("Setpoint"), requested)
                        )
                        .foregroundStyle(HisingenTheme.accent.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .frame(height: 100)
                .accessibilityLabel(L10n.text("Cabin temperature trend chart"))
                Text(L10n.text("Recorded while the vehicle reported climate status. Setpoints appear dashed; gaps mean the car was asleep or not reporting."))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        })
    }
}
