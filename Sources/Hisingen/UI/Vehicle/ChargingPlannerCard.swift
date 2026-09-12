import SwiftUI

/// Dashboard card for the opt-in Smart Charging Planner. Fetches (via the shared price
/// service — cached, one fetch per day after publication) today's and tomorrow's Swedish
/// spot prices for the selected zone, then shows the cheapest contiguous whole-hour
/// window that covers the energy still needed between the current battery level and the
/// set charge limit, with the price of charging right now as the baseline, a 48-hour
/// price outlook chart, and a freshness line.
@MainActor
struct ChargingPlannerCard: View {
    let state: VehicleState

    @Environment(\.preferencesStore) private var preferences
    @State private var points: [ElectricityPricePoint] = []
    @State private var hasLoaded = false
    @State private var fetchedAt: Date?

    private let service = ElectricityPriceService.shared

    private var zone: ElspotZone { preferences.electricityPriceZone }

    private var plannerTaskID: String {
        "\(zone.rawValue)|\(state.identity.vin)|\(state.freshness.fetchedAt.timeIntervalSince1970)"
    }

    var body: some View {
        cardContent
            .task(id: plannerTaskID) {
                let fetched = await service.prices(for: zone)
                guard !Task.isCancelled else { return }
                points = fetched
                fetchedAt = await service.fetchedAt(for: zone)
                hasLoaded = true
            }
    }

    @ViewBuilder
    private var cardContent: some View {
        if neededEnergyKwh > 0.5 {
            plannerBody
        }
    }

    /// Grid-side energy still missing to reach the charge limit (losses included). At or
    /// above the limit there is nothing to plan, so the card disappears entirely rather
    /// than rendering an empty placeholder.
    private var neededEnergyKwh: Double {
        ChargingPlannerSupport.neededEnergyKwh(
            batteryPercentage: state.energy.batteryPercentage,
            targetPercentage: state.energy.targetPercentage,
            usableCapacityKwh: preferences.vehicleSpecificationOverride(for: state.identity.vin)?.usableBatteryCapacityKwh
                ?? state.configuredUsableBatteryCapacityKwh
        )
    }

    private var plannerPowerKw: Double {
        ChargingPlannerSupport.powerKw(
            liveWatts: state.energy.powerWatts,
            isCharging: state.isCharging,
            configuredKw: preferences.electricityChargerPowerKw
        )
    }

    private var plannerBody: some View {
        let model = planModel
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "chart.bar.fill", title: L10n.text("Charging Planner"), color: .orange)

                if let model {
                    Text(model.windowLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(model.detailLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let savingsLine = model.savingsLine {
                        HStack(spacing: 5) {
                            Image(systemName: model.savings > 0 ? "arrow.down.circle.fill" : "clock")
                                .font(.system(size: 10))
                                .foregroundStyle(model.savings > 0 ? HisingenTheme.semanticGood : .secondary)
                            Text(savingsLine)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(model.savings > 0 ? HisingenTheme.semanticGood : .secondary)
                        }
                    }
                    PriceCurveView(points: points, plan: plan)
                } else if !hasLoaded && points.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(L10n.text("Loading prices…"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if !state.energy.schedules.isEmpty {
                    Label(L10n.text("The car has its own charging schedules — the planner does not use them"),
                          systemImage: "calendar.badge.exclamationmark")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 0) {
                    Text(L10n.text("Spot prices exclude taxes and grid fees"))
                    Text(" · \(zone.rawValue) · elprisetjustnu.se")
                    if let fetchedAt {
                        Text(" · " + L10n.format("fetched %@", Format.shortTime(date: fetchedAt)))
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var plan: ChargingPlan? {
        ChargingPlanner.cheapestWindow(
            prices: points,
            now: Date(),
            energyKwh: neededEnergyKwh,
            chargerPowerKw: plannerPowerKw
        )
    }

    private var statusMessage: String {
        guard let horizon = ChargingPlanner.dataHorizonEnd(prices: points) else {
            return L10n.text("Prices unavailable right now")
        }
        // Distinguish "tomorrow's file has not landed yet" from "the outlook can never
        // fit this charge" — a 54 h charge on a weak outlet will not fit into even a
        // complete two-day outlook, and blaming the publication time would be a lie.
        let now = Date()
        let planHours = max(1.0, (neededEnergyKwh / plannerPowerKw).rounded(.up))
        let dataComplete = horizon >= ElectricityPriceService.requiredCoverageEnd(after: now)
        if dataComplete && horizon.timeIntervalSince(now) < planHours * 3_600 {
            return L10n.format("A %d h charge is longer than the price outlook", Int(planHours))
        }
        return L10n.text("Tomorrow's prices arrive after 14:15")
    }

    private struct PlannerModel {
        var windowLabel: String
        var detailLine: String
        var savingsLine: String?
        var savings: Double
    }

    private var planModel: PlannerModel? {
        guard neededEnergyKwh > 0.5,
              let target = state.energy.targetPercentage else { return nil }

        let now = Date()
        guard let plan = self.plan else { return nil }

        let calendar = ElectricityPriceService.stockholmCalendar
        let startDay = calendar.startOfDay(for: plan.start)
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
        let dayLabel: String
        if startDay == today {
            dayLabel = L10n.text("Today")
        } else if startDay == tomorrow {
            dayLabel = L10n.text("Tomorrow")
        } else {
            dayLabel = Format.shortDate(date: plan.start)
        }
        let windowLabel = "\(dayLabel) \(Format.shortTime(date: plan.start)) – \(Format.shortTime(date: plan.end))"

        let average = Format.currency(plan.averagePrice, symbol: "kr") + "/kWh"
        let current = Format.currency(plan.currentPrice, symbol: "kr") + "/kWh"
        let detailLine = L10n.format(
            "Charge %@ over %d h to reach %d%% — average %@, now %@",
            Format.energyKwh(plan.energyKwh),
            Int(plan.hours),
            target,
            average,
            current
        )

        let savingsLine = plan.savings > 0.5
            ? L10n.format("Saves %@", Format.currency(plan.savings, symbol: "kr"))
            : L10n.text("Charging now is cheapest")

        return PlannerModel(
            windowLabel: windowLabel,
            detailLine: detailLine,
            savingsLine: savingsLine,
            savings: plan.savings
        )
    }
}
