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

    private enum HistoryPeriod: String, CaseIterable, Identifiable {
        case week = "7 Days"
        case month = "30 Days"
        case all = "All"
        var id: String { rawValue }
        var days: Int? { self == .week ? 7 : (self == .month ? 30 : nil) }
    }

    private var cutoff: Date? {
        period.days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
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

    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            periodPicker
            overviewCard
            if selectedSession != nil && !selectedSessionCurve.isEmpty { chargingCurveCard }
            if !trips.isEmpty {
                distanceChartCard
                tripListCard
            }
            if !chargingSessions.isEmpty { chargingHistoryCard }
            if efficiencyPoints.count >= 3 { efficiencyChartCard }
            if odometerPoints.count >= 3 { odometerChartCard }
            if !batteryHealthRecords.isEmpty { batteryHealthCard }
            if !commands.isEmpty { automationHistoryCard }
            if trips.isEmpty && chargingSessions.isEmpty && commands.isEmpty
                && batteryHealthRecords.isEmpty { emptyCard }
        }
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
    }

    private var overviewCard: some View {
        let totalDistance = trips.reduce(0) { $0 + $1.distanceKm }
        let drivingTime = trips.reduce(0) { $0 + $1.duration }
        let energy = chargingSessions.reduce(0) { $0 + $1.energyDeliveredKwh }
        let estimatedCost = energy * preferences.electricityPricePerKwh
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "chart.xyaxis.line", title: L10n.text("History Overview"), color: .indigo)
                    Spacer()
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
            Button(L10n.text("Telemetry")) {
                exportCSV(database.exportTelemetryCSV(for: state.vin), name: "Telemetry")
            }
            .disabled(telemetryRecords.isEmpty)
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

    // MARK: - Charging Curve

    private var chargingCurveCard: some View {
        let session = selectedSession
        let curve = selectedSessionCurve
        let peak = curve.compactMap(\.powerKw).max()
        let socGain = (curve.last?.soc ?? 0) - (curve.first?.soc ?? 0)
        let durationMinutes = session.map { max(0, Int(($0.endedAt ?? Date()).timeIntervalSince($0.startedAt) / 60)) }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "chart.dots.scatter", title: L10n.text("Charging Curve"), color: .green)
                    Spacer()
                    Picker(L10n.text("Session"), selection: Binding(
                        get: { selectedSession?.id },
                        set: { selectedSessionID = $0 }
                    )) {
                        ForEach(chargingSessions.prefix(50)) { item in
                            Text(sessionLabel(item)).tag(item.id as String?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
                Chart(curve) { point in
                    AreaMark(
                        x: .value(L10n.text("Time"), point.timestamp),
                        y: .value(L10n.text("Charge level"), point.soc)
                    )
                    .foregroundStyle(.linearGradient(colors: [Color.green.opacity(0.28), Color.green.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                    LineMark(
                        x: .value(L10n.text("Time"), point.timestamp),
                        y: .value(L10n.text("Charge level"), point.soc)
                    )
                    .foregroundStyle(Color.green)
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
                        .foregroundStyle(.linearGradient(colors: [Color.orange.opacity(0.25), Color.orange.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                        LineMark(
                            x: .value(L10n.text("Time"), point.timestamp),
                            y: .value(L10n.text("Power"), point.powerKw ?? 0)
                        )
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                        .interpolationMethod(.catmullRom)
                    }
                    .chartYAxisLabel("kW")
                    .frame(height: 80)
                    .accessibilityLabel(L10n.text("Charging curve power chart"))
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
                Text(L10n.text("Curves are drawn from locally recorded polls of vehicle telemetry, so resolution follows how often the vehicle reported while plugged in."))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private func curveStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 11, weight: .bold, design: .rounded)).lineLimit(1)
            Text(title).font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: - Trips

    private var distanceChartCard: some View {
        Card {
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
                                if let temperature = trip.ambientTemperatureCelsius {
                                    Text("· " + Format.temperature(celsius: temperature, unit: preferences.temperatureUnit))
                                }
                                if let consumption = trip.averageConsumption,
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

    private var chargingHistoryCard: some View {
        let energy = chargingSessions.reduce(0) { $0 + $1.energyDeliveredKwh }
        let averagePeak = chargingSessions.isEmpty ? 0 : chargingSessions.reduce(0) { $0 + $1.peakPowerKw } / Double(chargingSessions.count)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "bolt.badge.clock.fill", title: L10n.text("Charging Trends"), color: .green)
                KVRow(L10n.text("Sessions"), "\(chargingSessions.count)", symbol: "number")
                KVRow(L10n.text("Estimated Energy Added"), String(format: "%.1f kWh", energy), symbol: "bolt.fill", info: L10n.text("Estimated from stored vehicle telemetry unless a future metered wallbox source is explicitly identified."))
                if averagePeak > 0 {
                    KVRow(L10n.text("Average Observed Peak"), String(format: "%.1f kW", averagePeak), symbol: "waveform.path.ecg")
                }
                KVRow(L10n.text("Estimated Cost"), String(format: "%.2f %@", energy * preferences.electricityPricePerKwh, preferences.currencySymbol), symbol: "creditcard")
            }
        }
    }

    // MARK: - Driving Trends

    private var efficiencyChartCard: some View {
        let average = HistoryInsights.averageEfficiency(of: efficiencyPoints)
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
                Chart(efficiencyPoints) { point in
                    LineMark(
                        x: .value(L10n.text("Date"), point.timestamp),
                        y: .value(L10n.text("Consumption"), point.kwhPer100Km)
                    )
                    .foregroundStyle(Color.mint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)
                    PointMark(
                        x: .value(L10n.text("Date"), point.timestamp),
                        y: .value(L10n.text("Consumption"), point.kwhPer100Km)
                    )
                    .symbolSize(14)
                    .foregroundStyle(Color.mint.opacity(0.85))
                }
                .frame(height: 110)
                .accessibilityLabel(L10n.text("Energy consumption trend chart"))
                Text(L10n.text("Vehicle-reported consumption between charges. Short drives and climate use raise it; motorway cruising lowers it."))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var odometerChartCard: some View {
        let covered = HistoryInsights.distanceCovered(from: odometerPoints)
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
                        y: .value(L10n.text("Odometer"), convertDistance(point.odometerKm))
                    )
                    .foregroundStyle(Color.indigo)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)
                }
                .chartYAxisLabel(preferences.distanceUnit.suffix)
                .frame(height: 110)
                .accessibilityLabel(L10n.text("Odometer history chart"))
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
                        .foregroundStyle(Color.pink)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value(L10n.text("Date"), record.timestamp),
                            y: .value(L10n.text("State of Health"), record.stateOfHealthPct)
                        )
                        .symbolSize(16)
                        .foregroundStyle(Color.pink.opacity(0.85))
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
                    KVRow(latest.measurementSource == "calculated-v2"
                          ? L10n.text("Calculated estimate")
                          : L10n.text("Legacy estimate"),
                          "\(batteryHealthRecords.count)",
                          symbol: "questionmark.circle",
                          info: L10n.text("This is a calculated trend from observed telemetry, not a battery-management-system measurement. Rows are only recorded when the estimate moves meaningfully."))
                }
            }
        }
    }

    private func sohDomain(_ records: [BatteryHealthRecord]) -> ClosedRange<Double> {
        let values = records.map(\.stateOfHealthPct)
        let minimum = (values.min() ?? 90) - 0.75
        return max(50, minimum)...100
    }

    // MARK: - Automation

    private var automationHistoryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "command", title: L10n.text("Automation & Commands"), color: .orange)
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
        guard let url = URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)") else { return }
        NSWorkspace.shared.open(url)
    }
}
