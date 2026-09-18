import SwiftUI

@MainActor
struct ChargingControlsCard: View {
    let state: VehicleState
    let gate: ControlsCommandGate
    let onShowSchedule: (ScheduleKind) -> Void

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
                CardHeader(symbol: "bolt.fill", title: L10n.text("Charging Controls"), color: HisingenTheme.semanticGood)
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

                if profile.permits(.chargingSchedule)
                    && (features.contains(.remoteSchedules) || features.contains(.remoteCharging)) {
                    Divider().opacity(HisingenTheme.dividerOpacity)
                    Button {
                        onShowSchedule(.globalCharging)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.clock")
                            Text(L10n.text("Manage Timers & Schedules…"))
                                .hisType(.label, weight: .medium)
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                }
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

    private var chargeTargetPresets: [Int] { chargeBounds.targetPresets() }

    private var chargeTargetControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("Target Limit"))
                    .hisType(.label, weight: .medium)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(displayedChargeTarget.map { Format.percent(Double($0)) } ?? L10n.text("Unavailable"))
                    .hisType(.subhead, weight: .bold, design: .rounded)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .hisTelemetryValue(displayedChargeTarget, reduceMotion: reduceMotion)
            }

            HStack(spacing: 6) {
                ForEach(chargeTargetPresets, id: \.self) { target in
                    let selected = chargeTarget == target
                    Button {
                        gate.send(.setChargeTarget(target))
                    } label: {
                        Text(target == chargeBounds.dailyTarget
                             ? L10n.format("Daily %@", Format.percent(Double(target)))
                             : Format.percent(Double(target)))
                            .hisType(.micro, weight: selected ? .bold : .medium)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity)
                            .background(
                                selected ? HisingenTheme.accent.opacity(0.12) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .foregroundStyle(selected ? HisingenTheme.accent : .secondary)
                            .animation(reduceMotion ? nil : Motion.selection, value: selected)
                    }
                    .buttonStyle(.pressable)
                    .disabled(gate.isDisabled(.setChargeTarget(target)))
                    .accessibilityLabel(L10n.format(
                        "Set charge target to %@",
                        Format.percent(Double(target))
                    ))
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }

            if let chargeTarget {
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
                .tint(HisingenTheme.semanticGood)
                .disabled(gate.isDisabled(.setChargeTarget(chargeTarget)))
                .accessibilityValue(Format.percent(Double(
                    chargeTargetDraft.map { Int($0.rounded()) } ?? chargeTarget
                )))
                .transition(.opacity)
                gate.sendingOverlay(.setChargeTarget(chargeTarget))
            } else {
                Text(L10n.text("The vehicle did not report its current target. Choose a preset to set a new value."))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if let queued = state.energy.diagnostics?.unappliedTargetPercentage(current: chargeTarget) {
                pendingSyncLine(Format.percent(Double(queued)))
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

    private var currentLimitControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.text("Current Limit"))
                    .hisType(.label, weight: .medium)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(displayedAmpLimit.map { Format.amps($0) } ?? L10n.text("Unavailable"))
                    .hisType(.subhead, weight: .bold, design: .rounded)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .hisTelemetryValue(displayedAmpLimit, reduceMotion: reduceMotion)
            }

            if let ampLimit {
                let chips = chargeBounds.amperagePresets().filter { $0 != ampLimit }
                if !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { preset in
                            Button {
                                gate.send(.setAmpLimit(preset))
                            } label: {
                                Text(Format.amps(preset))
                                    .hisType(.micro, weight: .semibold, design: .rounded)
                                    .monospacedDigit()
                                    .frame(minWidth: 34)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(gate.isDisabled(.setAmpLimit(preset)))
                            .accessibilityLabel(L10n.format(
                                "Set charging current to %@",
                                Format.amps(preset)
                            ))
                            .transition(.opacity)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 2)
                    // Keyed on the filtered collection so the chip for the now-current
                    // limit slides out instead of vanishing with the next read.
                    .hisAnimation(Motion.layout, value: chips)
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
                .tint(HisingenTheme.semanticWarning)
                .disabled(gate.isDisabled(.setAmpLimit(ampLimit)))
                .accessibilityValue(Format.amps(
                    ampLimitDraft.map { Int($0.rounded()) } ?? ampLimit
                ))
                .transition(.opacity)
            } else {
                Text(L10n.text("The vehicle did not report a configurable current limit."))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if let queued = state.energy.diagnostics?.unappliedLimitAmps(current: ampLimit) {
                pendingSyncLine(Format.amps(queued))
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
                    Pill(text: L10n.text("Charge Now"), color: HisingenTheme.semanticGood, symbol: "bolt.fill")
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
                    Spacer()
                }
            }
            HStack(spacing: 8) {
                Button {
                    gate.send(.startChargingOverride)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                        Text(L10n.text("Charge Now")).hisType(.label, weight: .medium)
                        gate.sendingOverlay(.startChargingOverride)
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .tint(HisingenTheme.semanticGood)
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
                .buttonStyle(.bordered)
                .disabled(gate.isDisabled(.stopChargingOverride))
            }
        }
        .hisAnimation(Motion.stateChange, value: state.energy.chargeNowActive)
    }

    @ViewBuilder
    private var chargeLocationsSection: some View {
        if profile.permits(.chargeLocations) && features.contains(.remoteCharging) {
            let locations = state.energy.locations.filter { $0.isSavedLocation || !$0.alias.isEmpty }
            VStack(alignment: .leading, spacing: 10) {
                Divider().opacity(HisingenTheme.dividerOpacity)
                HStack {
                    Text(L10n.text("Saved Charge Locations"))
                        .hisType(.label, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showAddLocation = true
                    } label: {
                        Label(L10n.text("Add here"), systemImage: "plus.circle")
                            .hisType(.caption, weight: .medium)
                            .foregroundStyle(HisingenTheme.accent)
                    }
                    .buttonStyle(.pressable)
                    // Asks the gate, not the raw busy flag, so the card and this control always
                    // agree on why it is inert. The placeholder values are the ones the sheet
                    // starts from: availability reads the command's shape, not the user's numbers.
                    .disabled(gate.isDisabled(.createChargeLocationAtCar(
                        alias: "", ampLimit: 0, minimumSoc: 0, optimisedCharging: false
                    )))
                    .help(L10n.text("Saves the vehicle's current position as a charge location."))
                }

                if locations.isEmpty {
                    Text(L10n.text("No saved locations. Use “Add here” while parked where you charge."))
                        .hisType(.micro)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }

                ForEach(locations) { location in
                    chargeLocationRow(location)
                        .transition(.opacity)
                }
            }
            // Keyed on the collection itself so saved/removed locations reflow
            // instead of inserting and deleting instantly.
            .hisAnimation(Motion.cardChange, value: locations)
        }
    }

    private func chargeLocationRow(_ location: ChargeLocationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "mappin.circle.fill")
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.accent)
                Text(location.alias.isEmpty ? L10n.text("Unnamed location") : location.alias)
                    .hisType(.label, weight: .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                if state.energy.isAtChargeLocation == true && (state.energy.currentChargeLocationName == location.alias || state.energy.currentChargeLocationName == location.id) {
                    Pill(text: L10n.text("Here"), color: HisingenTheme.semanticGood, symbol: "bolt.fill")
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
                }
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
            .tint(HisingenTheme.semanticGood)
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
                        .foregroundStyle(.tertiary)
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
                        .foregroundStyle(.tertiary)
                }
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
            .tint(HisingenTheme.semanticWarning)
            // Probed with 0 A so the question is "does this vehicle support location amperage",
            // not "is the reading the vehicle last sent inside its own range".
            .disabled(gate.isDisabled(.updateChargeLocationAmpLimit(id: location.id, amps: 0)))
            .accessibilityLabel(L10n.text("Charging current at location"))

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
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                    .transition(.opacity)
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
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .hisAnimation(Motion.stateChange, value: location.optimisedChargingModeName)
    }
}
