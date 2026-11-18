import SwiftUI

/// Settings, Electricity: the electricity supplier. A Tibber access token prices charger sessions and
/// the charging planner from Tibber's own 15-minute prices, with no Home Assistant and no charger
/// required. Nothing here is required; without it, or while Tibber does not answer, the planner reads
/// the market prices and sessions are priced from the rate settings above.
@MainActor
struct SettingsTibberCard: View {
    @ObservedObject var model: HomeChargingModel
    let binder: PreferenceBinder

    @State private var token = ""
    @State private var isConnecting = false
    @State var homes: [TibberHome]?
    @State var selection = ""
    @State private var failure: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "bolt", title: L10n.text("Electricity Supplier"), color: HisingenTheme.semanticGood)
                Text(L10n.text("Optional. Connects Tibber to plan charging and price sessions from its own 15-minute prices, without Home Assistant."))
                    .hisType(.caption)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let home = model.tibberHome {
                    connectedView(home)
                } else {
                    setupView
                }
            }
        }
    }

    // MARK: Setup

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Tibber access token")).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
                Text(L10n.text("Create it at developer.tibber.com. It is stored in the macOS Keychain and never exported."))
                    .hisType(.caption).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                SecureField("", text: $token)
                    .hisField()
                    .accessibilityLabel(L10n.text("Tibber access token"))
            }
            Button { Task { await connect() } } label: {
                Text(isConnecting ? L10n.text("Connecting…") : L10n.text("Connect and find homes")).frame(minHeight: 24)
            }
            .buttonStyle(.hisProminent)
            .disabled(isConnecting || token.trimmingCharacters(in: .whitespaces).isEmpty)
            if let failure {
                Text(failure)
                    .hisType(.label).foregroundStyle(HisingenTheme.ink)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hisNotice(HisingenTheme.semanticCritical)
            }
            if let homes {
                PanelRule()
                if homes.isEmpty {
                    Text(L10n.text("This token has no Tibber home that Hisingen can read."))
                        .hisType(.label).foregroundStyle(HisingenTheme.inkMuted)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Home")).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
                        Picker("", selection: $selection) {
                            ForEach(homes) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .accessibilityLabel(L10n.text("Home"))
                    }
                    Button { save(homes) } label: { Text(L10n.text("Use this home")).frame(minHeight: 24) }
                        .buttonStyle(.hisProminent)
                        .disabled(selection.isEmpty)
                }
            }
        }
    }

    // MARK: Connected

    private func connectedView(_ home: TibberHome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 4) {
                KVRow(L10n.text("Supplier"), "Tibber")
                KVRow(L10n.text("Home"), home.name)
                if let currency = home.currency { KVRow(L10n.text("Currency"), currency) }
                if let area = home.priceArea { KVRow(L10n.text("Price area"), area) }
                if let company = home.gridCompany {
                    KVRow(L10n.text("Grid company"), company,
                          info: L10n.text("Tibber does not publish this company's fee. The per-kWh part is on your grid invoice."))
                }
                KVRow(L10n.text("Prices"), model.tibberProblem ?? L10n.text("Used for the planner and charging sessions"),
                      valueWarning: model.tibberProblem != nil)
            }
            if let zone = suggestedZone(for: home) {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse").hisType(.caption).foregroundStyle(HisingenTheme.accent)
                    Text(L10n.format("Tibber puts this home in %@", zone.title))
                        .hisType(.caption).foregroundStyle(HisingenTheme.inkMuted)
                    Button(L10n.text("Use")) {
                        binder.preferences.electricityPriceZone = zone
                        binder.bump()
                        binder.notify(.presentation)
                    }
                    .buttonStyle(.pressable)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.format("Use %@", zone.title))
                }
            }
            Text(L10n.text("Tibber's price includes energy, taxes and its markup but not the grid fee. Set your grid tariff in the card below; a paired charger can set its own."))
                .hisType(.caption).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            Button { model.disconnectTibber(); token = ""; homes = nil } label: {
                Text(L10n.text("Disconnect Tibber")).frame(minHeight: 24)
            }
            .buttonStyle(.hisSecondary(HisingenTheme.semanticCritical))
        }
    }

    /// The zone Tibber reports for the home, when it differs from the one the planner reads market
    /// prices for. Only offered where Hisingen reads market prices at all.
    private func suggestedZone(for home: TibberHome) -> ElspotZone? {
        guard binder.preferences.marketCountry.offersMarketPricing,
              let zone = home.elspotZone, zone != binder.preferences.electricityPriceZone else { return nil }
        return zone
    }

    // MARK: Actions

    private func connect() async {
        isConnecting = true
        failure = nil
        defer { isConnecting = false }
        switch await model.testTibber(token: token) {
        case .failure(let error):
            failure = error.errorDescription
            homes = nil
        case .success(let found):
            homes = found
            selection = found.first?.id ?? ""
        }
    }

    private func save(_ homes: [TibberHome]) {
        guard let home = homes.first(where: { $0.id == selection }) else { return }
        do {
            try model.connectTibber(token: token, home: home)
            token = ""
            self.homes = nil
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
