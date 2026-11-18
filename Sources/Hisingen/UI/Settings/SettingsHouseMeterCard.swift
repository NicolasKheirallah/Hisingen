import SwiftUI

/// Settings, Electricity: the house meter. A Perific monitor on the electricity meter's HAN port
/// gives live whole-house power, so the charging card can set the car against the rest of the
/// house, and hourly import for the Car Share rows in Log. Nothing here is required, and Hisingen
/// only reads the meter: Perific keeps balancing the charger.
///
/// Design read: the same spec-sheet card as Tibber beside it. Energy 2 / Rhythm 3 / Motion 2 from
/// DESIGN.md. The reading is a row, not a figure, because setup is the job of this card and the
/// live figure belongs on the charging card.
@MainActor
struct SettingsHouseMeterCard: View {
    @ObservedObject var meter: HouseMeterModel

    @State private var account = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var failure: String?
    @State private var found: [HouseMeter]?
    @State private var selection = ""

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "gauge", title: L10n.text("House Meter"), color: HisingenTheme.semanticGood)
                Text(L10n.text("Optional. Reads your home's electricity use from a Perific monitor, so charging can be shown against the whole house. Hisingen only reads it. Perific keeps balancing the charger."))
                    .hisType(.caption)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let chosen = meter.meter {
                    connectedView(chosen)
                } else {
                    setupView
                }
            }
        }
    }

    // MARK: Setup

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 10) {
            signInFields(detail: L10n.text("The account you use in the Perific app. It is stored in the macOS Keychain and never exported."))
            Button { Task { await signIn() } } label: {
                Text(isSigningIn ? L10n.text("Signing in…") : L10n.text("Sign in and find meters")).frame(minHeight: 24)
            }
            .buttonStyle(.hisProminent)
            .disabled(isSigningIn || !credentials.isComplete)
            failureView
            if let found {
                PanelRule()
                if found.isEmpty {
                    Text(L10n.text("This account has no meter that Hisingen can read. Check that it is the owner account in the Perific app."))
                        .hisType(.label).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Meter")).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
                        Picker("", selection: $selection) {
                            ForEach(found) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .accessibilityLabel(L10n.text("Meter"))
                    }
                    Button { use(found) } label: { Text(L10n.text("Use this meter")).frame(minHeight: 24) }
                        .buttonStyle(.hisProminent)
                        .disabled(selection.isEmpty)
                }
            }
        }
        .onAppear { if account.isEmpty { account = meter.savedUsername() ?? "" } }
    }

    // MARK: Connected

    private func connectedView(_ chosen: HouseMeter) -> some View {
        let reading = meter.presentation(carKw: nil)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 4) {
                KVRow(L10n.text("Source"), "Perific")
                KVRow(L10n.text("Meter"), chosen.name)
                KVRow(L10n.text("Status"), statusText, valueWarning: needsAttention)
                if let value = reading.houseValue {
                    KVRow(L10n.text("House Now"), value, info: L10n.text("Calculated from the meter's current and voltage, so it can read slightly above the energy your supplier bills."))
                }
                ForEach(reading.details) { detail in
                    KVRow(detail.label, detail.value, info: detail.info)
                }
            }
            if meter.link == .unauthorized {
                PanelRule()
                signInFields(detail: L10n.text("Perific did not accept the saved login. Enter the account and password again to reconnect."))
                Button { Task { await reconnect(chosen) } } label: {
                    Text(isSigningIn ? L10n.text("Signing in…") : L10n.text("Sign in")).frame(maxWidth: .infinity, minHeight: 24)
                }
                .buttonStyle(.hisProminent)
                .disabled(isSigningIn || !credentials.isComplete)
            }
            failureView
            Button { meter.disconnect(); password = ""; found = nil } label: {
                Text(L10n.text("Disconnect Perific")).frame(minHeight: 24)
            }
            .buttonStyle(.hisSecondary(HisingenTheme.semanticCritical))
        }
        .onAppear { if account.isEmpty { account = meter.savedUsername() ?? "" } }
    }

    private var statusText: String {
        switch meter.link {
        case .live: return L10n.text("Reading every 30 seconds")
        case .connecting: return L10n.text("Connecting…")
        case .reconnecting: return L10n.text("Reconnecting")
        case .unreachable(let reason): return reason
        case .unauthorized: return L10n.text("Sign-in refused")
        case .meterMissing: return L10n.text("This account no longer lists the meter")
        case .notConfigured: return L10n.text("Not connected")
        }
    }

    private var needsAttention: Bool {
        switch meter.link {
        case .unauthorized, .meterMissing, .unreachable: return true
        default: return false
        }
    }

    // MARK: Pieces

    private var credentials: DirectChargerCredentials { DirectChargerCredentials(username: account, password: password) }

    private func signInFields(detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Perific account email")).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
                Text(detail).hisType(.caption).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                TextField("", text: $account)
                    .hisField()
                    .autocorrectionDisabled()
                    .accessibilityLabel(L10n.text("Perific account email"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Password")).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
                SecureField("", text: $password)
                    .hisField()
                    .accessibilityLabel(L10n.text("Password"))
            }
        }
    }

    @ViewBuilder
    private var failureView: some View {
        if let failure {
            Text(failure)
                .hisType(.label).foregroundStyle(HisingenTheme.ink)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hisNotice(HisingenTheme.semanticCritical)
        }
    }

    // MARK: Actions

    private func signIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        failure = nil
        defer { isSigningIn = false }
        do {
            let meters = try await meter.connect(credentials: credentials)
            password = ""
            // One meter needs no choice; several do.
            if meters.count == 1, let only = meters.first {
                meter.select(only)
                found = nil
            } else {
                found = meters
                selection = meters.first?.id ?? ""
            }
        } catch {
            failure = error.localizedDescription
            found = nil
        }
    }

    private func use(_ meters: [HouseMeter]) {
        guard let chosen = meters.first(where: { $0.id == selection }) else { return }
        meter.select(chosen)
        found = nil
        failure = nil
    }

    private func reconnect(_ chosen: HouseMeter) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        failure = nil
        defer { isSigningIn = false }
        do {
            try await meter.replaceCredentials(credentials)
            password = ""
        } catch {
            failure = error.localizedDescription
        }
    }
}
