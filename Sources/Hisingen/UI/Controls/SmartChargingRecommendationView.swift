import SwiftUI

@MainActor
struct SmartChargingRecommendationView: View {
    let state: VehicleState

    @Environment(\.preferencesStore) private var preferences
    @State private var area: SwedishPriceArea = .se3
    @State private var powerKW = 11.0
    /// Day-ahead prices are fetched once per area (or on manual refresh) and cached here;
    /// the recommendation is recomputed locally from these when SOC/target/power change,
    /// so a telemetry tick never triggers a network call to the free price feed.
    @State private var prices: [SpotPriceInterval] = []
    @State private var pricesLoadedAt: Date?
    @State private var recommendation: SmartChargingRecommendation?
    @State private var isLoading = false
    @State private var errorText: String?

    private static let powerOptions: [Double] = [2.3, 3.7, 7.4, 11.0, 22.0]

    private var targetSOC: Double { Double(state.chargeTargetPercentage ?? 80) }
    private var currentSOC: Double { state.batteryPercentage ?? 0 }
    private var usableCapacity: Double {
        preferences.vehicleSpecificationOverride(for: state.vin)?.usableBatteryCapacityKwh
            ?? state.configuredUsableBatteryCapacityKwh
    }
    /// Grid energy includes a conservative 10% AC conversion/loss allowance.
    private var energyNeeded: Double {
        max(0, targetSOC - currentSOC) / 100 * max(0, usableCapacity) / 0.90
    }
    private var isSwedishMarket: Bool {
        let market = state.accountMarket?.uppercased()
        return market == nil || market == "SE"
    }

    private static func nearestPowerOption(_ kw: Double) -> Double {
        powerOptions.min(by: { abs($0 - kw) < abs($1 - kw) }) ?? 11.0
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    CardHeader(symbol: "bolt.badge.clock.fill",
                               title: L10n.text("Spot-price Charging Recommendation"), color: .yellow)
                    Spacer()
                    if isLoading { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 8) {
                    Picker(L10n.text("Price area"), selection: $area) {
                        ForEach(SwedishPriceArea.allCases) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .controlSize(.small)
                    .onChange(of: area) { _, value in preferences.smartChargingPriceArea = value }
                    Picker(L10n.text("Charging power"), selection: $powerKW) {
                        ForEach(Self.powerOptions, id: \.self) { value in
                            Text(String(format: "%.1f kW", value)).tag(value)
                        }
                    }
                    .controlSize(.small)
                    .onChange(of: powerKW) { _, value in
                        preferences.smartChargingPowerKW = value
                        recompute()
                    }
                }

                if !isSwedishMarket {
                    Text(L10n.format("These are Swedish (Nord Pool SE) day-ahead prices. Your account market is %@.",
                                     state.accountMarket ?? "?"))
                        .font(.system(size: 8.5)).foregroundStyle(.tertiary)
                }

                if energyNeeded <= 0 {
                    Text(L10n.text("The vehicle is already at its charge target."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else if usableCapacity <= 0 {
                    Text(L10n.text("Add a usable battery capacity in Settings to calculate the required window."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else if let recommendation {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("Cheapest window"))
                                .font(.system(size: 8.5)).foregroundStyle(.secondary)
                            Text("\(Format.dateTimeFormatter.string(from: recommendation.start)) – \(recommendation.end.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Format.currency(recommendation.estimatedCostSEK, symbol: "kr"))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                            Text(String(format: "%.2f kr/kWh · %.1f kWh", recommendation.averageSEKPerKWh,
                                        recommendation.energyKWh))
                                .font(.system(size: 8.5)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    Text(L10n.text("Recommendation only — Hisingen does not change the vehicle’s charging schedule. Spot prices exclude VAT, grid fees, taxes, and retailer markups."))
                        .font(.system(size: 8.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 9.5)).foregroundStyle(.orange)
                } else if !isLoading {
                    Text(L10n.text("No contiguous published price window is long enough yet. Tomorrow’s prices normally arrive after 13:00."))
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                }

                HStack {
                    Link(L10n.text("Prices: elprisetjustnu.se"),
                         destination: URL(string: "https://www.elprisetjustnu.se/elpris-api")!)
                        .font(.system(size: 8.5))
                    Spacer()
                    Button {
                        Task { await loadPrices(force: true) }
                    } label: {
                        Label(L10n.text("Refresh prices"), systemImage: "arrow.clockwise")
                            .font(.system(size: 8.5))
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoading)
                }
            }
        }
        .task(id: area) { await loadPrices(force: false) }
        .onChange(of: currentSOC) { _, _ in recompute() }
        .onChange(of: targetSOC) { _, _ in recompute() }
        .onChange(of: usableCapacity) { _, _ in recompute() }
        .onAppear {
            area = preferences.smartChargingPriceArea
            powerKW = Self.nearestPowerOption(preferences.smartChargingPowerKW)
            if let livePower = state.chargingPowerWatts, livePower > 1_000,
               preferences.smartChargingPowerWasCustomized == false {
                powerKW = Self.nearestPowerOption(Double(livePower) / 1_000)
            }
        }
    }

    /// Fetches prices only when the cache is empty, stale (rolled to a new day), or forced.
    private func loadPrices(force: Bool) async {
        let calendar = Calendar.current
        let cacheIsFresh = !prices.isEmpty
            && pricesLoadedAt.map { calendar.isDateInToday($0) } == true
        if !force && cacheIsFresh {
            recompute()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await SpotPriceService().fetchTodayAndTomorrow(area: area)
            guard !Task.isCancelled else { return }
            prices = fetched
            pricesLoadedAt = Date()
            errorText = nil
            recompute()
        } catch {
            guard !Task.isCancelled else { return }
            prices = []
            recommendation = nil
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Local, no-network: re-solve the cheapest window from the cached price rows.
    private func recompute() {
        guard energyNeeded > 0, powerKW > 0, usableCapacity > 0, !prices.isEmpty else {
            recommendation = nil
            return
        }
        recommendation = SmartChargingRecommendation.cheapestWindow(
            prices: prices, energyKWh: energyNeeded,
            chargingPowerKW: powerKW, notBefore: Date()
        )
    }
}
