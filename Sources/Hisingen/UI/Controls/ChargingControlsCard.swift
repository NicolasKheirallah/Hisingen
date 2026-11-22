import SwiftUI

@MainActor
struct ChargingControlsCard: View {
    let state: VehicleState
    let gate: ControlsCommandGate
    var selectedLocationID: String? = nil

    static func locationAnchor(_ id: String) -> String { "charge-location-\(id)" }

    @State private var expandedLocations: Set<String> = []

    @State private var chargeTargetDraft: Double?
    @State private var ampLimitDraft: Double?
    @State private var locationAmpDrafts: [String: Double] = [:]
    @State private var locationSocDrafts: [String: Double] = [:]
    /// Optimised-charging has no drag to end, so its optimistic value is held until the
    /// provider reports it. Reading straight from server state made the switch animate back
    /// to where it started, undoing the user's gesture and then redoing it seconds later.
    @State private var optimisedDrafts: [String: Bool] = [:]
    @State private var showAddLocation = false
    @State private var renamingLocation: ChargeLocationSnapshot?
    @State private var renameDraft: String = ""
    /// Set when the user taps a location's delete button; the row is only removed
    /// after the confirmation dialog's destructive action forwards the command.
    @State private var locationPendingDelete: ChargeLocationSnapshot?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.preferencesStore) private var preferences

    private var profile: VehicleCapabilityProfile { state.capabilityProfile }
    private var features: Set<AppFeature> { gate.features }
    private var chargeBounds: VehicleChargeBounds {
        VehicleChargeBounds(capabilities: state.otaCapabilities)
    }
    private var chargeTarget: Int? {
        state.energy.targetPercentage.flatMap { $0 > 0 ? $0 : nil }
    }
    private var ampLimit: Int? {
        state.energy.currentLimitAmps.flatMap { $0 > 0 ? $0 : nil }
    }
    /// What the slider is showing. The readout used to follow the server alone, so the knob
    /// moved under the pointer while the number beside it stayed frozen until the command
    /// round-tripped. §1 asks for feedback continuous *during* the interaction.
    private var displayedChargeTarget: Int? {
        chargeTargetDraft.map { Int($0.rounded()) } ?? chargeTarget
    }
    private var displayedAmpLimit: Int? {
        ampLimitDraft.map { Int($0.rounded()) } ?? ampLimit
    }

    var body: some View {
        let chargingCommands = [RemoteCommand.setChargeTarget(80), .setAmpLimit(16), .startChargingOverride]
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "bolt", title: L10n.text("Charging Controls"), color: HisingenTheme.semanticGood)
                gate.dimReason(gate.liveAvailability(chargingCommands))

                // Passive capability line, styled after the Target/Current Limit header rows.
                // Only rendered when the vehicle reports the setting as on; a nil or false
                // report simply leaves the row out.
                if state.energy.diagnostics?.isBidirectionalChargingEnabled == true {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right")
                            .hisType(.label, weight: .medium)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(L10n.text("Bidirectional Charging"))
                            .hisType(.label, weight: .medium)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(L10n.text("Enabled"))
                            .hisType(.label, weight: .semibold)
                            .foregroundStyle(HisingenTheme.semanticGood)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("Bidirectional Charging") + ": " + L10n.text("Enabled"))
                    .transition(.opacity)
                    .hisAnimation(Motion.layout, value: state.energy.diagnostics?.isBidirectionalChargingEnabled)
                }

                if profile.permits(.chargeTarget) && features.contains(.remoteCharging) {
                    chargeTargetControls
                }
                if profile.permits(.chargingCurrentLimit) && features.contains(.remoteCharging) {
                    currentLimitControls
                }
                if profile.permits(.chargingScheduleOverride)
                    && (features.contains(.remoteCharging) || features.contains(.remoteSchedules)) {
                    Divider().opacity(HisingenTheme.dividerOpacity)
                    chargeOverrideButtons
                }

                chargeLocationsSection
            }
        }
        .opacity(gate.liveOpacity(chargingCommands))
        .hisAnimation(Motion.stateChange, value: gate.liveAvailability(chargingCommands))
        .sheet(isPresented: $showAddLocation) {
            ChargeLocationEditorSheet(
                defaultAmpLimit: ampLimit ?? 16,
                capabilities: state.otaCapabilities
            ) { alias, amps, soc, optimised in
                gate.send(.createChargeLocationAtCar(
                    alias: alias,
                    ampLimit: amps,
                    minimumSoc: soc,
                    optimisedCharging: optimised
                ))
            }
        }
        .alert(
            L10n.text("Rename charge location"),
            isPresented: Binding(
                get: { renamingLocation != nil },
                set: { if !$0 { renamingLocation = nil } }
            )
        ) {
            TextField(L10n.text("Location name"), text: $renameDraft)
            // Save used to close the alert and do nothing at all when the field was empty or
            // unchanged, which reads as a save that worked. It is now disabled with the reason
            // attached, so the state is visible before the press rather than after it.
            Button(L10n.text("Save")) {
                guard let location = renamingLocation else { return }
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != location.alias else { return }
                gate.send(.updateChargeLocationAlias(id: location.id, alias: trimmed))
                renamingLocation = nil
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                          == (renamingLocation?.alias ?? ""))
            .help(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  ? L10n.text("Enter a name first.")
                  : L10n.text("The name is unchanged."))
            Button(L10n.text("Cancel"), role: .cancel) { renamingLocation = nil }
        }
        .confirmationDialog(
            L10n.text("Delete this charge location?"),
            isPresented: Binding(
                get: { locationPendingDelete != nil },
                set: { if !$0 { locationPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("Delete Location"), role: .destructive) {
                if let location = locationPendingDelete {
                    gate.send(.deleteChargeLocation(id: location.id))
                }
                locationPendingDelete = nil
            }
            Button(L10n.text("Cancel"), role: .cancel) { locationPendingDelete = nil }
        } message: {
            deleteConfirmationMessage
        }
        .onChange(of: selectedLocationID, initial: true) { _, id in
            if let id { expandedLocations.insert(id) }
        }
        .onChange(of: chargeTarget) { _, _ in chargeTargetDraft = nil }
        .onChange(of: ampLimit) { _, _ in ampLimitDraft = nil }
    }

    private var deleteConfirmationMessage: Text {
        guard let location = locationPendingDelete else { return Text("") }
        let name = location.alias.isEmpty ? L10n.text("Unnamed location") : location.alias
        return Text(L10n.format(
            "The vehicle will delete \u{201C}%@\u{201D} and its per-location charge limits.",
            name
        ))
    }

    /// Whether this vehicle service can change these settings at all. Volvo's public API reports
    /// the charge target and the current limit but exposes no write for either, so both controls
    /// rendered as sliders that were present, reachable and permanently disabled. A read-only line
    /// says what is true instead of inviting a drag that can never land.
    private var canWriteChargingSettings: Bool {
        ProviderCommandCatalog(brand: gate.brand).implements(.setChargeTarget(0))
    }

    private var readOnlySettingLine: some View {
        Text(L10n.text("This vehicle service reports this value but cannot change it."))
            .hisType(.micro)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var chargeTargetPresets: [Int] { chargeBounds.targetPresets() }

    private var chargeTargetControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("Target Limit"))
                    .hisType(.subhead)
                    .foregroundStyle(HisingenTheme.inkMuted)
                Spacer()
                Text(displayedChargeTarget.map { Format.percent(Double($0)) } ?? L10n.text("Unavailable"))
                    .hisType(.displaySmall)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .hisTelemetryValue(displayedChargeTarget, reduceMotion: reduceMotion)
            }

            if !canWriteChargingSettings {
                readOnlySettingLine
            } else if let chargeTarget {
                Slider(
                    value: Binding(
                        get: { chargeTargetDraft ?? Double(chargeTarget) },
                        set: { chargeTargetDraft = $0 }
                    ),
                    in: Double(chargeBounds.targetRange.lowerBound)...Double(chargeBounds.targetRange.upperBound),
                    step: 5,
                    onEditingChanged: { editing in
                        guard !editing, let draft = chargeTargetDraft else { return }
                        chargeTargetDraft = nil
                        let rounded = Int(draft.rounded())
                        guard rounded != chargeTarget else { return }
                        gate.send(.setChargeTarget(rounded))
                    }
                )
                .tint(HisingenTheme.accent)
                .disabled(gate.isDisabled(.setChargeTarget(chargeTarget)))
                .accessibilityLabel(L10n.text("Charge target"))
                .accessibilityValue(Format.percent(Double(
                    chargeTargetDraft.map { Int($0.rounded()) } ?? chargeTarget
                )))
                .transition(.opacity)
                gate.sendingOverlay(.setChargeTarget(chargeTarget))
                // The consequence of the draft, while the finger is still on it: the car's
                // own numbers project the time and range to the drafted target. Shows
                // nothing when the car did not report enough to project from.
                ChargeTargetProjection(
                    state: state,
                    draftPercent: chargeTargetDraft.map { Int($0.rounded()) } ?? chargeTarget,
                    distanceUnit: preferences.distanceUnit
                )
            } else {
                // Without a reported target the slider has nothing to start from, so the presets
                // are the way to set one.
                UnderlineSegments(
                    options: chargeTargetPresets.map { target in
                        (value: target,
                         title: target == chargeBounds.dailyTarget
                            ? L10n.format("Daily %@", Format.percent(Double(target)))
                            : Format.percent(Double(target)))
                    },
                    // Nothing is selected: the vehicle did not report a target to mark.
                    selection: Binding(get: { chargeTarget ?? -1 }, set: { gate.send(.setChargeTarget($0)) }),
                    accessibilityLabel: L10n.text("Charge target")
                )
                Text(L10n.text("The vehicle did not report its current target. Choose a preset to set a new value."))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if let queued = state.energy.diagnostics?.unappliedTargetPercentage(current: chargeTarget) {
                pendingSyncLine(Format.percent(Double(queued)))
            } else if let note = VehicleChargingCard.staleSettingNote(
                reportedAt: state.energy.targetPercentageReportedAt
            ) {
                staleSettingNoteLine(note)
            }
        }
        .hisAnimation(Motion.layout, value: chargeTarget)
        .hisAnimation(Motion.layout, value: state.energy.diagnostics?.pendingTargetPercentage)
    }

    /// The backend queues a setting change behind the car's next wake (observed live:
    /// `pendingAmpLimit` rides alongside the synced value until the vehicle applies it).
    /// Saying so keeps a queued number from reading as one the car already has.
    private func pendingSyncLine(_ queuedValue: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.badge.clock")
                .hisType(.micro)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.format("%@ queued · applies when the car wakes", queuedValue))
                .hisType(.micro, weight: .medium)
                .foregroundStyle(.secondary)
                .hisCaptionLeading()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("%@ queued · applies when the car wakes", queuedValue))
        .transition(.opacity)
    }

    /// The same "Last changed" note the charging card's detail rows carry: a setting the car
    /// has not touched for over a month should not read as fresh on the sliders either.
    private func staleSettingNoteLine(_ note: String) -> some View {
        Text(note)
            .hisType(.micro)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .transition(.opacity)
    }

    private func amperageEntry(title: String, current: Int?, command: @escaping (Int) -> RemoteCommand) -> LimitEntry {
        let range = chargeBounds.amperageRange
        return LimitEntry(
            title: title, unit: "A", range: range, current: current,
            rangeText: L10n.format("From %1$@ to %2$@", Format.amps(range.lowerBound), Format.amps(range.upperBound)),
            command: command
        )
    }

    private var currentLimitControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.text("Current Limit"))
                    .hisType(.subhead)
                    .foregroundStyle(HisingenTheme.inkMuted)
                if ampLimit == nil {
                    InformationButton(message: L10n.text("The vehicle did not report a configurable current limit."),
                                      subject: L10n.text("Current Limit"))
                }
                Spacer()
                if let ampLimit, canWriteChargingSettings {
                    LimitEntryButton(
                        entry: amperageEntry(title: L10n.text("Current Limit"), current: ampLimit) { .setAmpLimit($0) },
                        isAvailable: !gate.isDisabled(.setAmpLimit(ampLimit)),
                        color: HisingenTheme.inkMuted, send: gate.send
                    )
                }
                Text(displayedAmpLimit.map { Format.amps($0) } ?? L10n.text("Unavailable"))
                    .hisType(.displaySmall)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .hisTelemetryValue(displayedAmpLimit, reduceMotion: reduceMotion)
            }

            if !canWriteChargingSettings {
                readOnlySettingLine
            } else if let ampLimit {
                let presets = chargeBounds.amperagePresets()
                if presets.count > 1 {
                    // The reported limit is underlined, so the row reads as "where it is now" and a
                    // press as "move it there". The mark follows the car's report, not the press.
                    UnderlineSegments(
                        options: presets.map { (value: $0, title: Format.amps($0)) },
                        selection: Binding(
                            get: { ampLimit },
                            set: { preset in
                                guard preset != ampLimit else { return }
                                gate.send(.setAmpLimit(preset))
                            }
                        ),
                        accessibilityLabel: L10n.text("Current limit")
                    )
                    .disabled(gate.isDisabled(.setAmpLimit(ampLimit)))
                    gate.sendingOverlay(.setAmpLimit(ampLimit))
                }
                Slider(
                    value: Binding(
                        get: { ampLimitDraft ?? Double(ampLimit) },
                        set: { ampLimitDraft = $0 }
                    ),
                    in: Double(chargeBounds.amperageRange.lowerBound)...Double(chargeBounds.amperageRange.upperBound),
                    step: 1,
                    onEditingChanged: { editing in
                        guard !editing, let draft = ampLimitDraft else { return }
                        ampLimitDraft = nil
                        let rounded = Int(draft.rounded())
                        guard rounded != ampLimit else { return }
                        gate.send(.setAmpLimit(rounded))
                    }
                )
                .tint(HisingenTheme.accent)
                .disabled(gate.isDisabled(.setAmpLimit(ampLimit)))
                .accessibilityLabel(L10n.text("Current limit"))
                .accessibilityValue(Format.amps(
                    ampLimitDraft.map { Int($0.rounded()) } ?? ampLimit
                ))
                .transition(.opacity)
            }
            if let queued = state.energy.diagnostics?.unappliedLimitAmps(current: ampLimit) {
                pendingSyncLine(Format.amps(queued))
            } else if let note = VehicleChargingCard.staleSettingNote(
                reportedAt: state.energy.currentLimitReportedAt
            ) {
                staleSettingNoteLine(note)
            }
        }
        .hisAnimation(Motion.layout, value: ampLimit)
        .hisAnimation(Motion.layout, value: state.energy.diagnostics?.pendingLimitAmps)
    }

    private var chargeOverrideButtons: some View {
        VStack(spacing: 6) {
            // Reports the state the two buttons below act on: the manual override is live at
            // the vehicle, so "Resume Schedule" is the meaningful press. Mirrors the "Here"
            // pill idiom, including the reduce-motion crossfade.
            if state.energy.chargeNowActive == true {
                HStack(spacing: 6) {
                    Pill(text: L10n.text("Charge Now"), color: HisingenTheme.semanticGood, symbol: "bolt")
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
                    Spacer()
                }
            }
            HStack(spacing: 8) {
                Button {
                    gate.send(.startChargingOverride)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt")
                        Text(L10n.text("Charge Now")).hisType(.label, weight: .medium)
                        gate.sendingOverlay(.startChargingOverride)
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.hisProminent)
                .disabled(gate.isDisabled(.startChargingOverride))

                Button {
                    gate.send(.stopChargingOverride)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(L10n.text("Resume Schedule")).hisType(.label, weight: .medium)
                        gate.sendingOverlay(.stopChargingOverride)
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.hisSecondary)
                .disabled(gate.isDisabled(.stopChargingOverride))
            }
            if let queuedOverride = state.energy.unappliedChargeNowOverride(current: state.energy.chargeNowActive) {
                pendingSyncLine(queuedOverride
                    ? L10n.text("Charge now queued · applies when the car wakes")
                    : L10n.text("Resume schedule queued · applies when the car wakes"))
            }
            if let note = chargeOverrideStateNote {
                Text(note)
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .hisAnimation(Motion.stateChange, value: state.energy.chargeNowActive)
        .hisAnimation(Motion.layout, value: state.energy.pendingChargeNowOverride)
    }

    /// The Polestar ID path can send an override but cannot read one back, so the card would
    /// otherwise say nothing after the reader pressed Charge Now. The note names the action and
    /// the gap; it never claims the override is still active. It appears only within the note
    /// window, so it explains a recent press instead of nagging permanently.
    private var chargeOverrideStateNote: String? {
        guard state.energy.chargeNowActive == nil,
              ChargeOverrideEvidence.hasRecentOverride(state.commandState.receipts) else { return nil }
        return L10n.text("Hisingen sent Charge Now, but this provider does not report whether the schedule override is still active.")
    }

    @ViewBuilder
    private var chargeLocationsSection: some View {
        if features.contains(.chargeLocations) {
            let locations = state.savedChargeLocations
            let canEditLocations = profile.permits(.chargeLocations) && features.contains(.remoteCharging)
            VStack(alignment: .leading, spacing: 10) {
                Divider().opacity(HisingenTheme.dividerOpacity)
                HStack {
                    Text(L10n.text("Saved Charge Locations"))
                        .hisType(.label, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if canEditLocations {
                        Button {
                            showAddLocation = true
                        } label: {
                            Label(L10n.text("Add here"), systemImage: "plus.circle")
                                .hisType(.caption, weight: .medium)
                                .foregroundStyle(HisingenTheme.accent)
                        }
                        .buttonStyle(.pressable)
                        .disabled(gate.isDisabled(.createChargeLocationAtCar(
                            alias: "", ampLimit: 0, minimumSoc: 0, optimisedCharging: false
                        )))
                        .help(L10n.text("Saves the vehicle's current position as a charge location."))
                    }
                }

                if let presence = state.chargeLocationPresence {
                    Label {
                        Text(chargeLocationPresenceText(presence))
                    } icon: {
                        Image(systemName: "mappin.and.ellipse")
                    }
                    .hisType(.caption, weight: .medium)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                }

                if state.energy.hasPendingLocationChanges {
                    pendingSyncLine(pendingLocationText(state.energy))
                }

                if locations.isEmpty {
                    Text(L10n.text(canEditLocations
                                   ? "No saved locations. Use “Add here” while parked where you charge."
                                   : "No saved locations reported."))
                        .hisType(.micro)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                ForEach(locations) { location in
                    DisclosureGroup(isExpanded: locationExpansion(location.id)) {
                        if canEditLocations {
                            chargeLocationRow(location)
                        } else {
                            locationReadings(location)
                        }
                    } label: {
                        Text(locationName(location))
                            .hisType(.label, weight: .semibold)
                    }
                    .disclosureGroupStyle(WholeRowDisclosureStyle())
                    .id(Self.locationAnchor(location.id))
                    .transition(.opacity)
                }
            }
            // Keyed on the collection itself so saved/removed locations reflow
            // instead of inserting and deleting instantly.
            .hisAnimation(Motion.cardChange, value: locations)
        }
    }

    private func locationExpansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedLocations.contains(id) },
            set: { expanded in
                if expanded { expandedLocations.insert(id) }
                else { expandedLocations.remove(id) }
            }
        )
    }

    private func locationName(_ location: ChargeLocationSnapshot) -> String {
        guard !preferences.privacyRedactionEnabled, !location.alias.isEmpty else {
            return L10n.text("Saved charge location")
        }
        return location.alias
    }

    private func locationReadings(_ location: ChargeLocationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            KVRow(L10n.text("Current Limit"),
                  location.ampLimit > 0 ? Format.amps(location.ampLimit) : L10n.text("Vehicle default"))
            if location.minimumSoc > 0 {
                KVRow(L10n.text("Minimum Charge"), Format.percent(Double(location.minimumSoc)))
            }
            if let mode = location.optimisedChargingModeName, location.optimisedChargingEnabled {
                KVRow(L10n.text("Optimised charging"), mode)
            } else if !location.optimisedChargingEnabled, let offer = location.optimisedChargingModeName {
                // The mode row above speaks once the switch is on; this is what the backend
                // offers while it is still off, in the same words.
                KVRow(L10n.text("Available optimised charging"), offer)
            }
            if let bidirectional = location.isBidirectionalChargingEnabled {
                KVRow(L10n.text("Bidirectional charging"),
                      bidirectional ? L10n.text("On") : L10n.text("Off"))
            }
            if !preferences.privacyRedactionEnabled, let lat = location.latitude, let lon = location.longitude {
                KVRow(L10n.text("Coordinates"), String(format: "%.4f, %.4f", locale: L10n.displayLocale, lat, lon))
                    .privacySensitive()
            }
        }
        .padding(.top, 6)
    }

    private func chargeLocationPresenceText(_ presence: ChargeLocationPresence) -> String {
        if preferences.privacyRedactionEnabled { return L10n.text("Saved charge location") }
        guard let since = presence.since else {
            return L10n.format("At %@", presence.alias)
        }
        return L10n.format("At %@ since %@", presence.alias, Format.shortTime(date: since))
    }

    private func pendingLocationText(_ energy: EnergyAndChargingSnapshot) -> String {
        let additions = energy.pendingChargeLocationCount ?? 0
        let deletions = energy.pendingChargeLocationDeletionCount ?? 0
        if additions > 0 && deletions > 0 {
            return L10n.format("%d location changes queued · applies when the car wakes", additions + deletions)
        }
        if additions > 0 {
            return L10n.format("%d location additions queued · applies when the car wakes", additions)
        }
        return L10n.format("%d location deletions queued · applies when the car wakes", deletions)
    }

    private func chargeLocationRow(_ location: ChargeLocationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "mappin.circle")
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.accent)
                Spacer()
                Button {
                    renameDraft = location.alias
                    renamingLocation = location
                } label: {
                    Image(systemName: "pencil").hisType(.caption)
                        .foregroundStyle(HisingenTheme.accent)
                }
                .buttonStyle(.pressable)
                .disabled(gate.isDisabled(.updateChargeLocationAlias(
                    id: location.id, alias: location.alias
                )))
                .help(L10n.text("Rename"))
                .accessibilityLabel(L10n.text("Rename location"))
            }

            HStack {
                Text(L10n.text("Minimum charge"))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(Double(
                    locationSocDrafts[location.id].map { Int($0.rounded()) } ?? location.minimumSoc
                )))
                .hisType(.label, weight: .bold, design: .rounded)
                .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { locationSocDrafts[location.id] ?? Double(location.minimumSoc) },
                    set: { locationSocDrafts[location.id] = $0 }
                ),
                in: 0...100,
                step: 5,
                onEditingChanged: { editing in
                    guard !editing, let draft = locationSocDrafts[location.id] else { return }
                    locationSocDrafts[location.id] = nil
                    let rounded = Int(draft.rounded())
                    guard rounded != location.minimumSoc else { return }
                    gate.send(.updateChargeLocationMinimumSoc(id: location.id, soc: rounded))
                }
            )
            .tint(HisingenTheme.accent)
            .disabled(gate.isDisabled(.updateChargeLocationMinimumSoc(id: location.id, soc: 0)))
            .accessibilityLabel(L10n.text("Minimum charge at location"))

            let locationAmpDraft = locationAmpDrafts[location.id]
            HStack {
                Text(L10n.text("Current limit"))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // `location.ampLimit > 0` is the vehicle's own answer; 0 means it does not have a
                // per-location limit. The slider below still started at 16 A for that case while
                // this label read "Vehicle default", so the two halves of one control disagreed.
                if location.ampLimit == 0, locationAmpDraft == nil {
                    Text(L10n.text("Vehicle default"))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                } else if let draftAmps = locationAmpDraft.map({ Int($0.rounded()) }) {
                    Text(Format.amps(draftAmps))
                        .hisType(.label, weight: .bold, design: .rounded)
                        .monospacedDigit()
                } else if location.ampLimit > 0 {
                    Text(Format.amps(location.ampLimit))
                        .hisType(.label, weight: .bold, design: .rounded)
                        .monospacedDigit()
                } else {
                    Text(L10n.text("Vehicle default"))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                }
                LimitEntryButton(
                    entry: amperageEntry(
                        title: L10n.text("Current limit"),
                        current: location.ampLimit > 0 ? location.ampLimit : nil
                    ) { .updateChargeLocationAmpLimit(id: location.id, amps: $0) },
                    isAvailable: !gate.isDisabled(.updateChargeLocationAmpLimit(id: location.id, amps: 0)),
                    color: HisingenTheme.inkMuted, send: gate.send
                )
            }
            Slider(
                value: Binding(
                    get: { locationAmpDraft ?? Double(location.ampLimit > 0 ? location.ampLimit : 16) },
                    set: { locationAmpDrafts[location.id] = $0 }
                ),
                in: Double(chargeBounds.amperageRange.lowerBound)...Double(chargeBounds.amperageRange.upperBound),
                step: 1,
                onEditingChanged: { editing in
                    guard !editing, let draft = locationAmpDrafts[location.id] else { return }
                    locationAmpDrafts[location.id] = nil
                    let rounded = Int(draft.rounded())
                    guard rounded != location.ampLimit else { return }
                    gate.send(.updateChargeLocationAmpLimit(id: location.id, amps: rounded))
                }
            )
            .tint(HisingenTheme.accent)
            // Probed with 0 A so the question is "does this vehicle support location amperage",
            // not "is the reading the vehicle last sent inside its own range".
            .disabled(gate.isDisabled(.updateChargeLocationAmpLimit(id: location.id, amps: 0)))
            .accessibilityLabel(L10n.text("Charging current at location"))
            if location.ampLimit > 0 {
                let press = LimitStepping.pressed(location.ampLimit, within: chargeBounds.amperageRange,
                                                  step: preferences.nowLimitStep)
                HStack {
                    Button {
                        gate.send(.updateChargeLocationAmpLimit(id: location.id, amps: press.value))
                    } label: {
                        Text(press.restarts
                             ? L10n.format("Lower to %@", Format.amps(press.value))
                             : L10n.format("Raise to %@", Format.amps(press.value)))
                            .monospacedDigit()
                    }
                    .buttonStyle(.hisSecondary)
                    .controlSize(.small)
                    .disabled(gate.isDisabled(.updateChargeLocationAmpLimit(id: location.id, amps: 0)))
                    Spacer()
                }
            }

            Toggle(
                isOn: Binding(
                    get: { optimisedDrafts[location.id] ?? location.optimisedChargingEnabled },
                    set: { newValue in
                        optimisedDrafts[location.id] = newValue
                        gate.send(.setChargeLocationOptimisedCharging(id: location.id, enabled: newValue))
                    }
                )
            ) {
                Text(L10n.text("Optimised charging")).hisType(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(gate.isDisabled(.setChargeLocationOptimisedCharging(
                id: location.id, enabled: location.optimisedChargingEnabled
            )))
            .onChange(of: location.optimisedChargingEnabled) { _, _ in
                // The provider has caught up, or disagreed and won. Either way the reading is
                // authoritative again, so stop shadowing it.
                optimisedDrafts[location.id] = nil
            }
            if let modeName = location.optimisedChargingModeName {
                Text(modeName)
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .transition(.opacity)
            }

            if !preferences.privacyRedactionEnabled, let lat = location.latitude, let lon = location.longitude {
                KVRow(L10n.text("Coordinates"), String(format: "%.4f, %.4f", locale: L10n.displayLocale, lat, lon))
                    .privacySensitive()
            }

            Button(role: .destructive) {
                locationPendingDelete = location
            } label: {
                Label(L10n.text("Delete Location"), systemImage: "trash")
                    .hisType(.caption, weight: .medium)
                    .foregroundStyle(HisingenTheme.semanticCritical)
            }
            .buttonStyle(.pressable)
            .disabled(gate.isDisabled(.deleteChargeLocation(id: location.id)))
        }
        .padding(8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 0))
        .hisAnimation(Motion.stateChange, value: location.optimisedChargingModeName)
    }
}
