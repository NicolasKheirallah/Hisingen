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

    private var climateActive: Bool {
        guard let status = state.climateStatus else { return false }
        return status.activity == .active || status.activity == .heating
            || status.activity == .cooling || status.activity == .ventilating
    }

    var body: some View {
        let climateCommands = [Self.probe, RemoteCommand.startPreCleaning]
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    HStack(spacing: 7) {
                        SpinningFanView(
                            isSpinning: climateActive && !reduceMotion,
                            size: 14,
                            color: climateActive ? .orange : HisingenTheme.inkMuted
                        )
                        Text(L10n.text("Climate & Conditioning"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(HisingenTheme.ink)
                    }
                    Spacer()
                    if climateActive {
                        Pill(
                            text: state.climateStatus?.activity.displayName ?? L10n.text("Active"),
                            color: .orange,
                            symbol: "fan.fill"
                        )
                    } else if let status = state.climateStatus,
                              status.activity != .unknown,
                              status.activity != .idle {
                        Pill(text: status.activity.displayName, color: .secondary, symbol: nil)
                    }
                }

                gate.dimReason(gate.cardAvailability(climateCommands))

                if features.contains(.remoteClimate) {
                    if profile.hasSelectableClimateTemperature {
                        temperatureControls
                    } else {
                        climateAutomaticInfo
                    }

                    if profile.hasSelectableSeatHeating || profile.hasSelectableSteeringWheelHeating {
                        seatAndSteeringControls
                    }

                    Divider().opacity(0.5)
                    climateStartStopButtons

                    if features.contains(.remoteSchedules) && profile.permits(.climateTimers) {
                        Button {
                            onShowSchedule(.climate)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "calendar.badge.clock")
                                Text(L10n.text("Schedule departure preconditioning…"))
                                    .font(.system(size: 10.5, weight: .medium))
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
                                .font(.system(size: 11, weight: .medium))
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
        .opacity(gate.cardOpacity(climateCommands))
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
            HStack {
                Button {
                    gate.send(maxHeatCommand)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "windshield.front.heat")
                        Text(L10n.text("Max Heat")).font(.system(size: 9, weight: .semibold))
                        gate.sendingOverlay(maxHeatCommand)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
                .disabled(gate.isDisabled(maxHeatCommand))
                .help(L10n.text("Sends 30 °C with every heater at maximum. Does not change your saved settings."))
                Spacer()
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("Preconditioning Command Setpoint"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(L10n.text("Saved command setting; not live cabin telemetry"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    if let remaining = state.climateStatus?.timeRemainingMinutes, climateActive {
                        Text(L10n.format("%d min remaining", remaining))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(HisingenTheme.polestarAmber)
                    }
                }
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
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(targetTemperature <= climateTemperatureRange.lowerBound)
                .accessibilityLabel(L10n.text("Decrease target temperature"))

                HStack(spacing: 4) {
                    ForEach([19, 20, 21, 22, 23].filter { climateTemperatureRange.contains(Double($0)) }, id: \.self) { temp in
                        let isSelected = abs(targetTemperature - Double(temp)) < 0.25
                        Button {
                            targetTemperature = Double(temp)
                            preferences.remoteClimateTemperature = Double(temp)
                        } label: {
                            Text(Format.temperature(celsius: Double(temp), unit: preferences.temperatureUnit, decimals: 0))
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(isSelected ? Color.orange : nil)
                        .controlSize(.small)
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
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 24)
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HisingenTheme.ink)
                    if let remaining = state.climateStatus?.timeRemainingMinutes {
                        Text(L10n.format("%d min remaining", remaining))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.orange)
                    } else {
                        Text(L10n.text("Preconditions vehicle using in-car comfort settings."))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let interior = state.climateStatus?.interiorTemperatureCelsius {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(L10n.text("Interior")).font(.system(size: 9.5)).foregroundStyle(.secondary)
                        Text(Format.temperature(celsius: interior, unit: preferences.temperatureUnit))
                            .font(.system(size: 16, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(HisingenTheme.temperatureColor(celsius: interior))
                    }
                }
            }
            .padding(9)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            HStack {
                Text(L10n.text("Preconditions the cabin to comfortable temperature using in-car climate settings."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let interior = state.climateStatus?.interiorTemperatureCelsius {
                    Text(Format.temperature(celsius: interior, unit: preferences.temperatureUnit))
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var seatAndSteeringControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if profile.hasSelectableSeatHeating
                    && state.otaCapabilities?.controlSettings?.frontSeatSettings != false {
                    SeatHeatingControl(title: L10n.text("Driver"), level: $driverSeat) {
                        preferences.remoteDriverSeatHeating = $0
                    }
                    .disabled(gate.isDisabled(Self.probe))

                    SeatHeatingControl(title: L10n.text("Passenger"), level: $passengerSeat) {
                        preferences.remoteFrontRightSeatHeating = $0
                    }
                    .disabled(gate.isDisabled(Self.probe))
                }

                if profile.hasSelectableSteeringWheelHeating
                    && state.otaCapabilities?.controlSettings?.steeringWheelSettings != false {
                    SteeringHeatingControl(level: $steeringHeating) {
                        preferences.remoteSteeringWheelHeating = $0
                    }
                    .disabled(gate.isDisabled(Self.probe))
                }
            }

            if profile.hasSelectableSeatHeating
                && state.otaCapabilities?.controlSettings?.rearSeatSettings != false {
                if showRearSeats {
                    HStack(spacing: 8) {
                        SeatHeatingControl(title: L10n.text("Rear left"), level: $rearLeftSeat) {
                            preferences.remoteRearLeftSeatHeating = $0
                        }
                        .disabled(gate.isDisabled(Self.probe))
                        SeatHeatingControl(title: L10n.text("Rear right"), level: $rearRightSeat) {
                            preferences.remoteRearRightSeatHeating = $0
                        }
                        .disabled(gate.isDisabled(Self.probe))
                        Spacer(minLength: 0)
                    }
                } else {
                    Button {
                        withAnimation { showRearSeats = true }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.down")
                            Text(L10n.text("Rear seat heating")).font(.system(size: 10, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
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
        HStack(spacing: 8) {
            if climateActive {
                Button {
                    gate.send(.stopClimate)
                } label: {
                    HStack(spacing: 6) {
                        SpinningFanView(isSpinning: !reduceMotion, size: 13, color: .white)
                        Text(L10n.text("Stop Climate")).font(.system(size: 12, weight: .semibold))
                        gate.sendingOverlay(.stopClimate)
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.red)
                .disabled(gate.isDisabled(.stopClimate))
            } else {
                Button {
                    gate.send(startClimateCommand)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "fan.fill")
                        Text(L10n.text("Start Climate")).font(.system(size: 12, weight: .semibold))
                        gate.sendingOverlay(Self.probe)
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(HisingenTheme.polestarAmber)
                .disabled(gate.isDisabled(Self.probe))
            }
        }
    }
}
