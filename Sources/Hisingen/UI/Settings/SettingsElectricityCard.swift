import SwiftUI

/// Settings → Electricity. The country decides what is offered: Sweden unlocks market-linked
/// pricing (zone, contract, provider) and, as a sibling card, the charging planner; any other
/// country gets the typed-in rate and the optional night tariff. Charge costs everywhere in
/// the app read from what is set here. A country change goes out as a feature change so the
/// background planner starts or stops with it.
@MainActor
struct SettingsElectricityCard: View {
    let binder: PreferenceBinder

    private var preferences: PreferencesStore { binder.preferences }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "bolt.circle", title: L10n.text("Electricity"), color: HisingenTheme.semanticWarning)

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("Country"))
                            .hisType(.body, weight: .medium)
                        Text(preferences.marketCountry.offersMarketPricing
                             ? L10n.text("Market prices, providers and the charging planner are available")
                             : L10n.text("Market prices are available for Sweden only. Other countries use a typed-in rate."))
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

                Divider().opacity(HisingenTheme.dividerOpacity)

                SettingsElectricityRateSection(
                    binder: binder,
                    offersAutomatic: preferences.marketCountry.offersMarketPricing
                )
            }
        }
        .hisAnimation(Motion.layout, value: preferences.marketCountry)
    }
}
