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
    @State private var showAddLocation = false
    @State private var renamingLocation: ChargeLocationSnapshot?
    @State private var renameDraft: String = ""
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

    var body: some View {
        let chargingCommands = [RemoteCommand.setChargeTarget(80), .setAmpLimit(16), .startChargingOverride]
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "bolt.fill", title: L10n.text("Charging Controls"), color: .green)
                gate.dimReason(gate.cardAvailability(chargingCommands))

                if profile.permits(.chargeTarget) && features.contains(.remoteCharging) {
                    chargeTargetControls
                }
                if profile.permits(.chargingCurrentLimit) && features.contains(.remoteCharging) {
                    currentLimitControls
                }
                if profile.permits(.chargingScheduleOverride)
                    && (features.contains(.remoteCharging) || features.contains(.remoteSchedules)) {
                    Divider().opacity(0.5)
                    chargeOverrideButtons
                }

                chargeLocationsSection

                if profile.permits(.chargingSchedule)
                    && (features.contains(.remoteSchedules) || features.contains(.remoteCharging)) {
                    Divider().opacity(0.5)
                    Button {
                        onShowSchedule(.globalCharging)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.clock")
                            Text(L10n.text("Manage Timers & Schedules…"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .opacity(gate.cardOpacity(chargingCommands))
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
            Button(L10n.text("Save")) {
                if let location = renamingLocation {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed != location.alias {
                        gate.send(.updateChargeLocationAlias(id: location.id, alias: trimmed))
                    }
                }
                renamingLocation = nil
            }
            Button(L10n.text("Cancel"), role: .cancel) { renamingLocation = nil }
        }
        .onChange(of: chargeTarget) { _, _ in chargeTargetDraft = nil }
        .onChange(of: ampLimit) { _, _ in ampLimitDraft = nil }
    }

    private var chargeTargetPresets: [Int] { chargeBounds.targetPresets() }

    private var chargeTargetControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("Target Limit"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(chargeTarget.map { Format.percent(Double($0)) } ?? L10n.text("Unavailable"))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .hisTelemetryValue(chargeTarget, reduceMotion: reduceMotion)
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
                            .font(.system(size: 9.5, weight: selected ? .bold : .medium))
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity)
                            .background(
                                selected ? HisingenTheme.accent.opacity(0.18) : Color.primary.opacity(0.05),
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
                .tint(.green)
                .disabled(gate.isDisabled(.setChargeTarget(chargeTarget)))
                .accessibilityValue(Format.percent(Double(
                    chargeTargetDraft.map { Int($0.rounded()) } ?? chargeTarget
                )))
                gate.sendingOverlay(.setChargeTarget(chargeTarget))
            } else {
                Text(L10n.text("The vehicle did not report its current target. Choose a preset to set a new value."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var currentLimitControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.text("Current Limit"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ampLimit.map { Format.amps($0) } ?? L10n.text("Unavailable"))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .hisTelemetryValue(ampLimit, reduceMotion: reduceMotion)
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
                                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                    .frame(minWidth: 34)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(gate.isDisabled(.setAmpLimit(preset)))
                            .accessibilityLabel(L10n.format(
                                "Set charging current to %@",
                                Format.amps(preset)
                            ))
                        }
                        Spacer()
                    }
                    .padding(.bottom, 2)
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
                .tint(.orange)
                .disabled(gate.isDisabled(.setAmpLimit(ampLimit)))
                .accessibilityValue(Format.amps(
                    ampLimitDraft.map { Int($0.rounded()) } ?? ampLimit
                ))
            } else {
                Text(L10n.text("The vehicle did not report a configurable current limit."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chargeOverrideButtons: some View {
        HStack(spacing: 8) {
            Button {
                gate.send(.startChargingOverride)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                    Text(L10n.text("Charge Now")).font(.system(size: 11, weight: .medium))
                    gate.sendingOverlay(.startChargingOverride)
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(gate.isDisabled(.startChargingOverride))

            Button {
                gate.send(.stopChargingOverride)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(L10n.text("Resume Schedule")).font(.system(size: 11, weight: .medium))
                    gate.sendingOverlay(.stopChargingOverride)
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.bordered)
            .disabled(gate.isDisabled(.stopChargingOverride))
        }
    }

    @ViewBuilder
    private var chargeLocationsSection: some View {
        if profile.permits(.chargeLocations) && features.contains(.remoteCharging) {
            let locations = state.energy.locations.filter { $0.isSavedLocation || !$0.alias.isEmpty }
            VStack(alignment: .leading, spacing: 10) {
                Divider().opacity(0.5)
                HStack {
                    Text(L10n.text("Saved Charge Locations"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showAddLocation = true
                    } label: {
                        Label(L10n.text("Add here"), systemImage: "plus.circle")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(gate.remoteCommandInProgress)
                    .help(L10n.text("Saves the vehicle's current position as a charge location."))
                }

                if locations.isEmpty {
                    Text(L10n.text("No saved locations. Use “Add here” while parked where you charge."))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                ForEach(locations) { location in
                    chargeLocationRow(location)
                }
            }
        }
    }

    private func chargeLocationRow(_ location: ChargeLocationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(HisingenTheme.accent)
                Text(location.alias.isEmpty ? L10n.text("Unnamed location") : location.alias)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    renameDraft = location.alias
                    renamingLocation = location
                } label: {
                    Image(systemName: "pencil").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .disabled(gate.remoteCommandInProgress)
                .help(L10n.text("Rename"))
                .accessibilityLabel(L10n.text("Rename location"))
            }

            HStack {
                Text(L10n.text("Minimum charge"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(Double(
                    locationSocDrafts[location.id].map { Int($0.rounded()) } ?? location.minimumSoc
                )))
                .font(.system(size: 11, weight: .bold, design: .rounded))
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
            .tint(.green)
            .disabled(gate.remoteCommandInProgress)
            .accessibilityLabel(L10n.text("Minimum charge at location"))

            let locationAmpDraft = locationAmpDrafts[location.id]
            HStack {
                Text(L10n.text("Current limit"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                if let draftAmps = locationAmpDraft.map({ Int($0.rounded()) }) {
                    Text(Format.amps(draftAmps))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                } else if location.ampLimit > 0 {
                    Text(Format.amps(location.ampLimit))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                } else {
                    Text(L10n.text("Vehicle default"))
                        .font(.system(size: 10))
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
            .tint(.orange)
            .disabled(gate.remoteCommandInProgress)
            .accessibilityLabel(L10n.text("Charging current at location"))

            Toggle(
                isOn: Binding(
                    get: { location.optimisedChargingEnabled },
                    set: { gate.send(.setChargeLocationOptimisedCharging(id: location.id, enabled: $0)) }
                )
            ) {
                Text(L10n.text("Optimised charging")).font(.system(size: 10.5))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(gate.remoteCommandInProgress)
            if let modeName = location.optimisedChargingModeName {
                Text(modeName)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }

            Button(role: .destructive) {
                gate.send(.deleteChargeLocation(id: location.id))
            } label: {
                Label(L10n.text("Delete Location"), systemImage: "trash")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(gate.remoteCommandInProgress)
        }
        .padding(8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }
}
