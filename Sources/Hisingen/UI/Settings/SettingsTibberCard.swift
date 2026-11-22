import Charts
import SwiftUI

/// Settings, Electricity: the electricity supplier. A Tibber access token prices charger sessions and
/// the charging planner from Tibber's own 15-minute prices, with no Home Assistant and no charger
/// required. Nothing here is required; without it, or while Tibber does not answer, the planner reads
/// the market prices and sessions are priced from the rate settings above.
@MainActor
struct SettingsTibberCard: View {
    @ObservedObject var model: HomeChargingModel
    /// Observed directly, so the live-status row follows the stream and not just the supplier.
    @ObservedObject private var live: TibberLiveModel
    @StateObject private var energy: TibberEnergyModel

    init(model: HomeChargingModel, preferences: PreferencesStore) {
        self.model = model
        self.live = model.tibberLive
        _energy = StateObject(wrappedValue: TibberEnergyModel(preferences: preferences))
    }

    @State private var token = ""
    @State private var isConnecting = false
    @State private var isReplacingToken = false
    @State var homes: [TibberHome]?
    @State var selection = ""
    @State private var failure: String?

    var body: some View {
        SettingsConnectedServiceCard(
            title: "Electricity Supplier",
            symbol: "bolt",
            detail: "Optional. Connects Tibber to plan charging and price sessions from its own 15-minute prices, without Home Assistant."
        ) {
            if let home = model.tibberHome {
                connectedView(home)
                if isReplacingToken {
                    PanelRule()
                    setupView
                }
            } else {
                setupView
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
                KVRow(L10n.text("Live House Power"), liveStatusText,
                      info: L10n.text("Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one."))
            }
            Text(L10n.text("Tibber's price includes energy, taxes and its markup but not the grid fee. Set the grid tariff under Electricity. A paired charger can use its own tariff."))
                .hisType(.caption).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            PanelRule()
            TibberEnergySection(model: energy)
            HStack(spacing: 8) {
                Button(isReplacingToken ? L10n.text("Cancel") : L10n.text("Reconnect Tibber")) {
                    isReplacingToken.toggle()
                    if !isReplacingToken { clearDraft() }
                }
                .buttonStyle(.hisSecondary)
                .disabled(isConnecting)

                Button {
                    model.disconnectTibber()
                    isReplacingToken = false
                    clearDraft()
                } label: {
                    Text(L10n.text("Disconnect Tibber"))
                }
                .buttonStyle(.hisSecondary(HisingenTheme.semanticCritical))
                .disabled(isConnecting)
            }
            .controlSize(.small)
        }
    }

    private var liveStatusText: String {
        switch live.link {
        case .notConfigured, .connecting: return L10n.text("Connecting…")
        case .live: return L10n.text("Reading live")
        case .noPulse: return L10n.text("No Pulse paired")
        case .reconnecting: return L10n.text("Reconnecting")
        case .unauthorized: return L10n.text("Sign-in refused")
        }
    }

    private func clearDraft() {
        token = ""
        homes = nil
        selection = ""
        failure = nil
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
            isReplacingToken = false
            clearDraft()
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: House energy

/// The connected card's house-energy readout: the meter's last 30 days and the months before,
/// plus how the published prices sit across Tibber's five levels. Everything it shows came off a
/// meter or the price feed, so a part the feed has not answered stays out instead of reading as
/// zero.
private struct TibberEnergySection: View {
    @ObservedObject var model: TibberEnergyModel

    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 112
    @ScaledMetric(relativeTo: .body) private var levelChartHeight: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("House Energy")).hisType(.subhead, weight: .medium).foregroundStyle(HisingenTheme.ink)
            if let problem = model.problem {
                Text(problem)
                    .hisType(.label).foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let content = model.content {
                if content.days.count >= 2 {
                    energyChart(L10n.text("By Day"), unit: .day, content: content)
                }
                if content.months.count >= 2 {
                    energyChart(L10n.text("By Month"), unit: .month, content: content)
                }
                if !content.levelHours.isEmpty {
                    levelChart(content.levelHours)
                }
                if let cost = content.cost {
                    KVRow(L10n.text("House Cost"), Format.currency(cost.amount, symbol: cost.currency, decimals: 0),
                          info: L10n.text("What Tibber billed for these days of energy, taxes included. The grid fee is not in it."))
                }
            }
        }
        .task { await model.reload() }
    }

    @ViewBuilder
    private func energyChart(_ title: String, unit: Calendar.Component, content: TibberEnergyModel.Content) -> some View {
        let consumption = L10n.text("Consumption")
        let production = L10n.text("Production")
        let grouped = !content.productionRows(for: unit).isEmpty
        let dates = (content.rows(for: unit).map(\.start) + content.productionRows(for: unit).map(\.start)).sorted()
        VStack(alignment: .leading, spacing: 6) {
            Text(title).hisType(.label, weight: .medium).foregroundStyle(HisingenTheme.ink)
            Chart {
                ForEach(content.rows(for: unit), id: \.start) { row in
                    energyMark(x: row.start, y: row.kwh, unit: unit, series: consumption, grouped: grouped)
                }
                ForEach(content.productionRows(for: unit), id: \.start) { row in
                    energyMark(x: row.start, y: row.kwh, unit: unit, series: production, grouped: grouped)
                }
            }
            .chartForegroundStyleScale(domain: [consumption, production],
                                       range: [HisingenTheme.chartInfo, HisingenTheme.chartPositive])
            .historyTimeAxis(spanning: dates, monthly: unit == .month)
            .historyYAxis("kWh")
            .frame(height: chartHeight)
            .accessibilityLabel(title)
            .accessibilityValue(chartAccessibilityValue(points: content.rows(for: unit).map(\.kwh)))
            .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                title: title, yLabel: "kWh",
                points: content.rows(for: unit).map { ($0.start, $0.kwh) },
                valueFormat: { String(format: "%.0f", locale: L10n.displayLocale, $0) }))
            Text(L10n.text("Whole-home energy per period. A period the meter has not reported is left out, and the month still running is shorter than its neighbours."))
                .hisType(.micro).foregroundStyle(.secondary)
                .hisCaptionLeading()
                .fixedSize(horizontal: false, vertical: true)
            if grouped {
                HStack(spacing: 10) {
                    HistoryChartLegendItem(color: HisingenTheme.chartInfo, label: consumption, band: true)
                    HistoryChartLegendItem(color: HisingenTheme.chartPositive, label: production, band: true)
                    Spacer()
                }
            }
        }
    }

    /// One bar per period. With a production series beside it the two sit side by side, named in
    /// the legend; alone, the one series needs no grouping and no legend.
    @ChartContentBuilder
    private func energyMark(x: Date, y: Double, unit: Calendar.Component, series: String, grouped: Bool) -> some ChartContent {
        if grouped {
            BarMark(x: .value(L10n.text("Date"), x, unit: unit), y: .value(L10n.text("Energy"), y))
                .foregroundStyle(by: .value(L10n.text("Series"), series))
                .position(by: .value(L10n.text("Series"), series))
        } else {
            BarMark(x: .value(L10n.text("Date"), x, unit: unit), y: .value(L10n.text("Energy"), y))
                .foregroundStyle(HisingenTheme.chartInfo)
        }
    }

    private func levelChart(_ hours: [TibberPriceLevel: Double]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Price Levels")).hisType(.label, weight: .medium).foregroundStyle(HisingenTheme.ink)
            Chart(TibberPriceLevel.allCases, id: \.self) { level in
                BarMark(x: .value(L10n.text("Level"), level.title),
                        y: .value(L10n.text("Hours"), hours[level] ?? 0))
                    .foregroundStyle(HisingenTheme.chartInfo)
            }
            .historyYAxis("h")
            .frame(height: levelChartHeight)
            .accessibilityLabel(L10n.text("Price Levels"))
            .accessibilityValue(chartAccessibilityValue(points: TibberPriceLevel.allCases.map { hours[$0] ?? 0 }))
            Text(L10n.text("Hours at each of Tibber's price levels in the prices published for today and tomorrow."))
                .hisType(.micro).foregroundStyle(.secondary)
                .hisCaptionLeading()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
