import SwiftUI

/// Now: the first place in the panel (2026-11-16 redesign). It answers one question per glance,
/// "can I leave, and what do I need to do first?", in this order:
///
/// 1. One readiness line built only from reported signals.
/// 2. The car and its energy: the factory render, the battery figure, the range, the energy line.
/// 3. Three rows that each state one system and offer its one action.
///
/// Rows are typography on the panel separated by hairlines. Nothing here is a card or a tile, and
/// no figure appears that the car did not report.
@MainActor
struct NowInstrument: View {
    let state: VehicleState
    let imageCache: CarImageCache
    let commandGate: ControlsCommandGate

    @Environment(\.preferencesStore) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var condensed: Bool { HisingenTheme.layoutWidth < 600 }

    // MARK: Readings

    private var factoryImageData: Data? {
        state.identity.imageData
            ?? imageCache.image(for: state.identity.vin, angle: preferences.carRenderAngle.rawValue)
            ?? imageCache.image(for: state.identity.vin)
    }

    private var title: String {
        preferences.formattedVehicleTitle(
            vin: state.identity.vin,
            modelName: state.identity.modelName,
            modelYear: state.identity.modelYear,
            registrationNo: state.identity.registrationNo,
            fallbackBrand: state.model.brand
        )
    }

    private var batteryText: String {
        state.energy.batteryPercentage.map { String(format: "%.0f", locale: L10n.displayLocale, $0) } ?? "–"
    }

    private var rangeParts: Format.DistanceParts {
        state.primaryRangeKm.map { Format.distanceParts(km: $0, unit: preferences.distanceUnit) }
            ?? Format.DistanceParts(value: "–", unit: preferences.distanceUnit.suffix)
    }

    /// What the car is doing, then its doors: one line, each part only when reported. Range is
    /// left to the figure beside the car rather than said twice. Joined with a middle dot rather than built into a sentence, so sixteen
    /// languages read it without grammar the car never supplied.
    static func readinessParts(_ state: VehicleState, distanceUnit: DistanceUnit) -> [String] {
        var parts: [String] = []
        if let verdict = state.activeVerdict {
            parts.append(verdict)
        } else {
            parts.append(state.hasOldData() ? L10n.text("Asleep") : L10n.text("Parked"))
        }
        if let locked = state.exteriorStatus?.isLocked {
            parts.append(locked ? L10n.text("Locked") : L10n.text("Unlocked"))
        }
        return parts
    }

    /// The data age without the "asleep" the readiness line already said: when the car last
    /// reported, and when Hisingen last asked if that differs.
    private var ageLine: String {
        let updated = L10n.format("Updated %@", Format.relativeAge(since: state.dataTimestamp))
        guard state.hasOldData(), state.vehicleReportedAt != nil else { return updated }
        return L10n.format("%@ · Checked %@", updated, Format.relativeAge(since: state.fetchedAt))
    }

    private var attentionMessage: (text: String, critical: Bool)? {
        let summary = state.stateSummary
        switch summary.severity {
        case .critical: return (summary.message, true)
        case .warning: return (summary.message, false)
        default: return nil
        }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, condensed ? 10 : 14)

            energyBlock

            if state.powertrain.hasElectricRange {
                chargeLine
                    .padding(.top, 14)
            }

            VStack(spacing: 0) {
                doorsRow
                rule
                climateRow
                if state.powertrain.hasElectricRange {
                    rule
                    chargingRow
                }
            }
            .padding(.top, 18)
            .overlay(alignment: .top) { rule.padding(.top, 18) }
        }
        .padding(.horizontal, condensed ? 16 : 24)
        .padding(.top, condensed ? 14 : 20)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }

    private var rule: some View {
        Rectangle().fill(HisingenTheme.hairline).frame(height: 1)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Self.readinessParts(state, distanceUnit: preferences.distanceUnit).joined(separator: " · "))
                .hisType(size: condensed ? 18 : 21, relativeTo: .title2, weight: .semibold)
                .foregroundStyle(HisingenTheme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .contentTransition(reduceMotion ? .identity : .opacity)
                .hisAnimation(Motion.stateChange, value: state.activeVerdict)
            if let attention = attentionMessage {
                Label(attention.text, systemImage: attention.critical
                      ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .hisType(.label, weight: .semibold)
                    .foregroundStyle(attention.critical ? HisingenTheme.semanticCritical : HisingenTheme.semanticWarning)
            }
            HStack(spacing: 0) {
                Text(title)
                    .privacySensitive(preferences.privacyRedactionEnabled)
                Text(" · " + ageLine)
            }
            .hisType(.label)
            .foregroundStyle(HisingenTheme.inkMuted)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(state.freshnessDescription)
        }
    }

    // MARK: Energy

    private var energyBlock: some View {
        HStack(alignment: .center, spacing: condensed ? 10 : 18) {
            Group {
                if let factoryImageData {
                    VehiclePresentationView(
                        identity: VehiclePresentationIdentity(
                            vin: state.identity.vin,
                            angle: preferences.carRenderAngle.rawValue
                        ),
                        imageData: factoryImageData
                    )
                } else {
                    VehicleSideProfileDoorsView(
                        openings: state.exteriorStatus?.openings ?? [],
                        model: VehicleModel(modelName: state.identity.modelName, vin: state.identity.vin),
                        brand: state.model.brand
                    )
                }
            }
            .frame(maxWidth: .infinity, minHeight: condensed ? 130 : 170, maxHeight: condensed ? 150 : 196)
            .accessibilityLabel(L10n.format("%@ vehicle profile", title))

            VStack(alignment: .trailing, spacing: 2) {
                if state.powertrain.hasElectricRange {
                    figure(batteryText, unit: "%", size: condensed ? 50 : 64, label: L10n.text("Battery"))
                }
                figure(rangeParts.value, unit: rangeParts.unit, size: condensed ? 26 : 32,
                       label: L10n.text("Estimated Range"))
            }
            .fixedSize()
        }
    }

    /// A focal figure: light weight at display size, because the number is the instrument and
    /// heavy type would shout over the car. Tabular digits so it does not jitter as it rolls.
    private func figure(_ value: String, unit: String, size: CGFloat, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .hisType(size: size, relativeTo: .largeTitle, weight: .light)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(reduceMotion ? Motion.theme : Motion.telemetry, value: value)
            Text(unit)
                .hisType(size: max(13, size * 0.32), relativeTo: .title3, weight: .regular)
                .foregroundStyle(HisingenTheme.inkMuted)
        }
        .foregroundStyle(HisingenTheme.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value) \(unit)")
    }

    private var chargeLine: some View {
        let target = state.energy.targetPercentage.map(Double.init)
        return VStack(spacing: 6) {
            EnergyLine(level: state.energy.batteryPercentage, target: target, isCharging: state.isCharging)
            HStack {
                // Only while charging: otherwise the Charging row below already names the state.
                if state.isCharging, let verdict = state.activeVerdict {
                    Text(verdict).foregroundStyle(HisingenTheme.accent)
                }
                Spacer()
                if let target = state.energy.targetPercentage {
                    Text(L10n.format("Target %d%%", target))
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .monospacedDigit()
                }
            }
            .hisType(.label, weight: .medium)
        }
    }

    // MARK: Rows

    private var doorsRow: some View {
        let locked = state.exteriorStatus?.isLocked
        let command: RemoteCommand = locked == true ? .unlock : .lock
        return controlRow(
            symbol: locked == false ? "lock.open" : "lock",
            name: L10n.text("Locks"),
            value: locked.map { $0 ? L10n.text("Locked") : L10n.text("Unlocked") } ?? L10n.text("Unavailable"),
            valueIsWarning: locked == false,
            action: locked == true ? L10n.text("Unlock") : L10n.text("Lock"),
            command: command
        )
    }

    private var climateRow: some View {
        let command: RemoteCommand = state.isClimateActive
            ? .stopClimate
            : .startClimate(
                temperatureCelsius: Float(preferences.remoteClimateTemperature),
                frontLeftSeat: .off, frontRightSeat: .off,
                rearLeftSeat: .off, rearRightSeat: .off,
                steeringWheel: .off
            )
        return controlRow(
            symbol: "fan",
            name: L10n.text("Climate"),
            value: state.climateStatus?.activity.displayName ?? L10n.text("Climate unavailable"),
            valueIsActive: state.isClimateActive,
            action: state.isClimateActive ? L10n.text("Stop Climate") : L10n.text("Start Climate"),
            command: command
        )
    }

    private var chargingRow: some View {
        let overriding = state.energy.chargeNowActive == true
        // At its target with no override running, "Charge Now" beside "Complete" contradicts the
        // state it sits next to, so the row states and offers nothing.
        let hasAction = overriding || state.energy.chargingState != .complete
        return controlRow(
            symbol: "bolt",
            name: L10n.text("Charging"),
            value: state.energy.chargingState.displayName,
            valueIsActive: state.isCharging,
            action: hasAction ? (overriding ? L10n.text("Resume Schedule") : L10n.text("Charge Now")) : nil,
            command: overriding ? .stopChargingOverride : .startChargingOverride
        )
    }

    /// One system: its name, its reported state, and its one action as a real button. The action
    /// used to be 9 pt accent text under a tile, which read as a caption; a bordered button with
    /// a verb is what it is.
    private func controlRow(
        symbol: String,
        name: String,
        value: String,
        valueIsWarning: Bool = false,
        valueIsActive: Bool = false,
        action: String?,
        command: RemoteCommand
    ) -> some View {
        let availability = commandGate.availability(command)
        let sending = commandGate.isSending(command)
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .hisType(.body)
                .foregroundStyle(HisingenTheme.inkMuted)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(name)
                .hisType(.body)
                .foregroundStyle(HisingenTheme.inkMuted)
                .frame(minWidth: condensed ? 64 : 84, alignment: .leading)
            Text(value)
                .hisType(.body, weight: .semibold)
                .foregroundStyle(valueIsWarning ? HisingenTheme.semanticWarning
                                 : (valueIsActive ? HisingenTheme.accent : HisingenTheme.ink))
                .lineLimit(1)
                .contentTransition(reduceMotion ? .identity : .opacity)
                .hisAnimation(Motion.stateChange, value: value)
            Spacer(minLength: 8)
            if let action {
                Button {
                    commandGate.send(command)
                } label: {
                    HStack(spacing: 5) {
                        if sending {
                            ProgressView().controlSize(.mini)
                        }
                        Text(sending ? L10n.text("Sending…") : action)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 72)
                }
                .buttonStyle(RowActionButtonStyle())
                .disabled(!availability.isAvailable)
                .help(availability.shortReason ?? command.title(temperatureUnit: preferences.temperatureUnit))
                .accessibilityLabel(command.title(temperatureUnit: preferences.temperatureUnit))
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }
}

/// The row action: accent text on a 12 % accent wash, the one combination the palette's accent
/// guarantees 4.5:1 for in every theme and appearance. The system bordered style rendered a grey
/// fill under white text in dark appearance (2.1:1). Hover lifts the wash, press dims, disabled
/// drops to muted ink with no wash.
struct RowActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .hisType(.label, weight: .semibold)
            .foregroundStyle(isEnabled ? HisingenTheme.accent : HisingenTheme.inkMuted)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isEnabled
                          ? HisingenTheme.accent.opacity(hovering || configuration.isPressed ? 0.12 : 0.09)
                          : HisingenTheme.hairline)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
            .hisAnimation(Motion.interaction, value: hovering)
    }
}
