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

    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            periodPicker
            overviewCard
            if !trips.isEmpty {
                distanceChartCard
                tripListCard
            }
            if !chargingSessions.isEmpty { chargingHistoryCard }
            if !commands.isEmpty { automationHistoryCard }
            if trips.isEmpty && chargingSessions.isEmpty && commands.isEmpty { emptyCard }
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
                    Button {
                        exportTrips()
                    } label: {
                        Label(L10n.text("Export"), systemImage: "square.and.arrow.up")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(trips.isEmpty)
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

    private func exportTrips() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Hisingen-Trips-\(state.vin.suffix(6)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? database.exportTripsCSV(for: state.vin).write(to: url, atomically: true, encoding: .utf8)
    }

    private func openMap(latitude: Double, longitude: Double) {
        guard let url = URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)") else { return }
        NSWorkspace.shared.open(url)
    }
}
