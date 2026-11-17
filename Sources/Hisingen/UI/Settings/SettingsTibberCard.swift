import SwiftUI

/// Settings, Electricity: the electricity supplier. A Tibber access token prices charger sessions
/// from Tibber's own 15-minute prices, with no Home Assistant and no charger required. Nothing here
/// is required; without it sessions are priced from the rate settings above.
@MainActor
struct SettingsTibberCard: View {
    @ObservedObject var model: HomeChargingModel

    @State private var token = ""
    @State private var isConnecting = false
    @State var homes: [TibberHome]?
    @State var selection = ""
    @State private var failure: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "bolt", title: L10n.text("Electricity Supplier"), color: HisingenTheme.semanticGood)
                Text(L10n.text("Optional. Connects Tibber to price charging sessions from its own 15-minute prices, without Home Assistant."))
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
                KVRow(L10n.text("Prices"), model.tibberProblem ?? L10n.text("Used for charging sessions"),
                      valueWarning: model.tibberProblem != nil)
            }
            Text(L10n.text("Tibber's price includes energy, taxes and its markup but not the grid fee. Set the network fee on the paired charger."))
                .hisType(.caption).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            Button { model.disconnectTibber(); token = ""; homes = nil } label: {
                Text(L10n.text("Disconnect Tibber")).frame(minHeight: 24)
            }
            .buttonStyle(.hisSecondary(HisingenTheme.semanticCritical))
        }
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
