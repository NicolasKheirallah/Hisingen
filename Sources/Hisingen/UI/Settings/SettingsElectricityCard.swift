import SwiftUI

/// Settings → Electricity. The country decides what is offered: Sweden unlocks market-linked
/// pricing (zone, contract, provider) and, as a sibling card, the charging planner; any other
/// country gets the typed-in rate and the optional night tariff. Charge costs everywhere in
/// the app read from what is set here. A country change goes out as a feature change so the
/// background planner starts or stops with it.
@MainActor
struct SettingsElectricityCard: View {
    let binder: PreferenceBinder
    var state: VehicleState? = nil
    var tibberZone: ElspotZone? = nil

    private var preferences: PreferencesStore { binder.preferences }

    private var suggestedZone: ElspotZone? {
        guard let latitude = state?.location?.latitude else { return nil }
        let zone = ChargingPlannerSupport.suggestedZone(latitude: latitude)
        return zone == preferences.electricityPriceZone ? nil : zone
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "bolt.circle", title: L10n.text("Electricity"), color: HisingenTheme.semanticWarning)

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("Country"))
                            .hisType(.body, weight: .medium)
                        Text(preferences.hasPriceSource
                             ? L10n.text("Market prices, providers and the charging planner are available")
                             : L10n.text("Connect Tibber or choose Sweden to use market prices and the charging planner. Without a price source, a typed-in rate is used."))
                            .hisType(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: binder(\.marketCountry, .features)) {
                        ForEach(MarketCountry.allCases) { country in
                            Text(country.title).tag(country)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(L10n.text("Country"))
                    .controlSize(.small)
                    .frame(maxWidth: 160)
                }

                if preferences.marketCountry.offersMarketPricing {
                    priceZoneSection
                }

                Divider().opacity(HisingenTheme.dividerOpacity)

                SettingsElectricityRateSection(
                    binder: binder,
                    offersAutomatic: preferences.hasPriceSource
                )

                Divider().opacity(HisingenTheme.dividerOpacity)
                SettingsGridCarbonSection(binder: binder)
            }
        }
        .hisAnimation(Motion.layout, value: preferences.marketCountry)
    }
    @ViewBuilder
    private var priceZoneSection: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Price Zone"))
                    .hisType(.body, weight: .medium)
                Text(L10n.text("Used for spot prices and when Tibber prices are unavailable."))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker(L10n.text("Electricity price zone"), selection: binder(\.electricityPriceZone, .features)) {
                ForEach(ElspotZone.allCases) { zone in
                    Text(zone.title).tag(zone)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 160)
        }

        if let tibberZone, tibberZone != preferences.electricityPriceZone {
            zoneSuggestion(tibberZone, message: L10n.format("Tibber puts this home in %@", tibberZone.title))
        }
        if let suggestedZone, suggestedZone != tibberZone {
            zoneSuggestion(suggestedZone, message: L10n.format("The vehicle's location suggests %@", suggestedZone.title))
        }
    }

    private func zoneSuggestion(_ zone: ElspotZone, message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "location")
                .hisType(.caption)
                .accessibilityHidden(true)
            Text(message)
                .hisType(.caption)
                .foregroundStyle(.secondary)
            Button(L10n.text("Use")) {
                binder(\.electricityPriceZone, .features).wrappedValue = zone
            }
            .buttonStyle(.hisSecondary)
            .controlSize(.small)
            .accessibilityLabel(L10n.format("Use %@", zone.title))
        }
    }
}

@MainActor
struct SettingsElectricityWithSupplier: View {
    @ObservedObject var model: HomeChargingModel
    let binder: PreferenceBinder
    let state: VehicleState?

    var body: some View {
        SettingsElectricityCard(binder: binder, state: state, tibberZone: model.tibberHome?.elspotZone)
    }
}
