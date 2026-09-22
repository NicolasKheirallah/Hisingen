import SwiftUI

private enum VehicleQuickControlKind {
    case lock
    case climate
    case charging
}

/// One semantic glyph with two motion layers: a short activity rotation while a command is in
/// flight, and quiet ambient motion only while the represented system is genuinely active.
/// Press feedback stays in `PressableButtonStyle`, so acknowledgement begins on pointer-down.
private struct VehicleQuickControlGlyph: View {
    let kind: VehicleQuickControlKind
    let symbol: String
    let isActive: Bool
    let isSending: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ambientMotionAllowed) private var ambientMotionAllowed
    @State private var sendRotation: Double = 0
    @State private var chargePulse = false

    private var animatesSending: Bool { isSending && !reduceMotion && ambientMotionAllowed }
    private var animatesCharging: Bool {
        kind == .charging && isActive && !reduceMotion && ambientMotionAllowed
    }

    var body: some View {
        ZStack {
            if isSending {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .rotationEffect(.degrees(sendRotation))
                    .transition(.opacity)
            } else if kind == .climate {
                SpinningFanView(
                    isSpinning: isActive,
                    size: 17,
                    color: isActive ? HisingenTheme.semanticActive : HisingenTheme.ink
                )
                .transition(.opacity)
            } else {
                Image(systemName: symbol)
                    .opacity(animatesCharging && chargePulse ? 0.58 : 1)
                    .scaleEffect(animatesCharging && chargePulse ? 1.06 : 1)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .transition(.opacity)
            }
        }
        .hisSymbolSize(17, weight: .semibold)
        .frame(width: 20, height: 20)
        .hisAnimation(Motion.stateChange, value: isSending)
        .task(id: animatesSending) {
            sendRotation = 0
            guard animatesSending else { return }
            while !Task.isCancelled {
                withAnimation(.linear(duration: Motion.progressDuration)) {
                    sendRotation += 360
                }
                try? await Task.sleep(for: .seconds(Motion.progressDuration))
            }
        }
        .task(id: animatesCharging) {
            chargePulse = false
            guard animatesCharging else { return }
            withAnimation(Motion.livePulse) { chargePulse = true }
        }
        .accessibilityHidden(true)
    }
}

/// The glanceable instrument from the award concept, bound to the live vehicle snapshot.
/// It leads the wide production layout; the detailed cards remain below for deeper inspection.
@MainActor
struct AwardVehicleInstrument: View {
    let state: VehicleState
    let imageCache: CarImageCache
    let commandGate: ControlsCommandGate

    @Environment(\.preferencesStore) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var condensed: Bool { HisingenTheme.layoutWidth < 700 }

    private var factoryImageData: Data? {
        state.identity.imageData
            ?? imageCache.image(for: state.identity.vin, angle: preferences.carRenderAngle.rawValue)
            ?? imageCache.image(for: state.identity.vin)
    }

    private var model: VehicleModel {
        VehicleModel(modelName: state.identity.modelName, vin: state.identity.vin)
    }

    private var batteryValue: String {
        state.energy.batteryPercentage.map { String(format: "%.0f", locale: L10n.displayLocale, $0) } ?? "–"
    }

    private var rangeParts: Format.DistanceParts {
        state.primaryRangeKm.map {
            Format.distanceParts(km: $0, unit: preferences.distanceUnit)
        } ?? Format.DistanceParts(value: "–", unit: preferences.distanceUnit.suffix)
    }

    private var batteryValueColor: Color {
        switch state.batteryLevel {
        case .critical: return HisingenTheme.semanticCritical
        case .low: return HisingenTheme.semanticWarning
        case .charging: return HisingenTheme.accent
        case .chargingComplete: return HisingenTheme.semanticGood
        case .normal: return HisingenTheme.ink
        }
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

    private var lockCommand: RemoteCommand {
        state.exteriorStatus?.isLocked == true ? .unlock : .lock
    }

    private var climateCommand: RemoteCommand {
        if state.isClimateActive { return .stopClimate }
        return .startClimate(
            temperatureCelsius: Float(preferences.remoteClimateTemperature),
            frontLeftSeat: .off,
            frontRightSeat: .off,
            rearLeftSeat: .off,
            rearRightSeat: .off,
            steeringWheel: .off
        )
    }

    private var chargingCommand: RemoteCommand {
        state.energy.chargeNowActive == true ? .stopChargingOverride : .startChargingOverride
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .hisType(size: condensed ? 24 : 28, weight: .bold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    // The verdict answers "what is the car doing" in one sentence; the safety
                    // summary lives in the chip so the two never repeat each other. With
                    // nothing actively happening, the data age is the honest subline.
                    if let verdict = state.activeVerdict {
                        Text(verdict)
                            .hisType(.body, weight: .medium)
                            .foregroundStyle(HisingenTheme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        Text(state.freshnessDescription)
                            .hisType(.label, weight: .medium)
                            .foregroundStyle(HisingenTheme.inkMuted)
                    }
                }
                Spacer()
                StateSummaryChip(
                    message: state.stateSummary.message,
                    severity: state.stateSummary.severity,
                    prominence: .quiet
                )
                .fixedSize()
                .padding(.top, 2)
            }
            .padding(.bottom, 8)

            HStack(spacing: condensed ? 12 : 20) {
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
                            model: model,
                            brand: state.model.brand
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: condensed ? 155 : 190,
                       maxHeight: condensed ? 175 : 210)
                .accessibilityLabel(L10n.format("%@ vehicle profile", title))

                VStack(alignment: .trailing, spacing: condensed ? 14 : 18) {
                    instrumentReading(
                        value: batteryValue,
                        unit: "%",
                        label: L10n.text("Battery"),
                        isPrimary: true,
                        color: batteryValueColor,
                        alignment: .trailing
                    )
                    instrumentReading(
                        value: rangeParts.value,
                        unit: rangeParts.unit,
                        label: L10n.text("Estimated Range"),
                        isPrimary: false,
                        color: HisingenTheme.ink,
                        alignment: .trailing
                    )
                }
            }
            .padding(.vertical, 2)

            if state.powertrain.hasElectricRange {
                chargeRail
            }

            HStack(spacing: 0) {
                ledgerControl(
                    kind: .lock,
                    symbol: state.exteriorStatus?.isLocked == false ? "lock.open.fill" : "lock.fill",
                    value: state.exteriorStatus?.isLocked == false ? L10n.text("Unlocked") : L10n.text("Locked"),
                    action: state.exteriorStatus?.isLocked == true ? L10n.text("Unlock") : L10n.text("Lock"),
                    command: lockCommand
                )
                ledgerControl(
                    kind: .climate,
                    symbol: "fan.fill",
                    value: state.climateStatus?.activity.displayName ?? L10n.text("Climate unavailable"),
                    action: state.isClimateActive ? L10n.text("Stop Climate") : L10n.text("Start Climate"),
                    command: climateCommand
                )
                ledgerControl(
                    kind: .charging,
                    symbol: "bolt.fill",
                    value: state.energy.chargingState.displayName,
                    action: state.energy.chargeNowActive == true
                        ? L10n.text("Resume Schedule")
                        : L10n.text("Charge Now"),
                    command: chargingCommand
                )
                ledgerItem(symbol: "clock.arrow.circlepath", value: state.freshnessDescription, drawsDivider: false)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, condensed ? 16 : 24)
        .padding(.vertical, condensed ? 14 : 20)
        .accessibilityElement(children: .contain)
    }

    private func instrumentReading(
        value: String,
        unit: String,
        label: String,
        isPrimary: Bool,
        color: Color,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(label)
                .hisType(.label, weight: .semibold)
                .foregroundStyle(HisingenTheme.inkMuted)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .hisType(isPrimary ? .displayLarge : .display, weight: .bold)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                    .monospacedDigit()
                    .animation(reduceMotion ? Motion.theme : Motion.telemetry, value: value)
                Text(unit)
                    .hisType(isPrimary ? .displaySmall : .subhead, weight: .semibold)
                    .foregroundStyle(color.opacity(0.82))
            }

        }
        .frame(
            width: condensed ? 116 : 136,
            alignment: alignment == .leading ? .leading : .trailing
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value) \(unit)")
    }

    private var chargeRail: some View {
        VStack(spacing: 9) {
            HStack {
                Label(state.energy.chargingState.displayName, systemImage: "bolt.fill")
                    .hisType(.body, weight: .bold)
                    .foregroundStyle(state.isCharging ? HisingenTheme.accent : HisingenTheme.ink)
                Spacer()
                if let target = state.energy.targetPercentage {
                    Text(L10n.format("Target %d%%", target))
                        .hisType(.label, weight: .semibold)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(HisingenTheme.accent)
                        .frame(width: proxy.size.width * CGFloat(min(max(state.energy.batteryPercentage ?? 0, 0), 100) / 100))
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 18)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func ledgerItem(symbol: String, value: String, drawsDivider: Bool = true) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .hisSymbolSize(17, weight: .semibold)
                Text(value)
                    .hisType(.label, weight: .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            if drawsDivider { Divider().frame(height: 48) }
        }
        .frame(maxWidth: .infinity)
    }

    private func ledgerControl(
        kind: VehicleQuickControlKind,
        symbol: String,
        value: String,
        action: String,
        command: RemoteCommand
    ) -> some View {
        let availability = commandGate.availability(command)
        let isSending = isQuickControlSending(kind)
        return HStack(spacing: 12) {
            Button {
                commandGate.send(command)
            } label: {
                VStack(spacing: 5) {
                    VehicleQuickControlGlyph(
                        kind: kind,
                        symbol: symbol,
                        isActive: quickControlIsActive(kind),
                        isSending: isSending
                    )
                    Text(value)
                        .hisType(.label, weight: .semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .contentTransition(reduceMotion ? .identity : .opacity)
                    Text(isSending ? L10n.text("Sending…") : action)
                        .hisType(.micro, weight: .semibold)
                        .foregroundStyle(availability.isAvailable ? HisingenTheme.accent : HisingenTheme.inkMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .contentTransition(reduceMotion ? .identity : .opacity)
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .disabled(!availability.isAvailable)
            .help(availability.shortReason ?? command.title(temperatureUnit: preferences.temperatureUnit))
            .accessibilityLabel(command.title(temperatureUnit: preferences.temperatureUnit))
            .accessibilityValue(value)
            .hisAnimation(Motion.stateChange, value: value)
            .hisAnimation(Motion.interaction, value: isSending)

            Divider().frame(height: 54)
        }
        .frame(maxWidth: .infinity)
        .opacity(availability.isAvailable ? 1 : 0.6)
    }

    private func quickControlIsActive(_ kind: VehicleQuickControlKind) -> Bool {
        switch kind {
        case .lock: return state.exteriorStatus?.isLocked == true
        case .climate: return state.isClimateActive
        case .charging: return state.isCharging
        }
    }

    private func isQuickControlSending(_ kind: VehicleQuickControlKind) -> Bool {
        guard commandGate.remoteCommandInProgress, let identifier = commandGate.inFlightCommandID else {
            return false
        }
        switch kind {
        case .lock: return identifier == RemoteCommand.lock.identifier || identifier == RemoteCommand.unlock.identifier
        case .climate:
            return identifier == "start-climate" || identifier == RemoteCommand.stopClimate.identifier
        case .charging:
            return identifier == RemoteCommand.startChargingOverride.identifier
                || identifier == RemoteCommand.stopChargingOverride.identifier
        }
    }
}
