import SwiftUI

@MainActor
struct ClimateControlCard: View {
    let state: VehicleState
    let gate: ControlsCommandGate
    let onShowSchedule: (ScheduleKind) -> Void

    @State private var targetTemperature: Double = 21
    @State private var driverSeat: HeatingLevel = .unspecified
    @State private var passengerSeat: HeatingLevel = .unspecified
    @State private var rearLeftSeat: HeatingLevel = .unspecified
    @State private var rearRightSeat: HeatingLevel = .unspecified
    @State private var steeringHeating: HeatingLevel = .unspecified
    @State private var showRearSeats = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let probe = RemoteCommand.startClimate(
        temperatureCelsius: 0,
        frontLeftSeat: .unspecified,
        frontRightSeat: .unspecified,
        rearLeftSeat: .unspecified,
        rearRightSeat: .unspecified,
        steeringWheel: .unspecified
    )

    private var preferences: PreferencesStore { gate.preferences }
    private var profile: VehicleCapabilityProfile { state.capabilityProfile }
    private var features: Set<AppFeature> { gate.features }

    private var climateActive: Bool { state.isClimateActive }

    var body: some View {
        let climateCommands = [Self.probe, RemoteCommand.startPreCleaning]
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    HStack(spacing: 7) {
                        SpinningFanView(
                            isSpinning: climateActive && !reduceMotion,
                            size: 14,
                            color: climateActive ? HisingenTheme.semanticWarning : HisingenTheme.inkMuted
                        )
                        Text(L10n.text("Climate & Conditioning"))
                            .hisType(.body, weight: .bold)
                            .foregroundStyle(HisingenTheme.ink)
                    }
                    Spacer()
                    if climateActive {
                        Pill(
                            text: state.climateStatus?.activity.displayName ?? L10n.text("Active"),
                            color: HisingenTheme.semanticWarning,
                            symbol: "fan.fill"
                        )
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .hisAnimation(Motion.entrance, value: climateActive)
                .hisAnimation(Motion.stateChange, value: state.climateStatus?.activity)

                gate.dimReason(gate.liveAvailability(climateCommands))

                if features.contains(.remoteClimate) {
                    if profile.hasSelectableClimateTemperature {
                        temperatureControls
                    } else {
                        climateAutomaticInfo
                            .hisAnimation(Motion.stateChange, value: climateActive)
                            .hisAnimation(Motion.stateChange, value: state.climateStatus?.timeRemainingMinutes)
                    }

                    if profile.hasSelectableSeatHeating || profile.hasSelectableSteeringWheelHeating {
                        seatAndSteeringControls
                    }

                    Divider().opacity(HisingenTheme.dividerOpacity)
                    climateStartStopButtons

                    if features.contains(.remoteSchedules) && profile.permits(.climateTimers) {
                        Button {
                            onShowSchedule(.climate)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "calendar.badge.clock")
                                Text(L10n.text("Schedule departure preconditioning…"))
                                    .hisType(.caption, weight: .medium)
                            }
                            .frame(maxWidth: .infinity, minHeight: 26)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if profile.permits(.preCleaning) && features.contains(.remotePreCleaning) {
                    Button {
                        let isCleaning = state.airQuality?.cleaningState == .on
                        gate.send(isCleaning ? .stopPreCleaning : .startPreCleaning)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles").foregroundStyle(.secondary)
                            Text(L10n.text(state.airQuality?.cleaningState == .on
                                ? "Stop Air Cleaning" : "Clean Cabin Air (PM2.5 Pre-Clean)"))
                                .hisType(.label, weight: .medium)
                            gate.sendingOverlay(.startPreCleaning)
                        }
                        .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(gate.isDisabled(.startPreCleaning))
                }
            }
        }
        .opacity(gate.liveOpacity(climateCommands))
        .hisAnimation(Motion.stateChange, value: gate.liveAvailability(climateCommands))
        .onAppear {
            targetTemperature = min(
                climateTemperatureRange.upperBound,
                max(climateTemperatureRange.lowerBound, preferences.remoteClimateTemperature)
            )
            driverSeat = preferences.remoteDriverSeatHeating
            passengerSeat = preferences.remoteFrontRightSeatHeating
            rearLeftSeat = preferences.remoteRearLeftSeatHeating
            rearRightSeat = preferences.remoteRearRightSeatHeating
            steeringHeating = preferences.remoteSteeringWheelHeating
            showRearSeats = rearLeftSeat != .unspecified || rearRightSeat != .unspecified
        }
        .onChange(of: climateTemperatureRange) { _, bounds in
            targetTemperature = min(bounds.upperBound, max(bounds.lowerBound, targetTemperature))
        }
    }

    private var maxHeatCommand: RemoteCommand {
        .startClimate(
            temperatureCelsius: 30,
            frontLeftSeat: profile.hasSelectableSeatHeating ? .level3 : .unspecified,
            frontRightSeat: profile.hasSelectableSeatHeating ? .level3 : .unspecified,
            rearLeftSeat: profile.hasSelectableSeatHeating ? .level3 : .unspecified,
            rearRightSeat: profile.hasSelectableSeatHeating ? .level3 : .unspecified,
            steeringWheel: profile.hasSelectableSteeringWheelHeating ? .level3 : .unspecified
        )
    }

    private func adjustTemperature(byDisplayUnits delta: Double) {
        let unit = preferences.temperatureUnit
        let currentDisplay: Double
        switch unit {
        case .celsius: currentDisplay = targetTemperature
        case .fahrenheit: currentDisplay = targetTemperature * 9 / 5 + 32
        }
        let nextDisplay = currentDisplay + delta
        let nextCelsius: Double
        switch unit {
        case .celsius: nextCelsius = nextDisplay
        case .fahrenheit: nextCelsius = (nextDisplay - 32) * 5 / 9
        }
        let bounds = climateTemperatureRange
        let clamped = min(bounds.upperBound, max(bounds.lowerBound, (nextCelsius * 2).rounded() / 2))
        targetTemperature = clamped
        preferences.remoteClimateTemperature = clamped
    }

    private var temperatureStep: Double {
        preferences.temperatureUnit == .fahrenheit ? 1 : 0.5
    }

    private var temperatureControls: some View {
        VStack(spacing: 10) {
            if let interior = state.climateStatus?.interiorTemperatureCelsius {
                HStack(spacing: 6) {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(HisingenTheme.accent)
                        .hisType(.caption)
                    Text(L10n.text("Current Cabin:"))
                        .hisType(.caption, weight: .medium)
                        .foregroundStyle(.secondary)
                    Text(Format.temperature(celsius: interior, unit: preferences.temperatureUnit))
                        .hisType(.caption, weight: .bold)
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.temperatureColor(celsius: interior))
                    if let exterior = state.weather?.temperatureCelsius {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(L10n.text("Outside:"))
                            .hisType(.caption, weight: .medium)
                            .foregroundStyle(.secondary)
                        Text(Format.temperature(celsius: exterior, unit: preferences.temperatureUnit))
                            .hisType(.caption, weight: .bold)
                            .monospacedDigit()
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(HisingenTheme.chipFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            HStack {
                Button {
                    gate.send(maxHeatCommand)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "windshield.front.heat")
                        Text(L10n.text("Max Heat")).hisType(.micro, weight: .semibold)
                        gate.sendingOverlay(maxHeatCommand)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(HisingenTheme.semanticWarning)
                .disabled(gate.isDisabled(maxHeatCommand))
                .help(L10n.text("Sends 30 °C with every heater at maximum. Does not change your saved settings."))
                Spacer()
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("Preconditioning Command Setpoint"))
                        .hisType(.label, weight: .medium)
                        .foregroundStyle(.secondary)
                    Text(L10n.text("Saved command setting; not live cabin telemetry"))
                        .hisType(.micro)
                        .foregroundStyle(.tertiary)
                    if let remaining = state.climateStatus?.timeRemainingMinutes, climateActive {
                        Text(L10n.format("%d min remaining", remaining))
                            .hisType(.caption, weight: .medium)
                            .foregroundStyle(HisingenTheme.polestarAmber)
                            .transition(.opacity)
                    }
                }
                .hisAnimation(Motion.stateChange, value: state.climateStatus?.timeRemainingMinutes)
                .hisAnimation(Motion.entrance, value: climateActive)
                Spacer()
                Text(Format.temperature(celsius: targetTemperature, unit: preferences.temperatureUnit))
                    .font(.system(size: 22, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(HisingenTheme.temperatureColor(celsius: targetTemperature))
                    .accessibilityLabel(L10n.text("Target temperature"))
                    .accessibilityValue(Format.temperature(celsius: targetTemperature, unit: preferences.temperatureUnit))
            }

            HStack(spacing: 8) {
                Button {
                    adjustTemperature(byDisplayUnits: -temperatureStep)
                } label: {
                    Image(systemName: "minus")
                        .hisType(.body, weight: .bold)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(targetTemperature <= climateTemperatureRange.lowerBound)
                // It hard-stopped at the vehicle's limit with nothing saying why, so the control
                // read as broken at exactly the moment the reader was asking what the range was.
                .help(L10n.format("This vehicle accepts %@ to %@.",
                                  Format.temperature(celsius: climateTemperatureRange.lowerBound, unit: preferences.temperatureUnit),
                                  Format.temperature(celsius: climateTemperatureRange.upperBound, unit: preferences.temperatureUnit)))
                .accessibilityLabel(L10n.text("Decrease target temperature"))

                HStack(spacing: 4) {
                    ForEach([19, 20, 21, 22, 23].filter { climateTemperatureRange.contains(Double($0)) }, id: \.self) { temp in
                        let isSelected = abs(targetTemperature - Double(temp)) < 0.25
                        Button {
                            targetTemperature = Double(temp)
                            preferences.remoteClimateTemperature = Double(temp)
                        } label: {
                            Text(Format.temperature(celsius: Double(temp), unit: preferences.temperatureUnit, decimals: 0))
                                .hisType(.label, weight: isSelected ? .bold : .medium)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity)
                                .background(
                                    isSelected ? HisingenTheme.semanticWarning.opacity(0.18) : Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .foregroundStyle(isSelected ? HisingenTheme.semanticWarning : .secondary)
                                .animation(reduceMotion ? nil : Motion.selection, value: isSelected)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel(L10n.format(
                            "Set target to %@",
                            Format.temperature(celsius: Double(temp), unit: preferences.temperatureUnit, decimals: 0)
                        ))
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    }
                }

                Button {
                    adjustTemperature(byDisplayUnits: temperatureStep)
                } label: {
                    Image(systemName: "plus")
                        .hisType(.body, weight: .bold)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(targetTemperature >= climateTemperatureRange.upperBound)
                .accessibilityLabel(L10n.text("Increase target temperature"))
            }
        }
    }

    @ViewBuilder
    private var climateAutomaticInfo: some View {
        if climateActive {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Cabin Preconditioning Running"))
                        .hisType(.body, weight: .semibold)
                        .foregroundStyle(HisingenTheme.ink)
                    if let remaining = state.climateStatus?.timeRemainingMinutes {
                        Text(L10n.format("%d min remaining", remaining))
                            .hisType(.caption, weight: .medium)
                            .foregroundStyle(HisingenTheme.semanticWarning)
                    } else {
                        Text(L10n.text("Preconditions vehicle using in-car comfort settings."))
                            .hisType(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let interior = state.climateStatus?.interiorTemperatureCelsius {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(L10n.text("Interior")).hisType(.micro).foregroundStyle(.secondary)
                        Text(Format.temperature(celsius: interior, unit: preferences.temperatureUnit))
                            .hisType(.title, weight: .bold)
                            .monospacedDigit()
                            .foregroundStyle(HisingenTheme.temperatureColor(celsius: interior))
                    }
                }
            }
            .padding(9)
            .background(HisingenTheme.semanticWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
        } else {
            HStack {
                Text(L10n.text("Preconditions the cabin to comfortable temperature using in-car climate settings."))
                    .hisType(.label)
                    .foregroundStyle(.secondary)
                Spacer()
                if let interior = state.climateStatus?.interiorTemperatureCelsius {
                    Text(Format.temperature(celsius: interior, unit: preferences.temperatureUnit))
                        .hisType(.body, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .transition(.opacity)
        }
    }

    private var seatAndSteeringControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if profile.hasSelectableSeatHeating
                    && state.otaCapabilities?.controlSettings?.frontSeatSettings != false {
                    HeatingLevelControl(
                        title: L10n.text("Driver"), symbol: "carseat.left.fill", level: $driverSeat
                    ) {
                        preferences.remoteDriverSeatHeating = $0
                    }
                    .disabled(gate.isDisabled(Self.probe))

                    HeatingLevelControl(
                        title: L10n.text("Passenger"), symbol: "carseat.right.fill", level: $passengerSeat
                    ) {
                        preferences.remoteFrontRightSeatHeating = $0
                    }
                    .disabled(gate.isDisabled(Self.probe))
                }

                if profile.hasSelectableSteeringWheelHeating
                    && state.otaCapabilities?.controlSettings?.steeringWheelSettings != false {
                    HeatingLevelControl(
                        title: L10n.text("Steering Wheel"), symbol: "steeringwheel",
                        level: $steeringHeating
                    ) {
                        preferences.remoteSteeringWheelHeating = $0
                    }
                    .disabled(gate.isDisabled(Self.probe))
                }
            }

            if profile.hasSelectableSeatHeating
                && state.otaCapabilities?.controlSettings?.rearSeatSettings != false {
                if showRearSeats {
                    HStack(spacing: 8) {
                        HeatingLevelControl(
                            title: L10n.text("Rear left"), symbol: "carseat.left.fill",
                            level: $rearLeftSeat
                        ) {
                            preferences.remoteRearLeftSeatHeating = $0
                        }
                        .disabled(gate.isDisabled(Self.probe))
                        HeatingLevelControl(
                            title: L10n.text("Rear right"), symbol: "carseat.right.fill",
                            level: $rearRightSeat
                        ) {
                            preferences.remoteRearRightSeatHeating = $0
                        }
                        .disabled(gate.isDisabled(Self.probe))
                        Spacer(minLength: 0)
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                } else {
                    Button {
                        withAnimation(Motion.resolve(Motion.layout)) { showRearSeats = true }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.down")
                            Text(L10n.text("Rear seat heating")).hisType(.caption, weight: .medium)
                        }
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(HisingenTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var startClimateCommand: RemoteCommand {
        .startClimate(
            temperatureCelsius: Float(targetTemperature),
            frontLeftSeat: driverSeat,
            frontRightSeat: passengerSeat,
            rearLeftSeat: showRearSeats ? rearLeftSeat : .unspecified,
            rearRightSeat: showRearSeats ? rearRightSeat : .unspecified,
            steeringWheel: steeringHeating
        )
    }

    private var climateTemperatureRange: ClosedRange<Double> {
        state.otaCapabilities?.controlSettings?.temperatureRange ?? 16...30
    }

    private var climateStartStopButtons: some View {
        // One stable Button identity across start/stop: the icon and label
        // crossfade in place (spinner→fan morph) instead of the whole control
        // snapping to a new view.
        Button {
            gate.send(climateActive ? .stopClimate : startClimateCommand)
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    if climateActive {
                        SpinningFanView(isSpinning: !reduceMotion, size: 13, color: .white)
                            .transition(.opacity)
                    } else {
                        Image(systemName: "fan.fill")
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            .transition(.opacity)
                    }
                }
                Text(climateActive ? L10n.text("Stop Climate") : L10n.text("Start Climate"))
                    .hisType(.body, weight: .semibold)
                    .contentTransition(reduceMotion ? .identity : .opacity)
                gate.sendingOverlay(climateActive ? .stopClimate : startClimateCommand)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .tint(climateActive ? HisingenTheme.semanticCritical : HisingenTheme.polestarAmber)
        .disabled(gate.isDisabled(climateActive ? .stopClimate : startClimateCommand))
        .hisAnimation(Motion.stateChange, value: climateActive)
    }
}
