import SwiftUI

/// Settings, Electricity: the optional Home Charging integration. Enter the Home Assistant address
/// and a long-lived access token, pick the charger, and pair it with one vehicle and one saved
/// charge location. Nothing here is required; leaving it empty changes nothing else in the app.
@MainActor
struct SettingsHomeChargingCard: View {
    @ObservedObject var model: HomeChargingModel
    var state: VehicleState?
    var fleet: FleetSnapshot
    let binder: PreferenceBinder

    @State private var address = ""
    @State private var token = ""
    @State private var isTesting = false
    @State private var discovery: HomeAssistantDiscovery?
    @State private var failure: String?
    @State private var selectedCharger = ""
    @State private var map = HomeChargerEntityMap()
    @State var vin = ""
    @State var locationID = ""
    @State var isShared = false
    @State var feeText = "0"
    @State private var confirmsErase = false
    @State private var showsNexBlueBackfill = false
    // The setup extension shares these fields with the connection picker.
    @State var source: ChargerSource = .homeAssistant
    @State var account = ""
    @State var password = ""
    @State var directChargers: [DirectChargerSummary]?
    @State var directSelection = ""
    @State var directFailure: String?
    @State var isSigningIn = false
    @State var isResuming = false
    @State private var seededSource = false
    /// Reveals the setup form below an existing pairing, for a second charger.
    @State private var isAddingCharger = false

    var body: some View {
        SettingsConnectedServiceCard(
            title: "Home Charging",
            symbol: "powerplug",
            detail: "Connect a charger to view its status, control charging, and import sessions."
        ) {
            if model.pairings.isEmpty {
                setupView
            } else {
                chargerList
                if let pairing = model.pairing {
                    PanelRule()
                    pairedView(pairing)
                }
                if isAddingCharger {
                    PanelRule()
                    setupView
                    Button { isAddingCharger = false } label: {
                        Text(L10n.text("Cancel")).frame(minHeight: 24)
                    }
                    .buttonStyle(.hisSecondary)
                } else {
                    Button { isAddingCharger = true; discovery = nil; failure = nil } label: {
                        Text(L10n.text("Add another charger")).frame(minHeight: 24)
                    }
                    .buttonStyle(.hisSecondary)
                    .accessibilityHint(L10n.text("Pairs a second charger. Both stay listed, one holds the live connection and the other keeps its last reading."))
                }
            }
        }
        .onAppear {
            if address.isEmpty { address = model.savedAddress ?? "" }
            if vin.isEmpty { vin = state?.identity.vin ?? fleet.vehicles.first ?? "" }
            // A login saved before pairing would otherwise sit behind the Home Assistant choice,
            // which is what this view starts on every time Settings opens.
            if !seededSource, model.pairing == nil, source == .homeAssistant,
               let saved = ChargerSource.allCases.first(where: { model.hasSavedCredentials(for: $0) }) {
                source = saved
            }
            seededSource = true
        }
        .confirmationDialog(L10n.text("Remove Home Assistant from Hisingen?"), isPresented: $confirmsErase, titleVisibility: .visible) {
            Button(L10n.text("Remove Connection and Token"), role: .destructive) { model.eraseEverything(); discovery = nil; token = "" }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("The saved token and the charger pairing are deleted. Charging history that was already recorded stays."))
        }
        .sheet(isPresented: $showsNexBlueBackfill) {
            if let pairing = model.pairing, pairing.source == .nexBlue {
                NexBlueHistorySheet(model: model, timeZone: pairing.timeZone)
            }
        }
    }

    // MARK: - Setup

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 10) {
            field(L10n.text("Charger connection"), detail: nil) {
                Picker("", selection: $source) {
                    ForEach(ChargerSource.allCases) { Text($0.providerName).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel(L10n.text("Charger connection"))
                .disabled(isSigningIn)
                .onChange(of: source) { _, _ in directFailure = nil; directChargers = nil; failure = nil }
            }
            if source == .homeAssistant { homeAssistantSetup } else { directSetupView }
        }
    }

    @ViewBuilder
    private var homeAssistantSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            field(L10n.text("Home Assistant address"), detail: L10n.text("For example http://homeassistant.local:8123")) {
                TextField("", text: $address)
                    .hisField()
                    .autocorrectionDisabled()
                    .accessibilityLabel(L10n.text("Home Assistant address"))
            }
            field(L10n.text("Long-lived access token"),
                  detail: L10n.text("Create it in your Home Assistant profile under Security. It is stored in the macOS Keychain and never exported.")) {
                SecureField("", text: $token)
                    .hisField()
                    .accessibilityLabel(L10n.text("Long-lived access token"))
            }
            HStack(spacing: 8) {
                Button { Task { await connect() } } label: {
                    Text(isTesting ? L10n.text("Connecting…") : L10n.text("Connect and find chargers")).frame(minHeight: 24)
                }
                .buttonStyle(.hisProminent)
                .disabled(isTesting || address.trimmingCharacters(in: .whitespaces).isEmpty || (token.isEmpty && !model.hasToken))
                if model.hasToken && token.isEmpty {
                    Text(L10n.text("A saved token is used."))
                        .hisType(.caption).foregroundStyle(HisingenTheme.inkMuted)
                }
            }
            if let failure {
                Text(failure)
                    .hisType(.label).foregroundStyle(HisingenTheme.ink)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hisNotice(HisingenTheme.semanticCritical)
            }
            if let discovery { pairingForm(discovery) }
        }
    }

    @ViewBuilder
    private func pairingForm(_ discovery: HomeAssistantDiscovery) -> some View {
        PanelRule()
        Text(L10n.format("Connected to Home Assistant %@", discovery.version))
            .hisType(.label, weight: .semibold).foregroundStyle(HisingenTheme.ink)
        if !discovery.usedDeviceRegistry {
            Text(L10n.text("This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number."))
                .hisType(.micro).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
        }

        field(L10n.text("Charger"), detail: discovery.chargers.isEmpty ? L10n.text("No NexBlue charger was found. Map the entities by hand below.") : nil) {
            Picker("", selection: $selectedCharger) {
                Text(L10n.text("Map by hand")).tag("")
                ForEach(discovery.chargers) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .accessibilityLabel(L10n.text("Charger"))
            .onChange(of: selectedCharger) { _, id in
                if let charger = discovery.chargers.first(where: { $0.id == id }) {
                    var chosen = charger.entities
                    chosen.vehicleBattery = map.vehicleBattery
                    map = chosen
                }
            }
        }
        DisclosureGroup(L10n.text("Entities")) {
            VStack(spacing: 6) {
                entityPicker(L10n.text("Charging state"), \.chargingState, domain: "sensor", discovery)
                entityPicker(L10n.text("Power"), \.power, domain: "sensor", discovery)
                entityPicker(L10n.text("Session energy"), \.sessionEnergy, domain: "sensor", discovery)
                entityPicker(L10n.text("Charging switch"), \.chargingSwitch, domain: "switch", discovery)
                entityPicker(L10n.text("Lifetime energy"), \.lifetimeEnergy, domain: "sensor", discovery, optional: true)
                entityPicker(L10n.text("Current limit"), \.currentLimit, domain: "sensor", discovery, optional: true)
                // Reading and writing the limit are different entities in most integrations: a
                // sensor reports it, a `number` entity changes it. Mapping the number is what
                // enables the control on the charger card.
                entityPicker(L10n.text("Writable current limit"), \.currentLimitNumber, domain: "number", discovery, optional: true)
                entityPicker(L10n.text("Charging enabled"), \.chargingEnabled, domain: "binary_sensor", discovery, optional: true)
                entityPicker(L10n.text("Cable lock"), \.cableLock, domain: "binary_sensor", discovery, optional: true)
            }
            .padding(.top, 6)
        }
        .hisType(.body, weight: .medium)

        pairingFields(vehicleDetail: L10n.text("Sessions and plans are tied to this vehicle only. A car being near the charger is not enough."))
        field(L10n.text("Battery sensor for percentage plans"),
              detail: L10n.text("Optional. A sensor Home Assistant keeps on its own, for example from a Polestar integration.")) {
            Picker("", selection: Binding(get: { map.vehicleBattery ?? "" }, set: { map.vehicleBattery = $0.isEmpty ? nil : $0 })) {
                Text(L10n.text("None")).tag("")
                ForEach(discovery.batterySensors) { Text($0.name).tag($0.entityID) }
            }
            .labelsHidden()
            .accessibilityLabel(L10n.text("Battery sensor"))
        }
        field(L10n.text("Network fee, öre per kWh"),
              detail: L10n.text("Tibber's price leaves out the variable grid fee. Add yours here, or leave 0.")) {
            TextField("", text: $feeText)
                .hisField().frame(width: 90).multilineTextAlignment(.trailing)
                .accessibilityLabel(L10n.text("Network fee in öre per kWh"))
        }
        if !map.missingRequired.isEmpty {
            Text(L10n.format("Still needed: %@.", map.missingRequired.joined(separator: ", ")))
                .hisType(.label).foregroundStyle(HisingenTheme.semanticWarning)
        }
        Button { pair(discovery) } label: { Text(L10n.text("Pair charger")).frame(minHeight: 24) }
            .buttonStyle(.hisProminent)
            .disabled(!map.isUsable || vin.isEmpty)
    }

    // MARK: - Every paired charger

    /// Both chargers, with the one that holds the live connection marked. Selecting a row switches
    /// the connection to it; the other keeps its last reading, with the time it was read.
    private var chargerList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Chargers"))
                .hisType(.caption, weight: .semibold)
                .foregroundStyle(HisingenTheme.inkMuted)
            ForEach(model.pairings, id: \.identity) { candidate in
                let isLive = candidate.identity == model.pairing?.identity
                Button { model.selectCharger(identity: candidate.identity) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.chargerName)
                                .hisType(.label, weight: .medium)
                                .foregroundStyle(HisingenTheme.ink)
                            Text(chargerDetail(candidate, isLive: isLive))
                                .hisType(.micro)
                                .foregroundStyle(HisingenTheme.inkMuted)
                        }
                        Spacer(minLength: 6)
                        if isLive {
                            Text(L10n.text("Live connection"))
                                .hisType(.micro, weight: .medium)
                                .foregroundStyle(HisingenTheme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .help(isLive
                      ? L10n.text("This charger holds the live connection.")
                      : L10n.text("Show this charger's readings and commands."))
                .accessibilityAddTraits(isLive ? .isSelected : [])
            }
        }
    }

    private func chargerDetail(_ candidate: HomeChargingPairing, isLive: Bool) -> String {
        let vehicle = vehicleTitle(candidate.vin)
        let place = candidate.locationAlias.isEmpty ? L10n.text("None") : candidate.locationAlias
        var parts = [vehicle, place]
        if isLive {
            parts.append(linkText)
        } else if let contact = model.lastContact(for: candidate) {
            parts.append(L10n.format("Last read %@", HomeChargingTime.time(contact, in: candidate.timeZone)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Paired

    @ViewBuilder
    private func pairedView(_ pairing: HomeChargingPairing) -> some View {
        VStack(spacing: 4) {
            if pairing.source.isDirect {
                KVRow(L10n.text("Connected through"), pairing.source.providerName)
            } else {
                KVRow(L10n.text("Home Assistant"), HomeAssistantAddressText.host(pairing.baseURL))
            }
            KVRow(L10n.text("Connection"), linkText, valueWarning: linkIsProblem)
            if let contact = model.lastContact {
                KVRow(L10n.text("Last contact"), HomeChargingTime.time(contact, in: pairing.timeZone))
            }
            KVRow(L10n.text("Charger"), pairing.chargerName)
            KVRow(L10n.text("Vehicle"), vehicleTitle(pairing.vin))
            KVRow(L10n.text("Charge location"), pairing.locationAlias.isEmpty ? L10n.text("None") : pairing.locationAlias)
            KVRow(L10n.text("Shared charger"), pairing.isSharedCharger ? L10n.text("Yes") : L10n.text("No"))
            if !pairing.source.isDirect {
                KVRow(L10n.text("Hisingen component"), componentText,
                      info: L10n.text("The component runs plans inside Home Assistant and records finished sessions there, so they survive a closed Mac. Plans need it; status, controls and history do not."))
            }
            KVRow(L10n.text("Session history"), syncText)
            if pairing.source == .nexBlue, let receipt = model.lastNexBlueImport {
                KVRow(L10n.text("Last successful import"), HomeChargingTime.dateTime(receipt.importedAt, in: pairing.timeZone))
                KVRow(L10n.text("Imported date range"), HomeChargingTime.range(receipt.range, in: pairing.timeZone))
            }
        }
        // Charger sessions are only kept when the existing history switch is on, so it sits here
        // beside the row that reports it.
        toggleRow(L10n.text("Charging Session History"),
                  detail: L10n.text("Needed to keep charger sessions in Hisingen's local history."),
                  isOn: binder.toggle(\.storeChargingHistory, .presentation))
        HStack(spacing: 8) {
            Button { Task { await model.syncSessions() } } label: { Text(L10n.text("Import sessions now")).frame(minHeight: 24) }
                .buttonStyle(.hisSecondary)
                .disabled(model.syncState == .running)
            Button { model.refreshNow() } label: { Text(L10n.text("Reconnect")).frame(minHeight: 24) }
                .buttonStyle(.hisSecondary)
        }
        if pairing.source == .nexBlue {
            Button(L10n.text("Import earlier sessions")) { showsNexBlueBackfill = true }
                .buttonStyle(.hisSecondary)
                .disabled(!model.canBackfillNexBlue)
        }
        if model.link == .unauthorized, pairing.source.isDirect {
            directReloginForm(pairing)
        } else if model.link == .unauthorized {
            field(L10n.text("New access token"), detail: L10n.text("Home Assistant rejected the saved token. Paste a new long-lived token to reconnect.")) {
                HStack(spacing: 8) {
                    SecureField("", text: $token)
                        .hisField()
                        .accessibilityLabel(L10n.text("New access token"))
                    Button {
                        do { try model.replaceToken(token); token = ""; failure = nil } catch { failure = error.localizedDescription }
                    } label: { Text(L10n.text("Save token")).frame(minHeight: 24) }
                        .buttonStyle(.hisProminent)
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let failure {
                Text(failure).hisType(.label).foregroundStyle(HisingenTheme.semanticCritical)
            }
        }
        if pairing.source.isDirect && pairing.source != .nexBlue {
            Text(L10n.text("Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history."))
                .hisType(.caption).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
        }
        // Tibber's price leaves out the grid fee, whichever way the charger is connected.
        field(L10n.text("Network fee, öre per kWh"), detail: L10n.text("Added to Tibber prices when pricing sessions.")) {
            TextField("", text: $feeText, onCommit: { model.updateNetworkFee(Double(feeText.replacingOccurrences(of: ",", with: ".")) ?? 0) })
                .hisField().frame(width: 90).multilineTextAlignment(.trailing)
                .accessibilityLabel(L10n.text("Network fee in öre per kWh"))
        }
        .onAppear { feeText = String(format: "%g", locale: L10n.displayLocale, pairing.networkFeeOrePerKwh) }
        HStack(spacing: 8) {
            Button { Task { await model.unpairCancellingPlan(); discovery = nil } } label: { Text(L10n.text("Unpair charger")).frame(minHeight: 24) }
                .buttonStyle(.hisSecondary)
            if pairing.source.isDirect {
                Button { model.signOutDirect(); directChargers = nil; password = "" } label: { Text(L10n.text("Sign out")).frame(minHeight: 24) }
                    .buttonStyle(.hisSecondary(HisingenTheme.semanticCritical))
            } else {
                Button { confirmsErase = true } label: { Text(L10n.text("Remove token")).frame(minHeight: 24) }
                    .buttonStyle(.hisSecondary(HisingenTheme.semanticCritical))
            }
        }
        if case .finished(let summary) = model.syncState, summary.unassigned > 0 {
            Text(L10n.format("%d charger sessions could not be tied to a vehicle and are kept unassigned.", summary.unassigned))
                .hisType(.micro).foregroundStyle(HisingenTheme.inkMuted)
        }
    }

    private var linkIsProblem: Bool {
        switch model.link {
        case .live, .connecting: return false
        default: return true
        }
    }

    private var linkText: String {
        switch model.link {
        case .notConfigured: return L10n.text("Not set up")
        case .connecting: return L10n.text("Connecting")
        case .live: return L10n.text("Connected")
        case .reconnecting: return L10n.text("Reconnecting")
        case .unreachable: return L10n.text("Unreachable")
        case .unauthorized: return model.pairing?.source.isDirect == true ? L10n.text("Sign-in rejected") : L10n.text("Token rejected")
        }
    }

    private var componentText: String {
        switch model.componentInstalled {
        case true?: return L10n.text("Installed")
        case false?: return L10n.text("Not installed")
        case nil: return L10n.text("Not checked yet")
        }
    }

    private var syncText: String {
        switch model.syncState {
        case .idle: return model.lastNexBlueImport == nil ? L10n.text("Not imported yet") : L10n.text("Ready")
        case .running: return L10n.text("Importing")
        case .failed(let message): return message
        case .finished(let summary):
            if summary.skippedByPrivacy { return L10n.text("Off: local charging history is disabled") }
            return summary.changedRows == 0 ? L10n.text("Up to date") : L10n.format("%d sessions added or updated", summary.changedRows)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    func pairingFields(vehicleDetail: String) -> some View {
        field(L10n.text("Vehicle"), detail: vehicleDetail) {
            Picker("", selection: $vin) {
                ForEach(fleet.vehicles, id: \.self) { Text(vehicleTitle($0)).tag($0) }
            }
            .labelsHidden()
            .accessibilityLabel(L10n.text("Vehicle"))
        }
        field(L10n.text("Charge location"), detail: L10n.text("The saved location in the car where this charger stands.")) {
            Picker("", selection: $locationID) {
                Text(L10n.text("None")).tag("")
                ForEach(savedLocations) { Text($0.alias.isEmpty ? L10n.text("Unnamed location") : $0.alias).tag($0.id) }
            }
            .labelsHidden()
            .accessibilityLabel(L10n.text("Charge location"))
        }
        toggleRow(L10n.text("Other cars also use this charger"),
                  detail: L10n.text("A shared charger only records a session for this vehicle when the car's own charging overlaps it."),
                  isOn: $isShared)
    }

    var savedLocations: [ChargeLocationSnapshot] {
        let snapshot = vin == state?.identity.vin ? state : fleet.snapshot(for: vin)
        return (snapshot?.energy.locations ?? []).filter { $0.isSavedLocation || !$0.alias.isEmpty }
    }

    func vehicleTitle(_ vin: String) -> String {
        let snapshot = vin == state?.identity.vin ? state : fleet.snapshot(for: vin)
        let name = snapshot?.identity.modelName ?? snapshot?.model.brand.displayName ?? L10n.text("Vehicle")
        return "\(name) \(vin.suffix(4))"
    }

    private func entityPicker(_ title: String, _ keyPath: WritableKeyPath<HomeChargerEntityMap, String?>, domain: String,
                              _ discovery: HomeAssistantDiscovery, optional: Bool = false) -> some View {
        HStack {
            Text(title).hisType(.body).foregroundStyle(HisingenTheme.inkMuted)
            Spacer()
            Picker("", selection: Binding(get: { map[keyPath: keyPath] ?? "" }, set: { map[keyPath: keyPath] = $0.isEmpty ? nil : $0 })) {
                Text(optional ? L10n.text("None") : L10n.text("Choose")).tag("")
                ForEach(discovery.entities.filter { $0.domain == domain }) { Text($0.id).tag($0.id) }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            .accessibilityLabel(title)
        }
    }

    func field<Content: View>(_ title: String, detail: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
                    if let detail {
                        Text(detail).hisType(.caption).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
            }
            content()
        }
    }

    func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).hisType(.body, weight: .medium).foregroundStyle(HisingenTheme.ink)
                Text(detail).hisType(.caption).foregroundStyle(HisingenTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityLabel(title)
        }
    }

    // MARK: - Actions

    private func connect() async {
        isTesting = true
        failure = nil
        defer { isTesting = false }
        let usedToken = token.isEmpty ? (model.savedToken() ?? "") : token
        switch await model.testConnection(address: address, token: usedToken) {
        case .failure(let error):
            failure = error.localizedDescription
            discovery = nil
        case .success(let found):
            do { try model.saveConnection(address: address, token: usedToken) } catch { failure = error.localizedDescription; return }
            token = ""
            discovery = found
            if let first = found.chargers.first {
                selectedCharger = first.id
                map = first.entities
            }
            locationID = presenceLocationID() ?? ""
        }
    }

    func presenceLocationID() -> String? {
        let snapshot = vin == state?.identity.vin ? state : fleet.snapshot(for: vin)
        return snapshot?.chargeLocationPresence?.locationID
    }

    private func pair(_ discovery: HomeAssistantDiscovery) {
        let charger = discovery.chargers.first { $0.id == selectedCharger }
        let location = savedLocations.first { $0.id == locationID }
        let chargerID = charger?.id ?? HomeChargingPlanEntity.slug(map.chargingState ?? "charger")
        let pairing = HomeChargingPairing(
            baseURL: HomeAssistantAddress.normalise(address).urlString ?? address,
            chargerID: chargerID, chargerName: charger?.name ?? L10n.text("Home charger"), entities: map, vin: vin,
            locationID: locationID.isEmpty ? nil : locationID, locationAlias: location?.alias ?? L10n.text("Home"),
            isSharedCharger: isShared, timeZoneIdentifier: discovery.timeZone,
            networkFeeOrePerKwh: Double(feeText.replacingOccurrences(of: ",", with: ".")) ?? 0)
        model.pair(pairing)
        self.discovery = nil
    }
}

private enum HomeAssistantAddressText {
    static func host(_ address: String) -> String {
        URL(string: address)?.host ?? address
    }
}

private extension Result where Success == URL, Failure == HomeAssistantAddress.Failure {
    var urlString: String? {
        if case .success(let url) = self { return url.absoluteString }
        return nil
    }
}
