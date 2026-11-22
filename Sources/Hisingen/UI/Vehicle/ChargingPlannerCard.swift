import SwiftUI

/// Dashboard card for the opt-in Smart Charging Planner. Reads (via the shared price
/// provider – cached, one fetch per day after publication) today's and tomorrow's prices
/// from the connected provider (Tibber), or the Swedish spot prices for the selected zone
/// when none is connected or it cannot answer, then shows the cheapest contiguous whole-hour
/// window that covers the energy still needed between the current battery level and the
/// set charge limit, with the price of charging right now as the baseline, a 48-hour
/// price outlook chart, and a freshness line.
@MainActor
struct ChargingPlannerCard: View {
    let state: VehicleState
    var showsHomePlan = true
    var onOpenPlanner: (() -> Void)? = nil

    static func isAvailable(state: VehicleState, preferences: PreferencesStore) -> Bool {
        TabItemAvailability.of(
            .controlsChargingPlanner,
            state: state,
            enabledFeatures: preferences.features.enabled,
            plannerAvailable: preferences.smartChargingPlannerAvailable
        ) == .drawable
    }

    @Environment(\.preferencesStore) private var preferences
    @Environment(\.homeCharging) private var homeCharging
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var points: [ElectricityPricePoint] = []
    @State private var hasLoaded = false
    @State private var fetchedAt: Date?
    @State private var resolved: PlannerPrices?
    @State private var solarForecast: SolarForecast?
    @State private var gridCarbon: GridCarbonReading?

    private let provider = PlannerPriceProvider.shared

    private var zone: ElspotZone { preferences.electricityPriceZone }

    /// One localized sentence, not three concatenated fragments, so translators can reorder
    /// it. The zone code and the source name are data, not copy, and stay unlocalized.
    private var attributionLine: String {
        if resolved?.origin == .tibber {
            let basis = resolved?.includesNetworkFee == true
                ? L10n.text("Tibber prices include taxes and your network fee")
                : L10n.text("Tibber prices include taxes, not grid fees")
            guard let fetchedAt else { return basis }
            return L10n.format("%@ · fetched %@", basis, Format.shortTime(date: fetchedAt))
        }
        if let fetchedAt {
            return L10n.format("Spot prices exclude taxes and grid fees · %@ · elprisetjustnu.se, fetched %@",
                               zone.rawValue, Format.shortTime(date: fetchedAt))
        }
        return L10n.format("Spot prices exclude taxes and grid fees · %@ · elprisetjustnu.se", zone.rawValue)
    }

    private var cardChangeAnimation: Animation? { reduceMotion ? nil : Motion.cardChange }
    /// Reduce Motion keeps the fade and drops the movement.
    private var plannerTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95))
    }

    private var plannerTaskID: String {
        "\(zone.rawValue)|\(state.identity.vin)|\(state.freshness.fetchedAt.timeIntervalSince1970)"
    }

    var body: some View {
        if Self.isAvailable(state: state, preferences: preferences) {
            cardContent
            // Crossing the charge threshold in either direction must animate
            // the card's own insertion/removal, not snap it.
            .animation(cardChangeAnimation, value: neededEnergyKwh > 0.5)
            .task(id: plannerTaskID) {
                async let solar = Self.solarForecast(for: state, preferences: preferences)
                async let carbon = Self.gridCarbon(preferences: preferences, zone: zone)
                let answer = await provider.resolve(zone: zone)
                let forecast = await solar
                let reading = await carbon
                guard !Task.isCancelled else { return }
                points = answer.points
                fetchedAt = answer.fetchedAt
                resolved = answer
                solarForecast = forecast
                gridCarbon = reading
                hasLoaded = true
            }
        }
    }

    /// Open-Meteo radiation at the car's coordinates, when the car has reported them. The
    /// forecast adds a line only; a failure is nil and the card simply has no line. It sends
    /// the car's position to Open-Meteo, so it follows the Vehicle Weather setting.
    private static func solarForecast(for state: VehicleState, preferences: PreferencesStore) async -> SolarForecast? {
        guard preferences.features.contains(.vehicleWeather),
              let latitude = state.location?.latitude, let longitude = state.location?.longitude else { return nil }
        return await SolarForecastClient().forecast(latitude: latitude, longitude: longitude)
    }

    /// The live carbon line needs a saved Electricity Maps key. The key is read off the main
    /// thread; no key, a 401 and a malformed answer all return nil, so a guessed figure is not
    /// possible here. The manual grid intensity in Settings remains the emissions estimate's
    /// input and is never substituted for this line.
    private static func gridCarbon(preferences: PreferencesStore, zone: ElspotZone) async -> GridCarbonReading? {
        guard preferences.hasElectricityMapsKey else { return nil }
        let keychain = preferences.keychain
        return await Task.detached(priority: .utility) {
            guard let key = try? keychain.readElectricityMapsKey(), !key.isEmpty else { return nil }
            return await ElectricityMapsClient().carbonIntensity(zone: zone, apiKey: key)
        }.value
    }

    /// The paired vehicle with a home charger: Home Assistant can run this car's plan.
    private var showsHome: Bool {
        guard showsHomePlan, onOpenPlanner == nil, let homeCharging, homeCharging.supportsPlans else { return false }
        return homeCharging.shouldShow(for: state)
    }

    @ViewBuilder
    private var cardContent: some View {
        if neededEnergyKwh > 0.5 {
            plannerBody
                .transition(plannerTransition)
        } else if showsHome, let homeCharging {
            // At the charge limit there is nothing for this Mac to plan, but a plan Home Assistant
            // already runs, or one the reader wants to set, stays reachable.
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "chart.bar", title: L10n.text("Charging Planner"), color: HisingenTheme.semanticWarning)
                    HomePlannerSection(state: state, model: homeCharging)
                }
            }
        }
    }

    /// Grid-side energy still missing to reach the charge limit (losses included). At or
    /// above the limit there is nothing to plan, so the card disappears entirely rather
    /// than rendering an empty placeholder.
    private var neededEnergyKwh: Double {
        ChargingPlannerSupport.neededEnergyKwh(
            batteryPercentage: state.energy.batteryPercentage,
            targetPercentage: state.energy.targetPercentage,
            usableCapacityKwh: state.configuredCapacityReference(
                specification: preferences.vehicleSpecificationOverride(for: state.identity.vin)).kwh
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
                CardHeader(symbol: "chart.bar", title: L10n.text("Charging Planner"), color: HisingenTheme.semanticWarning)

                if basis != .fixed, let resolved, !points.isEmpty { sourceRow(resolved) }

                if let model {
                    Group {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.timeRange)
                                .hisType(.display)
                                .foregroundStyle(HisingenTheme.ink)
                                .hisTelemetryValue(model.timeRange, reduceMotion: reduceMotion)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(model.dayLabel)
                                .hisType(.label)
                                .foregroundStyle(HisingenTheme.inkMuted)
                            if onOpenPlanner == nil {
                                Text(model.detailLine)
                                .hisType(.label)
                                .foregroundStyle(HisingenTheme.inkMuted)
                                .hisCaptionLeading()
                                .fixedSize(horizontal: false, vertical: true)
                                    .hisTelemetryValue(model.detailLine, reduceMotion: reduceMotion)
                            }
                        }
                        if onOpenPlanner == nil {
                            priceFigures(model)
                        Text(model.savingsLine)
                            .hisType(.label, weight: .semibold)
                            .foregroundStyle(model.savings > 0 ? HisingenTheme.ink : HisingenTheme.inkMuted)
                            .hisTelemetryValue(model.savingsLine, reduceMotion: reduceMotion)
                        PriceCurveView(points: priceSeries, plan: plan,
                                       granularity: basis.granularity,
                                       caption: basis.chartCaption,
                                       expectedEnd: ElectricityPriceService.requiredCoverageEnd(after: Date()))
                        }
                    }
                    .transition(plannerTransition)
                } else if !hasLoaded && points.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(HisingenTheme.inkMuted)
                        Text(L10n.text("Loading prices…"))
                            .hisType(.label)
                            .foregroundStyle(HisingenTheme.inkMuted)
                    }
                    .transition(plannerTransition)
                } else {
                    Text(statusMessage)
                        .hisType(.label)
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .transition(plannerTransition)
                }

                if onOpenPlanner == nil {
                    if let solarForecast, !solarForecast.isEmpty {
                        SolarForecastLine(forecast: solarForecast)
                            .transition(plannerTransition)
                    }
                    if let gridCarbon {
                        KVRow(
                            L10n.text("Grid carbon now"),
                            L10n.format("%@ g CO₂/kWh", Format.number(gridCarbon.gramsCO2PerKwh, decimals: 0)),
                            symbol: "leaf",
                            info: gridCarbon.observedAt.map { Format.shortTime(date: $0) }
                        )
                        Text(L10n.format("Source: %@", gridCarbon.source))
                            .hisType(.micro)
                            .foregroundStyle(HisingenTheme.inkMuted)
                        .transition(plannerTransition)
                    }
                }

                if let onOpenPlanner {
                    NavigationRow(
                        title: L10n.text("Open in Plan"),
                        accessibilityName: "\(L10n.text("Open in Plan")), \(L10n.text("Charging Planner"))",
                        action: onOpenPlanner
                    )
                }
                if onOpenPlanner == nil && !state.energy.schedules.isEmpty {
                    Label(L10n.text("The car has its own charging schedules. The planner does not use them"),
                          systemImage: "calendar.badge.exclamationmark")
                        .hisType(.micro)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }

                if onOpenPlanner == nil && basis != .fixed {
                    Text(attributionLine)
                        .hisType(.micro)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }

                if showsHome, let homeCharging {
                    PanelRule().padding(.vertical, 2)
                    HomePlannerSection(state: state, model: homeCharging)
                }
            }
            // Loading → loaded → status branch swaps key here; the persistent
            // VStack carries the animation because branches cannot animate
            // their own removal.
            .animation(cardChangeAnimation, value: hasLoaded)
            .animation(cardChangeAnimation, value: planModel?.timeRange)
        }
    }

    /// The two prices the plan is judged by, as figures over labels: what the window costs per
    /// kWh and what charging this minute would cost.
    private func priceFigures(_ model: PlannerModel) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 28))
        return layout {
            priceFigure(value: model.averagePrice, label: L10n.text("Planned average"), level: model.plannedLevel)
            priceFigure(value: model.currentPrice, label: L10n.text("Now"), level: model.currentLevel)
        }
        .accessibilityElement(children: .combine)
    }

    private func priceFigure(value: Double, label: String, level: TibberPriceLevel?) -> some View {
        PlannerPriceFigure(value: value, label: label, level: level)
    }

    /// Which prices the plan below is built from. A fallback names itself in the warning colour, and
    /// the reason Tibber could not be used sits in the row's information button.
    private func sourceRow(_ prices: PlannerPrices) -> some View {
        let fellBack = prices.isFallback
        let value: String
        if prices.origin == .tibber {
            value = "Tibber"
        } else {
            value = fellBack ? L10n.text("Elpriser, Tibber unavailable") : "Elpriser"
        }
        let reason = fellBack
            ? L10n.format("Tibber did not answer, so the planner uses market prices. %@", prices.tibberProblem ?? "")
                .trimmingCharacters(in: .whitespaces)
            : nil
        return KVRow(L10n.text("Prices"), value, valueWarning: fellBack, info: reason)
    }

    /// How the planner prices a slot, read from the electricity setting. There is no choice here:
    /// Settings → Electricity owns the contract, and this card follows it.
    private var basis: PlannerPriceBasis {
        PlannerPriceBasis(mode: preferences.electricityRateMode,
                          contract: preferences.electricityPriceContract)
    }

    /// The prices the plan is built from. A flat rate has no market file behind it, so it gets a
    /// series of its own and the fetched market prices stay out of the decision.
    private var priceSeries: [ElectricityPricePoint] {
        guard basis == .fixed else { return points }
        return ChargingPlanner.fixedSeries(
            dayPricePerKwh: preferences.electricityPricePerKwh,
            nightPricePerKwh: preferences.nightTariffEnabled ? preferences.nightElectricityPricePerKwh : nil,
            nightStartHour: preferences.nightTariffStartHour,
            nightEndHour: preferences.nightTariffEndHour,
            from: Date()
        )
    }

    private var plan: ChargingPlan? {
        ChargingPlanner.cheapestWindow(
            prices: priceSeries,
            now: Date(),
            energyKwh: neededEnergyKwh,
            chargerPowerKw: plannerPowerKw,
            granularity: basis.granularity
        )
    }

    /// "2 h" at hourly prices, "1 h 15 min" at quarter-hourly ones.
    private func durationText(_ hours: Double) -> String {
        let total = Int((hours * 60).rounded())
        if total < 60 { return L10n.format("%d min", total) }
        return L10n.format("%d h %d min", total / 60, total % 60)
    }

    private var statusMessage: String {
        guard let horizon = ChargingPlanner.dataHorizonEnd(prices: points) else {
            return L10n.text("Prices unavailable right now")
        }
        // Distinguish "tomorrow's file has not landed yet" from "the outlook can never
        // fit this charge" – a 54 h charge on a weak outlet will not fit into even a
        // complete two-day outlook, and blaming the publication time would be a lie.
        let now = Date()
        let step = basis.granularity
        let planSeconds = max(step, ((neededEnergyKwh / plannerPowerKw) / step).rounded(.up) * step)
        let dataComplete = horizon >= ElectricityPriceService.requiredCoverageEnd(after: now)
        if dataComplete && horizon.timeIntervalSince(now) < planSeconds {
            let minutes = Int((planSeconds / 60).rounded())
            return minutes % 60 == 0
                ? L10n.format("A %d h charge is longer than the price outlook", minutes / 60)
                : L10n.format("A %@ charge is longer than the price outlook", durationText(planSeconds / 3_600))
        }
        return L10n.format("Tomorrow's prices arrive after %@", Format.clockTime(hour: 14, minute: 15))
    }

    private struct PlannerModel {
        var timeRange: String
        var dayLabel: String
        var detailLine: String
        var averagePrice: Double
        var currentPrice: Double
        var savingsLine: String
        var savings: Double
        /// Tibber's own level for the planned window and for this minute, when Tibber is the source.
        var plannedLevel: TibberPriceLevel?
        var currentLevel: TibberPriceLevel?
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
        let timeRange = "\(Format.shortTime(date: plan.start))–\(Format.shortTime(date: plan.end))"

        let minutes = Int((plan.hours * 60).rounded())
        let detailLine = minutes % 60 == 0
            ? L10n.format("Charge %@ over %d h to reach %d%%", Format.energyKwh(plan.energyKwh), minutes / 60, target)
            : L10n.format("Charge %@ over %@ to reach %d%%", Format.energyKwh(plan.energyKwh), durationText(plan.hours), target)

        let savingsLine = plan.savings > 0.5
            ? L10n.format("Saves %@", Format.currency(plan.savings, symbol: "kr"))
            : L10n.text("Charging now is cheapest")

        return PlannerModel(
            timeRange: timeRange,
            dayLabel: dayLabel,
            detailLine: detailLine,
            averagePrice: plan.averagePrice,
            currentPrice: plan.currentPrice,
            savingsLine: savingsLine,
            savings: plan.savings,
            plannedLevel: resolved?.level(from: plan.start, to: plan.end),
            currentLevel: resolved?.level(at: now)
        )
    }
}

/// One price the plan is judged by: the figure over its label. With Tibber as the source the label
/// carries Tibber's own level for that price.
struct PlannerPriceFigure: View {
    let value: Double
    let label: String
    var level: TibberPriceLevel?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let text = Format.number(value, decimals: 2)
        let caption = level.map { L10n.format("%@ · %@", label, $0.title.lowercased()) } ?? label
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(text)
                    .hisType(size: 22, relativeTo: .title)
                    .foregroundStyle(HisingenTheme.ink)
                    .hisTelemetryValue(text, reduceMotion: reduceMotion)
                Text("kr/kWh")
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
            }
            Text(caption)
                .hisType(.label)
                .foregroundStyle(HisingenTheme.inkMuted)
        }
    }
}
