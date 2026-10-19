import SwiftUI

/// Settings → Display, Units & Energy → "Electricity Rate". One switch decides where every
/// charge-cost figure comes from: a rate typed in (with the optional night tariff), or the
/// market spot price for the user's zone plus their provider's markup. Automatic mode asks
/// for the contract type (15-minute or hourly settlement), the provider, and the markup and
/// other per-kWh charges in öre as written on their price list; the app ships no provider
/// prices because those are per contract and change often.
@MainActor
struct SettingsElectricityRateSection: View {
    let binder: PreferenceBinder
    /// False outside Sweden: the market-linked mode is Swedish, so only the typed-in rate shows.
    var offersAutomatic = true

    @State private var electricityPrice = "2.00"
    @State private var currencySymbol = "kr"
    @State private var nightElectricityPrice = "2.00"
    @State private var markupText = "0"
    @State private var otherChargesText = "0"
    @State private var priceLookup: PriceLookup = .loading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum PriceLookup: Equatable {
        case loading
        case unavailable
        case spot(Double)
    }

    private var preferences: PreferencesStore { binder.preferences }
    private var policy: ElectricityRatePolicy { preferences.electricityRatePolicy }

    private var lookupID: String {
        "\(preferences.electricityRateMode.rawValue)|\(preferences.electricityPriceZone.rawValue)|\(preferences.electricityPriceContract.rawValue)"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Electricity Rate"))
                        .hisType(.body, weight: .medium)
                    Text(L10n.text("For charge cost estimates"))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if offersAutomatic {
                    Picker("", selection: modeBinding) {
                        ForEach(ElectricityRateMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel(L10n.text("Electricity rate mode"))
                    .controlSize(.small)
                    .frame(maxWidth: 210)
                }
            }

            if policy.isAutomatic {
                automaticRows
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                fixedRows
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .hisAnimation(Motion.layout, value: preferences.electricityRateMode)
        .hisAnimation(Motion.layout, value: preferences.nightTariffEnabled)
        .onAppear {
            electricityPrice = String(format: "%.2f", locale: L10n.displayLocale, preferences.electricityPricePerKwh)
            currencySymbol = preferences.currencySymbol
            nightElectricityPrice = String(format: "%.2f", locale: L10n.displayLocale, preferences.nightElectricityPricePerKwh)
            markupText = Self.oreText(preferences.electricityMarkupOrePerKwh)
            otherChargesText = Self.oreText(preferences.electricityOtherChargesOrePerKwh)
        }
        .task(id: lookupID) { await loadCurrentPrice() }
    }

    // MARK: - Mode

    /// Automatic prices are in SEK, so choosing it also sets the currency the rest of the app
    /// shows; the typed-in rate stays available as the fallback for uncovered sessions.
    private var modeBinding: Binding<ElectricityRateMode> {
        Binding(
            get: { preferences.electricityRateMode },
            set: { newMode in
                guard newMode != preferences.electricityRateMode else { return }
                preferences.electricityRateMode = newMode
                if newMode == .automatic {
                    preferences.currencySymbol = "kr"
                    currencySymbol = "kr"
                }
                binder.bump()
                binder.notify(.presentation)
            }
        )
    }

    // MARK: - Automatic

    private var automaticRows: some View {
        VStack(spacing: 10) {
            pickerRow(
                title: "Price Zone", detail: "Spot-price area you live in",
                accessibility: "Electricity price zone"
            ) {
                Picker("", selection: binder(\.electricityPriceZone, .presentation)) {
                    ForEach(ElspotZone.allCases) { zone in
                        Text(zone.title).tag(zone)
                    }
                }
            }

            pickerRow(
                title: "Contract", detail: "How your contract settles the market price",
                accessibility: "Electricity contract type"
            ) {
                Picker("", selection: binder(\.electricityPriceContract, .presentation)) {
                    ForEach(ElectricityPriceContract.allCases) { contract in
                        Text(contract.title).tag(contract)
                    }
                }
            }

            pickerRow(
                title: "Provider", detail: "Your electricity retailer",
                accessibility: "Electricity provider"
            ) {
                Picker("", selection: binder(\.electricityProvider, .presentation)) {
                    ForEach(ElectricityProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
            }

            oreRow(
                title: "Provider markup",
                detail: preferences.electricityProvider == .other
                    ? L10n.text("Påslag from your price list, excluding VAT")
                    : L10n.format("Find the påslag on your %@ price list or invoice", preferences.electricityProvider.title),
                text: $markupText
            ) { value in
                preferences.electricityMarkupOrePerKwh = value
                binder.bump()
                binder.notify(.presentation)
            }

            oreRow(
                title: "Tax and grid fee",
                detail: L10n.text("Optional: energy tax and grid fee per kWh, excluding VAT"),
                text: $otherChargesText
            ) { value in
                preferences.electricityOtherChargesOrePerKwh = value
                binder.bump()
                binder.notify(.presentation)
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Add 25% VAT"))
                        .hisType(.body, weight: .medium)
                    Text(L10n.text("Spot prices exclude VAT; households pay it on the total"))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: binder.toggle(\.electricityIncludesVAT, .presentation))
                    .labelsHidden()
                    .accessibilityLabel(L10n.text("Add 25% VAT"))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            currentPriceRow

            rateField(
                title: "Rate without market prices",
                detail: "Used for sessions the market prices do not cover",
                symbolEditable: false
            )

            Text(L10n.text("Market prices from elprisetjustnu.se. A changed contract type applies to sessions priced from now on; earlier ones keep their settlement."))
                .hisType(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What the settings produce right now, so a wrong markup shows up as a wrong number
    /// before it shows up in History.
    private var currentPriceRow: some View {
        HStack(spacing: 8) {
            Text(L10n.text("Current price"))
                .hisType(.body, weight: .medium)
            Spacer()
            switch priceLookup {
            case .loading:
                Text(L10n.text("Fetching prices…"))
                    .hisType(.label)
                    .foregroundStyle(.secondary)
            case .unavailable:
                Text(L10n.text("Market prices unavailable"))
                    .hisType(.label)
                    .foregroundStyle(.secondary)
            case .spot(let spot):
                let price = L10n.format("%@/kWh", Format.currency(policy.retailPrice(spotSekPerKwh: spot), symbol: preferences.currencySymbol, decimals: 2))
                Text(price)
                    .hisType(.body, weight: .bold)
                    .hisTelemetryValue(price, reduceMotion: reduceMotion)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func loadCurrentPrice() async {
        guard preferences.electricityRateMode == .automatic else { return }
        priceLookup = .loading
        let prices = await ElectricityPriceService.shared.prices(for: preferences.electricityPriceZone)
        let settled = preferences.electricityPriceContract.settle(prices)
        if let spot = ChargingPlanner.currentPrice(prices: settled, at: Date()) {
            priceLookup = .spot(spot)
        } else {
            priceLookup = .unavailable
        }
    }

    // MARK: - Fixed

    private var fixedRows: some View {
        VStack(spacing: 10) {
            rateField(title: "Price per kWh", detail: "Typed-in rate for every session", symbolEditable: true)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Night Tariff"))
                        .hisType(.body, weight: .medium)
                    Text(L10n.text("Splits session cost by when energy actually flowed"))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: binder.toggle(\.nightTariffEnabled))
                    .labelsHidden()
                    .accessibilityLabel(L10n.text("Night Tariff"))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if preferences.nightTariffEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        TextField("2.00", text: $nightElectricityPrice)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 55)
                            .multilineTextAlignment(.trailing)
                            .controlSize(.small)
                            .accessibilityLabel(L10n.text("Night rate"))
                            .onChange(of: nightElectricityPrice) { _, _ in
                                if let price = NumberParsing.decimal(from: nightElectricityPrice),
                                   (0.01...1_000).contains(price) {
                                    preferences.nightElectricityPricePerKwh = price
                                }
                            }
                        Text(L10n.text("/kWh from"))
                            .hisType(.label)
                            .foregroundStyle(.secondary)
                        Stepper(value: binder(\.nightTariffStartHour), in: 0...23) {
                            Text(String(format: "%02d:00", locale: L10n.displayLocale, preferences.nightTariffStartHour))
                                .hisType(.label, design: .monospaced)
                        }
                        .controlSize(.small)
                        Text(L10n.text("to"))
                            .hisType(.label)
                            .foregroundStyle(.secondary)
                        Stepper(value: binder(\.nightTariffEndHour), in: 0...23) {
                            Text(String(format: "%02d:00", locale: L10n.displayLocale, preferences.nightTariffEndHour))
                                .hisType(.label, design: .monospaced)
                        }
                        .controlSize(.small)
                    }
                    if !SettingsValidation.isValidElectricityPrice(nightElectricityPrice) {
                        InlineValidationLabel(message: L10n.text("Enter a night rate between 0.01 and 1,000."))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Rows

    /// The typed-in rate with its currency symbol. Fixed mode edits both; automatic mode edits
    /// only the rate, because the currency is already SEK.
    private func rateField(title: String, detail: String, symbolEditable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(title))
                        .hisType(.body, weight: .medium)
                    Text(L10n.text(detail))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    TextField("2.00", text: $electricityPrice)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)
                        .multilineTextAlignment(.trailing)
                        .controlSize(.small)
                        .accessibilityLabel(L10n.text(title))
                        .onChange(of: electricityPrice) { _, _ in
                            if let price = NumberParsing.decimal(from: electricityPrice),
                               (0.01...1_000).contains(price) {
                                preferences.electricityPricePerKwh = price
                            }
                        }
                    if symbolEditable {
                        TextField("kr", text: $currencySymbol)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 45)
                            .controlSize(.small)
                            .accessibilityLabel(L10n.text("Currency symbol"))
                            .onChange(of: currencySymbol) { _, _ in
                                if SettingsValidation.isValidCurrencySymbol(currencySymbol) {
                                    preferences.currencySymbol = currencySymbol.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }
                    } else {
                        Text(preferences.currencySymbol)
                            .hisType(.label)
                            .foregroundStyle(.secondary)
                    }
                    Text("/kWh")
                        .hisType(.label)
                        .foregroundStyle(.secondary)
                }
            }
            if !SettingsValidation.isValidElectricityPrice(electricityPrice) {
                InlineValidationLabel(message: L10n.text("Enter a rate between 0.01 and 1,000."))
            }
            if symbolEditable, !SettingsValidation.isValidCurrencySymbol(currencySymbol) {
                InlineValidationLabel(message: L10n.text("Enter a currency symbol or code using 1–8 characters."))
            }
        }
    }

    private func pickerRow<Control: View>(
        title: String, detail: String, accessibility: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(title))
                    .hisType(.body, weight: .medium)
                Text(L10n.text(detail))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            control()
                .labelsHidden()
                .accessibilityLabel(L10n.text(accessibility))
                .controlSize(.small)
                .frame(maxWidth: 220)
        }
    }

    private func oreRow(
        title: String, detail: String, text: Binding<String>,
        commit: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(title))
                        .hisType(.body, weight: .medium)
                    Text(detail)
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    TextField("0", text: text)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)
                        .multilineTextAlignment(.trailing)
                        .controlSize(.small)
                        .accessibilityLabel(L10n.text(title))
                        .onChange(of: text.wrappedValue) { _, newText in
                            if SettingsValidation.isValidOre(newText), let value = NumberParsing.decimal(from: newText) {
                                commit(value)
                            }
                        }
                    Text(L10n.text("öre/kWh"))
                        .hisType(.label)
                        .foregroundStyle(.secondary)
                }
            }
            if !SettingsValidation.isValidOre(text.wrappedValue) {
                InlineValidationLabel(message: L10n.text("Enter an amount between 0 and 1,000 öre."))
            }
        }
    }

    private static func oreText(_ value: Double) -> String {
        value == value.rounded()
            ? String(format: "%.0f", locale: L10n.displayLocale, value)
            : String(format: "%.1f", locale: L10n.displayLocale, value)
    }
}
