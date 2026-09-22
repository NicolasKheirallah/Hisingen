import SwiftUI

extension HistoryDashboardView {
    /// A period instrument for History. Every mark is derived from the selected range, so the
    /// composition stays useful with one trip, many trips, or none without inventing activity.
    var awardHistoryOverview: some View {
        let totalDistance = aggregateTrips.reduce(0) { $0 + $1.distanceKm }
        let drivingTime = aggregateTrips.reduce(0) { $0 + $1.duration }
        let energy = chargingSessions.reduce(0) { $0 + $1.energyDeliveredKwh }
        let cost = aggregateChargingCost()

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("History Overview"))
                        .hisType(.micro, weight: .bold)
                        .foregroundStyle(HisingenTheme.accent)
                    Text(Format.distance(km: totalDistance, decimals: 1, unit: preferences.distanceUnit))
                        .hisType(.displayLarge, weight: .bold)
                        .monospacedDigit()
                    Text(L10n.text(period.rawValue))
                        .hisType(.label, weight: .medium)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
                Spacer()
                exportMenu
            }

            tripDistanceBars

            HStack(spacing: 0) {
                historyReading(value: Format.count(aggregateTrips.count), label: L10n.text("Trips"))
                Divider().frame(height: 40)
                historyReading(value: Format.shortDuration(minutes: Int(drivingTime / 60)), label: L10n.text("Driving"))
                Divider().frame(height: 40)
                historyReading(value: Format.energyKwh(energy), label: L10n.text("Estimated Energy"))
                Divider().frame(height: 40)
                historyReading(
                    value: cost.map { Format.currency($0.amount, symbol: $0.currency) } ?? "–",
                    label: L10n.text("Estimated Cost")
                )
            }
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Divider() }
            .overlay(alignment: .bottom) { Divider() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var tripDistanceBars: some View {
        let recent = Array(aggregateTrips.sorted { $0.endedAt < $1.endedAt }.suffix(14))
        let maximum = recent.map(\.distanceKm).max() ?? 0
        return AwardTripBars(trips: recent, maximum: max(maximum, 1),
                             distanceUnit: preferences.distanceUnit)
    }

    private func historyReading(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .hisType(.subhead, weight: .bold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .hisType(.micro, weight: .medium)
                .foregroundStyle(HisingenTheme.inkMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The last fourteen trips as a bar strip. A bar answers with its detail line when selected:
/// pointer click or keyboard activation both select, so the strip is reachable without a
/// mouse. Only one bar is selected at a time; selecting is reading, it changes nothing.
@MainActor
private struct AwardTripBars: View {
    let trips: [TripHistoryEntry]
    let maximum: Double
    let distanceUnit: DistanceUnit

    @State private var selectedID: String?
    @FocusState private var focusedID: String?

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 5) {
                if trips.isEmpty {
                    Text(L10n.text("No trips were recorded in this period."))
                        .hisType(.label)
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ForEach(trips) { trip in
                        bar(for: trip)
                    }
                }
            }
            .frame(height: 68)

            if let detail = selectedDetail {
                Text(detail)
                    .hisType(.label, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(HisingenTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: trips) { _, trips in
            // A period switch replaces the trips; a selection that no longer names one of
            // them would keep a stale detail line on screen.
            if let selectedID, !trips.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        }
    }

    private var selectedDetail: String? {
        guard let selectedID, let trip = trips.first(where: { $0.id == selectedID }) else { return nil }
        return L10n.format("%@, %@",
                           Format.dateFormatter.string(from: trip.endedAt),
                           Format.distance(km: trip.distanceKm, decimals: 1, unit: distanceUnit))
    }

    private func bar(for trip: TripHistoryEntry) -> some View {
        let isSelected = trip.id == selectedID
        let isLatest = trip.id == trips.last?.id
        return Button {
            selectedID = isSelected ? nil : trip.id
        } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(HisingenTheme.accent.opacity(isSelected || isLatest ? 1 : 0.42))
                .frame(maxWidth: .infinity)
                .frame(height: max(5, 68 * trip.distanceKm / max(maximum, 1)))
        }
        .buttonStyle(.pressable)
        .focusable()
        .focused($focusedID, equals: trip.id)
        .onSubmit { selectedID = isSelected ? nil : trip.id }
        .help(Format.distance(km: trip.distanceKm, decimals: 1, unit: distanceUnit))
        .accessibilityLabel(
            L10n.format("%@, %@",
                        Format.dateFormatter.string(from: trip.endedAt),
                        Format.distance(km: trip.distanceKm, decimals: 1, unit: distanceUnit))
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
