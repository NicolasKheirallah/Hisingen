import SwiftUI

extension SettingsHomeChargingCard {
    @ViewBuilder
    var directSetupView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isResuming {
                Text(L10n.text("Reading chargers…"))
                    .hisType(.label).foregroundStyle(HisingenTheme.inkMuted)
            } else if directChargers != nil, model.hasSavedCredentials(for: source) {
                signedInRow
            } else {
                signInFields
            }
            if let directFailure {
                Text(directFailure)
                    .hisType(.label).foregroundStyle(HisingenTheme.ink)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hisNotice(HisingenTheme.semanticCritical)
            }
            if let directChargers { directPairingForm(directChargers) }
        }
        .onAppear {
            if account.isEmpty { account = model.savedUsername(for: source) ?? "" }
        }
        .onChange(of: source) { _, newValue in
            account = model.savedUsername(for: newValue) ?? ""
            password = ""
        }
        .task(id: source) { await resumeSavedLogin() }
    }

    private var signedInRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.format("Signed in to %@", source.providerName))
                .hisType(.body, weight: .medium)
                .foregroundStyle(HisingenTheme.ink)
            Spacer(minLength: 0)
            Button(L10n.text("Sign out")) {
                model.forgetDirectLogin(source)
                directChargers = nil
                directFailure = nil
                password = ""
            }
            .buttonStyle(.hisSecondary)
        }
    }

    @ViewBuilder
    private var signInFields: some View {
        field(L10n.text("Account email"),
              detail: source == .nexBlue ? nil : L10n.format("The one you use in the %@ app. It is stored in the macOS Keychain and never exported.", source.providerName)) {
            TextField("", text: $account)
                .hisField()
                .autocorrectionDisabled()
                .accessibilityLabel(L10n.text("Account email"))
        }
        field(L10n.text("Password"), detail: nil) {
            SecureField("", text: $password)
                .hisField()
                .accessibilityLabel(L10n.text("Password"))
        }
        Button { Task { await signIn() } } label: {
            Text(isSigningIn ? L10n.text("Signing in…") : L10n.text("Sign in and find chargers")).frame(minHeight: 24)
        }
        .buttonStyle(.hisProminent)
        .disabled(isSigningIn || !DirectChargerCredentials(username: account, password: password).isComplete)
    }

    @ViewBuilder
    private func directPairingForm(_ chargers: [DirectChargerSummary]) -> some View {
        PanelRule()
        if chargers.isEmpty {
            Text(L10n.format("This account has no charger that Hisingen can control. Check that it is the owner account in the %@ app.", source.providerName))
                .hisType(.label).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
        } else {
            field(L10n.text("Charger"), detail: nil) {
                Picker("", selection: $directSelection) {
                    ForEach(chargers) { Text($0.displayName).tag($0.id) }
                }
                .labelsHidden()
                .accessibilityLabel(L10n.text("Charger"))
            }
            pairingFields(vehicleDetail: L10n.text("Sessions are tied to this vehicle only. A car being near the charger is not enough."))
            if source != .nexBlue {
                Text(L10n.text("Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history."))
                    .hisType(.caption).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
            field(L10n.text("Network fee, öre per kWh"),
                  detail: L10n.text("Tibber's price leaves out the variable grid fee. Add yours here, or leave 0.")) {
                TextField("", text: $feeText)
                    .hisField().frame(width: 90).multilineTextAlignment(.trailing)
                    .accessibilityLabel(L10n.text("Network fee in öre per kWh"))
            }
            Button { pairDirect(chargers) } label: { Text(L10n.text("Pair charger")).frame(minHeight: 24) }
                .buttonStyle(.hisProminent)
                .disabled(directSelection.isEmpty || vin.isEmpty)
        }
    }

    /// Asks for the login again when the vendor stopped accepting the saved one.
    @ViewBuilder
    func directReloginForm(_ pairing: HomeChargingPairing) -> some View {
        field(L10n.format("Sign in to %@ again", pairing.source.providerName),
              detail: L10n.format("%@ did not accept the saved login. Enter the account and password again to reconnect.", pairing.source.providerName)) {
            VStack(spacing: 6) {
                TextField("", text: $account)
                    .hisField()
                    .autocorrectionDisabled()
                    .accessibilityLabel(L10n.text("Account email"))
                SecureField("", text: $password)
                    .hisField()
                    .accessibilityLabel(L10n.text("Password"))
                Button {
                    Task { await reconnect() }
                } label: { Text(isSigningIn ? L10n.text("Signing in…") : L10n.text("Sign in")).frame(maxWidth: .infinity, minHeight: 24) }
                    .buttonStyle(.hisProminent)
                    .disabled(isSigningIn || !DirectChargerCredentials(username: account, password: password).isComplete)
            }
        }
        .onAppear { if account.isEmpty { account = model.savedUsername(for: pairing.source) ?? "" } }
        if let directFailure {
            Text(directFailure).hisType(.label).foregroundStyle(HisingenTheme.semanticCritical)
        }
    }

    // MARK: Actions

    private func signIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        directFailure = nil
        defer { isSigningIn = false }
        let credentials = DirectChargerCredentials(username: account, password: password)
        do {
            let chargers = try await model.connectDirect(source, credentials: credentials)
            password = ""
            directChargers = chargers
            directSelection = chargers.first?.id ?? ""
            locationID = presenceLocationID() ?? ""
        } catch {
            directFailure = error.localizedDescription
            directChargers = nil
        }
    }

    /// Picks up an account that signed in earlier, so leaving Settings before pairing does not cost the login.
    private func resumeSavedLogin() async {
        guard directChargers == nil, !isSigningIn, !isResuming, model.hasSavedCredentials(for: source) else { return }
        isResuming = true
        directFailure = nil
        defer { isResuming = false }
        do {
            guard let chargers = try await model.resumeDirect(source) else { return }
            directChargers = chargers
            directSelection = chargers.first?.id ?? ""
            locationID = presenceLocationID() ?? ""
        } catch is CancellationError {
            return
        } catch {
            directFailure = error.localizedDescription
        }
    }

    private func reconnect() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        directFailure = nil
        defer { isSigningIn = false }
        do {
            try await model.replaceCredentials(DirectChargerCredentials(username: account, password: password))
            password = ""
        } catch {
            directFailure = error.localizedDescription
        }
    }

    private func pairDirect(_ chargers: [DirectChargerSummary]) {
        guard let charger = chargers.first(where: { $0.id == directSelection }) else { return }
        let location = savedLocations.first { $0.id == locationID }
        // A direct charger has no Home Assistant, so its time zone is the Mac's.
        let pairing = HomeChargingPairing(
            baseURL: "", chargerID: charger.id, chargerName: charger.name.isEmpty ? source.providerName : charger.name,
            entities: HomeChargerEntityMap(), vin: vin,
            locationID: locationID.isEmpty ? nil : locationID, locationAlias: location?.alias ?? L10n.text("Home"),
            isSharedCharger: isShared, timeZoneIdentifier: TimeZone.current.identifier,
            networkFeeOrePerKwh: max(0, Double(feeText.replacingOccurrences(of: ",", with: ".")) ?? 0), source: source,
            chargerRole: charger.role)
        model.pair(pairing)
        directChargers = nil
    }
}
